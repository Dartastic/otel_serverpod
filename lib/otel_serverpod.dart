// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

/// OpenTelemetry instrumentation for Serverpod.
///
/// One `OtelServerpod.install(pod)` call opens `http.server` semconv spans
/// per endpoint method call (route = `endpoint.method`) and records the
/// standard `http.server.request.duration` metrics. Pass
/// `Serverpod(databaseInterceptor: OtelServerpod.databaseInterceptor)` for
/// `db.*` client spans. Works with any OTLP backend.
library;

export 'src/otel_serverpod.dart' show OtelServerpod;
export 'src/otel_serverpod_semantics.dart' show OtelServerpodSemantics;
