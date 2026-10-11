// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'dart:io' show HttpStatus;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:otel_serverpod/src/otel_middleware.dart';
import 'package:otel_serverpod/src/request_telemetry.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

class _FakeHistogram extends Fake implements otel.APIHistogram<double> {
  final List<(double, otel.Attributes?)> records = [];

  @override
  void record(double value, [otel.Attributes? attributes]) =>
      records.add((value, attributes));
}

class _FakeUpDownCounter extends Fake implements otel.APIUpDownCounter<int> {
  final List<int> adds = [];

  @override
  void add(int value, [otel.Attributes? attributes]) => adds.add(value);
}

class _Boom implements Exception {}

const _traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
const _traceparent = '00-$_traceId-00f067aa0ba902b7-01';

Request _postRequest({Map<String, Iterable<String>>? headers}) =>
    RequestInternal.create(
      Method.post,
      Uri.parse('http://localhost:8080/greeting'),
      Object(),
      headers: Headers.fromMap(headers),
    );

void main() {
  group('otelServerpodMiddleware', () {
    setUpAll(() async {
      await otel.OTel.initialize(
        serviceName: 'test-service',
        endpoint: 'http://localhost:4318',
      );
    });

    tearDown(OtelServerpod.uninstall);

    late _FakeHistogram requestDuration;
    late _FakeUpDownCounter activeRequests;
    late Middleware middleware;

    setUp(() {
      requestDuration = _FakeHistogram();
      activeRequests = _FakeUpDownCounter();
      middleware = otelServerpodMiddleware(
        tracer: otel.OTel.tracerProvider().getTracer(
          OtelServerpodSemantics.instrumentationScopeName,
          version: OtelServerpodSemantics.instrumentationScopeVersion,
        ),
        requestDuration: requestDuration,
        activeRequests: activeRequests,
      );
    });

    test(
        'extracts W3C context, opens a server span and records the duration '
        'metric with the status code', () async {
      otel.Span? seenSpan;
      RequestTelemetry? seenTelemetry;
      final handler = middleware((req) async {
        seenSpan = otel.Context.current.span as otel.Span?;
        seenTelemetry = otel.Context.current.get(RequestTelemetry.contextKey);
        return Response.ok();
      });

      final result = await handler(_postRequest(headers: {
        'traceparent': [_traceparent],
      })) as Response;

      expect(result.statusCode, HttpStatus.ok);
      final span = seenSpan!;
      expect(span.kind, otel.SpanKind.server);
      expect(span.name, 'POST'); // semconv unrouted fallback
      expect(span.spanContext.traceId.toString(), _traceId);
      expect(seenTelemetry, isNotNull);
      expect(
          span.attributes.getString(otel.Http.httpRequestMethod.key), 'POST');
      expect(span.attributes.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.ok);
      // Not Error. Instrumentation leaves a successful span Unset, and the
      // SDK no longer upgrades Unset to Ok on end().
      expect(span.status, otel.SpanStatusCode.Unset);

      expect(requestDuration.records, hasLength(1));
      final (value, attributes) = requestDuration.records.single;
      expect(value, greaterThanOrEqualTo(0));
      expect(attributes!.getString(otel.Http.httpRequestMethod.key), 'POST');
      expect(attributes.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.ok);
      expect(attributes.getString(otel.Url.urlScheme.key), 'http');
      expect(attributes.getString(otel.ErrorAttributes.errorType.key), isNull);
    });

    test('tracks active_requests +1/-1 around the call', () async {
      final handler = middleware((req) async {
        expect(activeRequests.adds, [1]);
        return Response.ok();
      });
      await handler(_postRequest());
      expect(activeRequests.adds, [1, -1]);
    });

    test('metric http.route comes from the RequestTelemetry holder', () async {
      final handler = middleware((req) async {
        otel.Context.current.get(RequestTelemetry.contextKey)!
          ..endpointPath = 'greeting'
          ..method = 'hello';
        return Response.ok();
      });
      await handler(_postRequest());

      final (_, attributes) = requestDuration.records.single;
      expect(attributes!.getString(otel.Http.httpRoute.key), 'greeting.hello');
    });

    test(
        'unexpected exception: 500 on the metric, Error status + error.type '
        'on the span, rethrown', () async {
      otel.Span? seenSpan;
      final handler = middleware((req) async {
        seenSpan = otel.Context.current.span as otel.Span?;
        throw _Boom();
      });

      await expectLater(handler(_postRequest()), throwsA(isA<_Boom>()));

      final span = seenSpan!;
      expect(span.status, otel.SpanStatusCode.Error);
      expect(span.attributes.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.internalServerError);
      expect(span.attributes.getString(otel.ErrorAttributes.errorType.key),
          '_Boom');

      final (_, attributes) = requestDuration.records.single;
      expect(attributes!.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.internalServerError);
      expect(attributes.getString(otel.ErrorAttributes.errorType.key), '_Boom');
    });

    test(
        'dispatch exceptions map to their wire status codes and 4xx does not '
        'mark the server span as error', () async {
      otel.Span? seenSpan;
      final handler = middleware((req) async {
        seenSpan = otel.Context.current.span as otel.Span?;
        throw EndpointNotFoundException('Endpoint not found');
      });

      await expectLater(
          handler(_postRequest()), throwsA(isA<EndpointNotFoundException>()));

      final span = seenSpan!;
      // Not Error. Instrumentation leaves a successful span Unset, and the
      // SDK no longer upgrades Unset to Ok on end().
      expect(span.status, otel.SpanStatusCode.Unset);
      expect(span.attributes.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.notFound);
      expect(span.attributes.getString(otel.ErrorAttributes.errorType.key),
          isNull);

      final (_, attributes) = requestDuration.records.single;
      expect(attributes!.getInt(otel.Http.httpResponseStatusCode.key),
          HttpStatus.notFound);
      expect(attributes.getString(otel.ErrorAttributes.errorType.key), isNull);
    });
  });
}
