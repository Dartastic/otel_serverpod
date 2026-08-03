// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;

import 'otel_serverpod_semantics.dart';

/// Mutable per-request holder shared between the relic middleware (layer A)
/// and the endpoint-connector wrapper (layer B) via the OTel [otel.Context].
///
/// Serverpod routes `POST /<endpoint>` with the method name inside the JSON
/// body, so the middleware cannot know the route when it opens the span. The
/// wrapper, which runs inside the middleware's `next()` future, writes the
/// endpoint/method here so the middleware can stamp `http.route` on the
/// `http.server.request.duration` metric when the request completes.
class RequestTelemetry {
  /// Endpoint path as dispatched (`greeting`, or `module.endpoint`).
  String? endpointPath;

  /// Endpoint method name (`hello`).
  String? method;

  /// `http.route` (= `endpoint.method`) once layer B has resolved the call,
  /// null for unrouted requests (404s, non-endpoint paths).
  String? get httpRoute {
    final endpointPath = this.endpointPath;
    final method = this.method;
    if (endpointPath == null || method == null) return null;
    return OtelServerpodSemantics.httpRoute(endpointPath, method);
  }

  /// The one [otel.ContextKey] both layers use. Lazily created on first use
  /// so it is only minted after `OTel.initialize` (creating it earlier throws
  /// the SDK's own initialize-first StateError — fail fast, no fallback).
  static final otel.ContextKey<RequestTelemetry> contextKey =
      otel.OTel.contextKey<RequestTelemetry>(
          OtelServerpodSemantics.requestTelemetryContextKeyName);
}
