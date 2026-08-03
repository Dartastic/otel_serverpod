// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

/// Every telemetry name this package emits that is NOT in the rc.1
/// Weaver-generated semconv enums of `dartastic_opentelemetry_api`.
///
/// The no-string-keys rule: attribute keys, metric names, span names and
/// attribute values are either a semconv enum member (`Http.httpRoute`,
/// `HttpMetric.httpServerRequestDuration`, `DbSystemName.postgresql`, ...)
/// or an exported const/builder on this class — never an inline literal.
abstract final class OtelServerpodSemantics {
  /// Instrumentation scope name for every tracer/meter this package creates.
  static const String instrumentationScopeName = 'otel_serverpod';

  /// Instrumentation scope version — keep in lock-step with pubspec.yaml.
  static const String instrumentationScopeVersion = '0.1.0-beta.1';

  /// `rpc.system.name` value for Serverpod endpoint method calls.
  ///
  /// Not in the registry's [RpcSystemName] value enum (grpc, jsonrpc, ...);
  /// vendor systems supply their own name per the registry's open enum rule.
  static const String rpcSystemServerpod = 'serverpod';

  /// Explicit bucket boundaries for `http.server.request.duration`, seconds —
  /// the registry's advice buckets for HTTP server duration histograms.
  static const List<double> httpServerRequestDurationBoundaries = [
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1,
    2.5,
    5,
    7.5,
    10,
  ];

  /// Debug name of the [ContextKey] carrying the per-request
  /// `RequestTelemetry` holder between the middleware and the endpoint
  /// wrapper. Not a telemetry key; a Context plumbing name.
  static const String requestTelemetryContextKeyName =
      'otel_serverpod.request_telemetry';

  /// `http.route` for a Serverpod endpoint method call:
  /// route = `endpoint.method` (e.g. `greeting.hello`), the route-level
  /// grouping key dashboards consume.
  static String httpRoute(String endpointPath, String method) =>
      '$endpointPath.$method';

  /// Server span name for a routed endpoint call, semconv
  /// `{http.request.method} {http.route}` form (e.g. `POST greeting.hello`).
  static String endpointSpanName(
          String httpRequestMethod, String endpointPath, String method) =>
      '$httpRequestMethod ${httpRoute(endpointPath, method)}';

  /// Client span name for a database operation, semconv
  /// `{db.operation.name} {db.collection.name}` form (e.g. `find person`),
  /// falling back to the bare operation when no collection is known.
  static String dbSpanName(String operationName, String? collectionName) =>
      collectionName == null ? operationName : '$operationName $collectionName';

  // `db.operation.name` values — the typed Serverpod Database API verbs.
  // One const per delegated method on `Database` (4.0 line).

  /// `db.operation.name` for `Database.find`.
  static const String dbOperationFind = 'find';

  /// `db.operation.name` for `Database.findFirstRow`.
  static const String dbOperationFindFirstRow = 'findFirstRow';

  /// `db.operation.name` for `Database.findById`.
  static const String dbOperationFindById = 'findById';

  /// `db.operation.name` for `Database.lockRows`.
  static const String dbOperationLockRows = 'lockRows';

  /// `db.operation.name` for `Database.update`.
  static const String dbOperationUpdate = 'update';

  /// `db.operation.name` for `Database.updateRow`.
  static const String dbOperationUpdateRow = 'updateRow';

  /// `db.operation.name` for `Database.updateById`.
  static const String dbOperationUpdateById = 'updateById';

  /// `db.operation.name` for `Database.updateWhere`.
  static const String dbOperationUpdateWhere = 'updateWhere';

  /// `db.operation.name` for `Database.insert`.
  static const String dbOperationInsert = 'insert';

  /// `db.operation.name` for `Database.insertRow`.
  static const String dbOperationInsertRow = 'insertRow';

  /// `db.operation.name` for `Database.upsert`.
  static const String dbOperationUpsert = 'upsert';

  /// `db.operation.name` for `Database.upsertRow`.
  static const String dbOperationUpsertRow = 'upsertRow';

  /// `db.operation.name` for `Database.delete`.
  static const String dbOperationDelete = 'delete';

  /// `db.operation.name` for `Database.deleteRow`.
  static const String dbOperationDeleteRow = 'deleteRow';

  /// `db.operation.name` for `Database.deleteWhere`.
  static const String dbOperationDeleteWhere = 'deleteWhere';

  /// `db.operation.name` for `Database.count`.
  static const String dbOperationCount = 'count';

  /// `db.operation.name` for `Database.unsafeQuery`.
  static const String dbOperationUnsafeQuery = 'unsafeQuery';

  /// `db.operation.name` for `Database.unsafeExecute`.
  static const String dbOperationUnsafeExecute = 'unsafeExecute';

  /// `db.operation.name` for `Database.unsafeSimpleQuery`.
  static const String dbOperationUnsafeSimpleQuery = 'unsafeSimpleQuery';

  /// `db.operation.name` for `Database.unsafeSimpleExecute`.
  static const String dbOperationUnsafeSimpleExecute = 'unsafeSimpleExecute';

  /// `db.operation.name` for `Database.transaction`.
  static const String dbOperationTransaction = 'transaction';

  /// `db.operation.name` for `Database.testConnection`.
  static const String dbOperationTestConnection = 'testConnection';
}
