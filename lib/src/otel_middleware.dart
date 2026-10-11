// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'dart:io' show HttpStatus;

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    as otel;
import 'package:serverpod/serverpod.dart';

import 'request_telemetry.dart';

/// Layer A of the endpoint instrumentation: a relic [Middleware] for
/// `pod.server.addMiddleware`.
///
/// Per request it:
/// - extracts W3C context (`traceparent`/`tracestate`/`baggage`) from the
///   request headers,
/// - opens ONE [otel.SpanKind.server] span named `{http.request.method}`
///   (the semconv unrouted fallback — Serverpod routes `POST /<endpoint>`
///   with the method in the JSON body, so the route is unknown here; the
///   endpoint wrapper renames the span once dispatch resolves it),
/// - runs `next(req)` in a zone carrying the OTel context plus a mutable
///   [RequestTelemetry] holder the wrapper fills in,
/// - on completion stamps `http.response.status_code`, ends the span, and
///   records `http.server.request.duration` with the final attributes,
///   tracking `http.server.active_requests` around the call.
///
/// User middleware runs INSIDE Serverpod's own exception-to-response
/// middleware, so failures surface here as raw exceptions, not error
/// responses; [_statusCodeForException] mirrors Serverpod's documented
/// mapping so the span/metric carry the status code the client receives.
Middleware otelServerpodMiddleware({
  required otel.APITracer tracer,
  required otel.APIHistogram<double> requestDuration,
  required otel.APIUpDownCounter<int> activeRequests,
}) {
  return (Handler next) {
    return (Request req) async {
      final carrier = <String, String>{
        for (final entry in req.headers.entries)
          entry.key.toLowerCase(): entry.value.join(','),
      };
      final getter = _MapGetter(carrier);
      // The app's configured propagators (W3C trace context + baggage by
      // default; OTEL_PROPAGATORS overrides), read per request so an SDK
      // initialized after install still applies.
      final extracted = otel.OTelAPI.textMapPropagator
          .extract(otel.Context.current, carrier, getter);

      final httpRequestMethod = req.method.value;
      final span = tracer.startSpan(
        httpRequestMethod,
        context: extracted,
        kind: otel.SpanKind.server,
        attributes: otel.OTelAPI.attributesFromSemanticMap({
          otel.Http.httpRequestMethod: httpRequestMethod,
          otel.Url.urlPath: req.url.path,
          otel.Url.urlScheme: req.url.scheme,
          otel.Network.networkProtocolVersion: req.protocolVersion,
        }),
      );

      final activeRequestAttributes = otel.OTelAPI.attributesFromSemanticMap({
        otel.Http.httpRequestMethod: httpRequestMethod,
        otel.Url.urlScheme: req.url.scheme,
      });
      activeRequests.add(1, activeRequestAttributes);

      final telemetry = RequestTelemetry();
      final stopwatch = Stopwatch()..start();
      int? statusCode;
      String? errorType;
      try {
        final result = await extracted
            .withSpan(span)
            .copyWith(RequestTelemetry.contextKey, telemetry)
            .run<Result>(() async => await next(req));
        // Hijack/WebSocketUpgrade results carry no HTTP status code.
        if (result is Response) statusCode = result.statusCode;
        return result;
      } catch (e) {
        statusCode = _statusCodeForException(e);
        errorType = e.runtimeType.toString();
        rethrow;
      } finally {
        stopwatch.stop();
        activeRequests.add(-1, activeRequestAttributes);

        final route = telemetry.httpRoute;
        final status = statusCode;
        final isServerError =
            status != null && status >= HttpStatus.internalServerError;
        // Semconv: 4xx does not mark a SERVER span as error, and error.type
        // is only set when the request ends in error (exception or 5xx).
        if (isServerError) {
          errorType ??= status.toString();
          span.setStatus(otel.SpanStatusCode.Error);
        }
        if (status != null) {
          span.setIntAttribute(otel.Http.httpResponseStatusCode.key, status);
        }
        if (errorType != null && isServerError) {
          span.setStringAttribute<String>(
              otel.ErrorAttributes.errorType.key, errorType);
        }
        span.end();

        requestDuration.record(
          stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
          otel.OTelAPI.attributesFromSemanticMap({
            otel.Http.httpRequestMethod: httpRequestMethod,
            if (route != null) otel.Http.httpRoute: route,
            if (status != null) otel.Http.httpResponseStatusCode: status,
            if (errorType != null && isServerError)
              otel.ErrorAttributes.errorType: errorType,
            otel.Url.urlScheme: req.url.scheme,
            otel.Network.networkProtocolVersion: req.protocolVersion,
          }),
        );
      }
    };
  };
}

/// The HTTP status Serverpod's outer exception middleware will answer with
/// for [e] — mirrors `Server._reportException` on the 4.0 line so the span
/// and metric agree with the wire response.
int _statusCodeForException(Object e) => switch (e) {
      EndpointNotFoundException() => HttpStatus.notFound,
      NotAuthorizedException(
        reason: AuthenticationFailureReason.unauthenticated
      ) =>
        HttpStatus.unauthorized,
      NotAuthorizedException() => HttpStatus.forbidden,
      MethodNotFoundException() ||
      InvalidEndpointMethodTypeException() ||
      InvalidParametersException() ||
      SerializableException() ||
      HeaderException() =>
        HttpStatus.badRequest,
      MaxBodySizeExceeded() => HttpStatus.requestEntityTooLarge,
      _ => HttpStatus.internalServerError,
    };

class _MapGetter implements otel.TextMapGetter<String> {
  _MapGetter(this._map);

  final Map<String, String> _map;

  @override
  String? get(String key) => _map[key];

  @override
  Iterable<String> keys() => _map.keys;
}
