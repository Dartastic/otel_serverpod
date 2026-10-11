// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:serverpod/serverpod.dart';

import 'otel_database.dart';
import 'otel_endpoint_wrapper.dart';
import 'otel_future_call.dart';
import 'otel_middleware.dart';
import 'otel_serverpod_semantics.dart';
import 'otel_serverpod_state.dart';

/// One-call OpenTelemetry instrumentation for Serverpod.
///
/// ```dart
/// await OTel.initialize(serviceName: 'mypod');
/// final pod = Serverpod(args, Protocol(), Endpoints(),
///     databaseInterceptor: OtelServerpod.databaseInterceptor);
/// OtelServerpod.install(pod);
/// await pod.start();
/// ```
///
/// [install] gives you `http.server` spans named `POST endpoint.method`
/// (with `http.route = endpoint.method`) and the
/// `http.server.request.duration` and `http.server.active_requests`
/// metrics. The `databaseInterceptor:` constructor line adds `db.*`
/// client spans and `db.client.operation.duration` per database operation.
abstract final class OtelServerpod {
  /// Install the middleware and rewrap the endpoint connectors. Call after
  /// OTel initialization and after constructing the pod, before
  /// `pod.start()`. Idempotent — a second call is a no-op.
  ///
  /// [tracer]/[meter] default to the `otel_serverpod` instrumentation scope
  /// on the global providers.
  ///
  /// [captureDbStatements] stamps `db.query.text` on `unsafe*` raw-SQL
  /// database operations. Privacy default OFF — raw SQL can carry sensitive
  /// literals.
  ///
  /// Throws [StateError] when the OTel SDK is not initialized. No fallback
  /// auto-init: the endpoint/auth wiring belongs to your initialize call.
  static void install(
    Serverpod pod, {
    otel.Tracer? tracer,
    otel.APIMeter? meter,
    bool captureDbStatements = false,
  }) {
    final factory = otel.OTelFactory.otelFactory;
    if (factory == null || factory is! otel.OTelSDKFactory) {
      throw StateError(
          'Initialize OTel (OTel.initialize) before OtelServerpod.install');
    }
    if (OtelServerpodInstallation.current != null) return;

    tracer ??= otel.OTel.tracerProvider().getTracer(
      OtelServerpodSemantics.instrumentationScopeName,
      version: OtelServerpodSemantics.instrumentationScopeVersion,
    );
    meter ??= otel.OTel.meterProvider().getMeter(
      name: OtelServerpodSemantics.instrumentationScopeName,
      version: OtelServerpodSemantics.instrumentationScopeVersion,
    );

    final requestDuration = meter.createHistogram<double>(
      name: otel.HttpMetric.httpServerRequestDuration.name,
      unit: otel.HttpMetric.httpServerRequestDuration.unit,
      advisory: const otel.InstrumentAdvisory(
        explicitBucketBoundaries:
            OtelServerpodSemantics.httpServerRequestDurationBoundaries,
      ),
    );
    final activeRequests = meter.createUpDownCounter<int>(
      name: otel.HttpMetric.httpServerActiveRequests.name,
      unit: otel.HttpMetric.httpServerActiveRequests.unit,
    );
    final dbOperationDuration = meter.createHistogram<double>(
      name: otel.DbMetric.dbClientOperationDuration.name,
      unit: otel.DbMetric.dbClientOperationDuration.unit,
    );

    OtelServerpodInstallation.current = OtelServerpodInstallation(
      tracer: tracer,
      dbOperationDuration: dbOperationDuration,
      captureDbStatements: captureDbStatements,
    );

    pod.server.addMiddleware(otelServerpodMiddleware(
      tracer: tracer,
      requestDuration: requestDuration,
      activeRequests: activeRequests,
    ));
    wrapEndpointDispatch(pod.endpoints);
  }

  /// Per-session [Database] wrapper emitting `db.*` client spans and
  /// `db.client.operation.duration`. Pass to the Serverpod constructor —
  /// a constructor parameter, so [install] cannot retrofit it:
  ///
  /// ```dart
  /// Serverpod(args, Protocol(), Endpoints(),
  ///     databaseInterceptor: OtelServerpod.databaseInterceptor);
  /// ```
  ///
  /// Sessions only reach the database after `pod.start()`, which the wiring
  /// order puts after [install]; a session created without [install] having
  /// run fails fast with [StateError] on its first database operation.
  ///
  /// For a [FutureCallSession] it also opens the future call's INTERNAL
  /// span (Serverpod builds the session, and so calls this, right before
  /// the call body runs) and ends it when Serverpod closes the session; the
  /// session's database operations become its children. Register
  /// [diagnosticEventHandler] too, so a future call that throws gets an
  /// Error status and its exception recorded.
  static Database databaseInterceptor(Session session, Database inner) {
    final installation = OtelServerpodInstallation.require();
    final futureCallSpan =
        session is FutureCallSession ? startFutureCallSpan(session) : null;
    final databaseConfig = session.serverpod.config.database;
    return OtelDatabase(
      inner: inner,
      tracer: installation.tracer,
      operationDuration: installation.dbOperationDuration,
      captureDbStatements: installation.captureDbStatements,
      serverAddress: databaseConfig?.host,
      serverPort: databaseConfig?.port,
      parentSpan: futureCallSpan,
    );
  }

  /// Records the exception of a future call that throws on its span and
  /// marks it Error. Serverpod reports those exceptions only as diagnostic
  /// events, so pass this handler to the pod alongside
  /// [databaseInterceptor]:
  ///
  /// ```dart
  /// Serverpod(args, Protocol(), Endpoints(),
  ///     databaseInterceptor: OtelServerpod.databaseInterceptor,
  ///     experimentalFeatures: ExperimentalFeatures(
  ///       diagnosticEventHandlers: [OtelServerpod.diagnosticEventHandler],
  ///     ));
  /// ```
  static const DiagnosticEventHandler diagnosticEventHandler =
      OtelFutureCallExceptionHandler();

  /// Test teardown: clear the installation.
  ///
  /// The relic middleware and connector wrappers cannot be removed from a
  /// live pod; discard the pod itself (tests construct a fresh one).
  static Future<void> uninstall() async {
    OtelServerpodInstallation.current = null;
  }
}
