// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    as otel;

/// Package-internal install-time wiring shared by `OtelServerpod`,
/// `OtelServerpod.databaseInterceptor` and the future-call spans. Not exported by
/// the package barrel — this is plumbing, not API.
class OtelServerpodInstallation {
  /// Captures the wiring `OtelServerpod.install` resolved.
  OtelServerpodInstallation({
    required this.tracer,
    required this.dbOperationDuration,
    required this.captureDbStatements,
  });

  /// Tracer for the `otel_serverpod` instrumentation scope.
  final otel.APITracer tracer;

  /// `db.client.operation.duration` histogram for `OtelDatabase`.
  final otel.APIHistogram<double> dbOperationDuration;

  /// Stamp `db.query.text` on `unsafe*` database operations.
  final bool captureDbStatements;

  /// The active installation, set by `OtelServerpod.install`, cleared by
  /// `OtelServerpod.uninstall`.
  static OtelServerpodInstallation? current;

  /// The active installation, or null after reporting the missing
  /// `OtelServerpod.install` through the OpenTelemetry error handler.
  /// Telemetry never throws into the app: callers skip instrumentation
  /// and let the operation run untraced.
  static OtelServerpodInstallation? resolve() {
    final installation = current;
    if (installation == null) {
      otel.OTelErrorHandling.report(StateError(
          'OtelServerpod is not installed: call OtelServerpod.install(pod) '
          'before pod.start(). Database and future-call spans are skipped.'));
    }
    return installation;
  }
}
