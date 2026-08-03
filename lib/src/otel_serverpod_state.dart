// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;

/// Package-internal install-time wiring shared by `OtelServerpod`,
/// `OtelServerpod.databaseInterceptor` and `OtelFutureCall`. Not exported by
/// the package barrel — this is plumbing, not API.
class OtelServerpodInstallation {
  /// Captures the wiring `OtelServerpod.install` resolved.
  OtelServerpodInstallation({
    required this.tracer,
    required this.dbOperationDuration,
    required this.captureDbStatements,
  });

  /// Tracer for the `otel_serverpod` instrumentation scope.
  final otel.Tracer tracer;

  /// `db.client.operation.duration` histogram for `OtelDatabase`.
  final otel.APIHistogram<double> dbOperationDuration;

  /// Stamp `db.query.text` on `unsafe*` database operations.
  final bool captureDbStatements;

  /// The active installation, set by `OtelServerpod.install`, cleared by
  /// `OtelServerpod.uninstall`.
  static OtelServerpodInstallation? current;

  /// The active installation, or a StateError naming the fix. Fail fast, no
  /// fallback: telemetry silently not appearing is the worst failure mode.
  static OtelServerpodInstallation require() {
    final installation = current;
    if (installation == null) {
      throw StateError('Call OtelServerpod.install(pod) before pod.start() — '
          'OtelServerpod is not installed.');
    }
    return installation;
  }
}
