// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:otel_serverpod/src/otel_endpoint_wrapper.dart';
import 'package:otel_serverpod/src/request_telemetry.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

class _TestEndpoints extends EndpointDispatch {
  @override
  void initializeEndpoints(Server server) {}
}

class _TestEndpoint extends Endpoint {}

class _FakeSession extends Fake implements Session {}

class _Boom implements Exception {}

class _DeclaredApiException implements SerializableException {
  @override
  Object? toJson() => <String, Object?>{};
}

void main() {
  group('wrapEndpointDispatch / wrapMethodConnector', () {
    setUpAll(() async {
      await otel.OTel.initialize(
        serviceName: 'test-service',
        endpoint: 'http://localhost:4318',
      );
    });

    tearDown(OtelServerpod.uninstall);

    _TestEndpoints buildDispatch(MethodCall call) {
      final endpoints = _TestEndpoints();
      endpoints.connectors['greeting'] = EndpointConnector(
        name: 'greeting',
        endpoint: _TestEndpoint(),
        methodConnectors: {
          'hello': MethodConnector(
            name: 'hello',
            params: {
              'name': ParameterDescription(
                  name: 'name', type: String, nullable: false),
            },
            call: call,
            returnsVoid: false,
          ),
          'stream': MethodStreamConnector(
            name: 'stream',
            params: {},
            returnType: MethodStreamReturnType.streamType,
            streamParams: {},
            call: (session, params, streamParams) =>
                const Stream<Object?>.empty(),
          ),
        },
      );
      return endpoints;
    }

    otel.Span startServerSpan() =>
        otel.OTel.tracerProvider().getTracer('test').startSpan(
              'POST',
              kind: otel.SpanKind.server,
            );

    test('rewrap preserves keys/params and passes stream connectors through',
        () {
      final endpoints = buildDispatch((session, params) async => 'Hello');
      final originalStream =
          endpoints.connectors['greeting']!.methodConnectors['stream'];
      final originalHello = endpoints.connectors['greeting']!
          .methodConnectors['hello']! as MethodConnector;

      wrapEndpointDispatch(endpoints);

      final connector = endpoints.connectors['greeting']!;
      expect(connector.methodConnectors.keys, ['hello', 'stream']);
      expect(connector.methodConnectors['stream'], same(originalStream));

      final wrapped = connector.methodConnectors['hello']! as MethodConnector;
      expect(wrapped, isNot(same(originalHello)));
      expect(wrapped.name, 'hello');
      expect(wrapped.params, same(originalHello.params));
      expect(wrapped.returnsVoid, originalHello.returnsVoid);
    });

    test('wrapped call renames the active span and sets route/rpc attributes',
        () async {
      Session? seenSession;
      Map<String, dynamic>? seenParams;
      final endpoints = buildDispatch((session, params) async {
        seenSession = session;
        seenParams = params;
        return 'Hello';
      });
      wrapEndpointDispatch(endpoints);
      final wrapped = endpoints.connectors['greeting']!
          .methodConnectors['hello']! as MethodConnector;

      final span = startServerSpan();
      final telemetry = RequestTelemetry();
      final session = _FakeSession();
      final result = await otel.Context.current
          .withSpan(span)
          .copyWith(RequestTelemetry.contextKey, telemetry)
          .run(() => wrapped.call(session, {'name': 'World'}));
      span.end();

      expect(result, 'Hello');
      expect(seenSession, same(session));
      expect(seenParams, {'name': 'World'});
      expect(span.name, 'POST greeting.hello');
      expect(
          span.attributes.getString(otel.Http.httpRoute.key), 'greeting.hello');
      expect(span.attributes.getString(otel.Rpc.rpcSystemName.key),
          OtelServerpodSemantics.rpcSystemServerpod);
      expect(
          span.attributes.getString(otel.Rpc.rpcMethod.key), 'greeting.hello');
      expect(telemetry.endpointPath, 'greeting');
      expect(telemetry.method, 'hello');
      expect(telemetry.httpRoute, 'greeting.hello');
    });

    test('module connectors get the module-qualified route', () async {
      final module = _TestEndpoints();
      module.connectors['user'] = EndpointConnector(
        name: 'user',
        endpoint: _TestEndpoint(),
        methodConnectors: {
          'get': MethodConnector(
              name: 'get', params: {}, call: (session, params) async => null),
        },
      );
      final endpoints = _TestEndpoints();
      endpoints.modules['auth'] = module;

      wrapEndpointDispatch(endpoints);
      final wrapped = module.connectors['user']!.methodConnectors['get']!
          as MethodConnector;

      final span = startServerSpan();
      await otel.Context.current
          .withSpan(span)
          .run(() => wrapped.call(_FakeSession(), {}));
      span.end();

      expect(span.name, 'POST auth.user.get');
      expect(
          span.attributes.getString(otel.Http.httpRoute.key), 'auth.user.get');
    });

    test('records the exception, marks Error and rethrows', () async {
      final endpoints = buildDispatch((session, params) async => throw _Boom());
      wrapEndpointDispatch(endpoints);
      final wrapped = endpoints.connectors['greeting']!
          .methodConnectors['hello']! as MethodConnector;

      final span = startServerSpan();
      await expectLater(
        otel.Context.current
            .withSpan(span)
            .run(() => wrapped.call(_FakeSession(), {})),
        throwsA(isA<_Boom>()),
      );
      span.end();

      expect(span.status, otel.SpanStatusCode.Error);
      expect(span.spanEvents, isNotEmpty);
      expect(span.attributes.getString(otel.ErrorAttributes.errorType.key),
          '_Boom');
    });

    test(
        'SerializableException keeps the span status Unset '
        '(declared API contract error, 4xx on the wire)', () async {
      final endpoints = buildDispatch(
          (session, params) async => throw _DeclaredApiException());
      wrapEndpointDispatch(endpoints);
      final wrapped = endpoints.connectors['greeting']!
          .methodConnectors['hello']! as MethodConnector;

      final span = startServerSpan();
      await expectLater(
        otel.Context.current
            .withSpan(span)
            .run(() => wrapped.call(_FakeSession(), {})),
        throwsA(isA<_DeclaredApiException>()),
      );
      span.end();

      // Not Error — the SDK's end() upgrades a still-Unset status to Ok.
      expect(span.status, otel.SpanStatusCode.Ok);
      expect(span.spanEvents, isNotEmpty);
      expect(span.attributes.getString(otel.ErrorAttributes.errorType.key),
          '_DeclaredApiException');
    });
  });
}
