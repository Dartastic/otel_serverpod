// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:serverpod/serverpod.dart';

import 'otel_serverpod_semantics.dart';

/// A [Database] wrapper that opens a [otel.SpanKind.client] span named
/// `{db.operation.name} {db.collection.name}` (e.g. `find person`) around
/// every operation and records `db.client.operation.duration`.
///
/// Installed per session by `OtelServerpod.databaseInterceptor` (passed to
/// the `Serverpod(databaseInterceptor:)` constructor parameter — the
/// documented "+1 line"); construct directly only in tests or custom wiring.
///
/// Spans parent to whatever span is active in the zone [otel.Context] when
/// the operation runs — the endpoint span for session ops inside an endpoint
/// call, the future-call span under `OtelFutureCall`. [transaction] wraps
/// its callback in the transaction span's context so inner operations become
/// children automatically.
///
/// `db.query.text` is stamped ONLY on the `unsafe*` raw-SQL operations and
/// ONLY when [captureDbStatements] is true — raw SQL can carry sensitive
/// literals, so the privacy default is OFF. The typed CRUD operations
/// never carry query text.
class OtelDatabase implements Database {
  /// Wraps [inner], emitting spans from [tracer] and (optionally) duration
  /// measurements to [operationDuration]. [serverAddress]/[serverPort] stamp
  /// `server.address`/`server.port` from the pod's database config.
  OtelDatabase({
    required Database inner,
    required otel.Tracer tracer,
    otel.APIHistogram<double>? operationDuration,
    this.captureDbStatements = false,
    this.serverAddress,
    this.serverPort,
  })  : _inner = inner,
        _tracer = tracer,
        _operationDuration = operationDuration;

  final Database _inner;
  final otel.Tracer _tracer;
  final otel.APIHistogram<double>? _operationDuration;

  /// Stamp `db.query.text` on `unsafe*` operations. Privacy default OFF.
  final bool captureDbStatements;

  /// `server.address` for every span, from the pod database config.
  final String? serverAddress;

  /// `server.port` for every span, from the pod database config.
  final int? serverPort;

  /// `db.system.name` registry value for the wrapped database's dialect.
  /// Read lazily so test fakes only need [Database.dialect] when a traced
  /// operation actually runs.
  late final String _dbSystemName = switch (_inner.dialect) {
    DatabaseDialect.postgres => otel.DbSystemName.postgresql.value,
    DatabaseDialect.sqlite => otel.DbSystemName.sqlite.value,
  };

  /// Table name for the model type [T], from the wrapped database's
  /// serialization manager; null when [T] has no table (never expected for
  /// generated models, but the span is not worth failing an op over).
  String? _tableNameFor<T>() =>
      _inner.serializationManager.getTableForType(T)?.tableName;

  /// Run [operation] under a client span + duration measurement.
  ///
  /// [activateSpan] additionally runs [operation] in the new span's zone
  /// context — used by [transaction] so the operations inside the callback
  /// become children of the transaction span automatically. Leaf operations
  /// skip the zone hop.
  Future<R> _traced<R>(
    String operationName,
    String? collectionName,
    Future<R> Function() operation, {
    String? queryText,
    bool activateSpan = false,
  }) async {
    final span = _tracer.startSpan(
      OtelServerpodSemantics.dbSpanName(operationName, collectionName),
      kind: otel.SpanKind.client,
      attributes: otel.OTel.attributesFromSemanticMap({
        otel.Db.dbSystemName: _dbSystemName,
        otel.Db.dbOperationName: operationName,
        if (collectionName != null) otel.Db.dbCollectionName: collectionName,
        if (queryText != null && captureDbStatements)
          otel.Db.dbQueryText: queryText,
        if (serverAddress != null) otel.Server.serverAddress: serverAddress!,
        if (serverPort != null) otel.Server.serverPort: serverPort!,
      }),
    );
    final stopwatch = Stopwatch()..start();
    try {
      if (activateSpan) {
        return await otel.Context.current.withSpan(span).run(operation);
      }
      return await operation();
    } catch (e, stackTrace) {
      span.recordException(e, stackTrace: stackTrace, escaped: true);
      span.setStringAttribute<String>(
          otel.ErrorAttributes.errorType.key, e.runtimeType.toString());
      span.setStatus(otel.SpanStatusCode.Error);
      rethrow;
    } finally {
      stopwatch.stop();
      span.end();
      _operationDuration?.record(
        stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
        otel.OTel.attributesFromSemanticMap({
          otel.Db.dbSystemName: _dbSystemName,
          otel.Db.dbOperationName: operationName,
          if (collectionName != null) otel.Db.dbCollectionName: collectionName,
        }),
      );
    }
  }

  @override
  DatabaseDialect get dialect => _inner.dialect;

  @override
  DatabaseSerializationManager get serializationManager =>
      _inner.serializationManager;

  @override
  DatabaseAnalyzer get analyzer => _inner.analyzer;

  @override
  Future<List<T>> find<T extends TableRow>({
    Expression? where,
    int? limit,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationFind,
        _tableNameFor<T>(),
        () => _inner.find<T>(
          where: where,
          limit: limit,
          offset: offset,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: transaction,
          include: include,
          lockMode: lockMode,
          lockBehavior: lockBehavior,
        ),
      );

  @override
  Future<T?> findFirstRow<T extends TableRow>({
    Expression? where,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationFindFirstRow,
        _tableNameFor<T>(),
        () => _inner.findFirstRow<T>(
          where: where,
          offset: offset,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: transaction,
          include: include,
          lockMode: lockMode,
          lockBehavior: lockBehavior,
        ),
      );

  @override
  Future<T?> findById<T extends TableRow>(
    Object id, {
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationFindById,
        _tableNameFor<T>(),
        () => _inner.findById<T>(
          id,
          transaction: transaction,
          include: include,
          lockMode: lockMode,
          lockBehavior: lockBehavior,
        ),
      );

  @override
  Future<void> lockRows<T extends TableRow>({
    required Expression where,
    required LockMode lockMode,
    required Transaction transaction,
    LockBehavior lockBehavior = LockBehavior.wait,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationLockRows,
        _tableNameFor<T>(),
        () => _inner.lockRows<T>(
          where: where,
          lockMode: lockMode,
          transaction: transaction,
          lockBehavior: lockBehavior,
        ),
      );

  @override
  Future<List<T>> update<T extends TableRow>(
    List<T> rows, {
    List<Column>? columns,
    Transaction? transaction,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpdate,
        _tableNameFor<T>(),
        () => _inner.update<T>(
          rows,
          columns: columns,
          transaction: transaction,
          noReturn: noReturn,
        ),
      );

  @override
  Future<T> updateRow<T extends TableRow>(
    T row, {
    List<Column>? columns,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpdateRow,
        row.table.tableName,
        () => _inner.updateRow<T>(
          row,
          columns: columns,
          transaction: transaction,
        ),
      );

  @override
  Future<T?> updateById<T extends TableRow>(
    Object id, {
    required List<ColumnValue> columnValues,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpdateById,
        _tableNameFor<T>(),
        () => _inner.updateById<T>(
          id,
          columnValues: columnValues,
          transaction: transaction,
        ),
      );

  @override
  Future<List<T>> updateWhere<T extends TableRow>({
    required List<ColumnValue> columnValues,
    required Expression where,
    int? limit,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpdateWhere,
        _tableNameFor<T>(),
        () => _inner.updateWhere<T>(
          columnValues: columnValues,
          where: where,
          limit: limit,
          offset: offset,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: transaction,
          noReturn: noReturn,
        ),
      );

  @override
  Future<List<T>> insert<T extends TableRow>(
    List<T> rows, {
    Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationInsert,
        _tableNameFor<T>(),
        () => _inner.insert<T>(
          rows,
          transaction: transaction,
          ignoreConflicts: ignoreConflicts,
          noReturn: noReturn,
        ),
      );

  @override
  Future<T> insertRow<T extends TableRow>(
    T row, {
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationInsertRow,
        row.table.tableName,
        () => _inner.insertRow<T>(row, transaction: transaction),
      );

  @override
  Future<List<T>> upsert<T extends TableRow>(
    List<T> rows, {
    required List<Column> conflictColumns,
    List<Column>? updateColumns,
    Expression? updateWhere,
    Transaction? transaction,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpsert,
        _tableNameFor<T>(),
        () => _inner.upsert<T>(
          rows,
          conflictColumns: conflictColumns,
          updateColumns: updateColumns,
          updateWhere: updateWhere,
          transaction: transaction,
          noReturn: noReturn,
        ),
      );

  @override
  Future<T?> upsertRow<T extends TableRow>(
    T row, {
    required List<Column> conflictColumns,
    List<Column>? updateColumns,
    Expression? updateWhere,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUpsertRow,
        row.table.tableName,
        () => _inner.upsertRow<T>(
          row,
          conflictColumns: conflictColumns,
          updateColumns: updateColumns,
          updateWhere: updateWhere,
          transaction: transaction,
        ),
      );

  @override
  Future<List<T>> delete<T extends TableRow>(
    List<T> rows, {
    Column? orderBy,
    List<Column>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationDelete,
        _tableNameFor<T>(),
        () => _inner.delete<T>(
          rows,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: transaction,
          noReturn: noReturn,
        ),
      );

  @override
  Future<T> deleteRow<T extends TableRow>(
    T row, {
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationDeleteRow,
        row.table.tableName,
        () => _inner.deleteRow<T>(row, transaction: transaction),
      );

  @override
  Future<List<T>> deleteWhere<T extends TableRow>({
    required Expression where,
    Column? orderBy,
    List<Column>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationDeleteWhere,
        _tableNameFor<T>(),
        () => _inner.deleteWhere<T>(
          where: where,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: transaction,
          noReturn: noReturn,
        ),
      );

  @override
  Future<int> count<T extends TableRow>({
    Expression? where,
    int? limit,
    bool useCache = true,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationCount,
        _tableNameFor<T>(),
        () => _inner.count<T>(
          where: where,
          limit: limit,
          useCache: useCache,
          transaction: transaction,
        ),
      );

  @override
  Future<DatabaseResult> unsafeQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUnsafeQuery,
        null,
        () => _inner.unsafeQuery(
          query,
          timeoutInSeconds: timeoutInSeconds,
          transaction: transaction,
          parameters: parameters,
        ),
        queryText: query,
      );

  @override
  Future<int> unsafeExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUnsafeExecute,
        null,
        () => _inner.unsafeExecute(
          query,
          timeoutInSeconds: timeoutInSeconds,
          transaction: transaction,
          parameters: parameters,
        ),
        queryText: query,
      );

  @override
  Future<DatabaseResult> unsafeSimpleQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUnsafeSimpleQuery,
        null,
        () => _inner.unsafeSimpleQuery(
          query,
          timeoutInSeconds: timeoutInSeconds,
          transaction: transaction,
        ),
        queryText: query,
      );

  @override
  Future<int> unsafeSimpleExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationUnsafeSimpleExecute,
        null,
        () => _inner.unsafeSimpleExecute(
          query,
          timeoutInSeconds: timeoutInSeconds,
          transaction: transaction,
        ),
        queryText: query,
      );

  @override
  Future<R> transaction<R>(
    TransactionFunction<R> transactionFunction, {
    TransactionSettings? settings,
  }) =>
      _traced(
        OtelServerpodSemantics.dbOperationTransaction,
        null,
        () => _inner.transaction<R>(transactionFunction, settings: settings),
        // The operations inside the callback become children of the
        // transaction span via its activated zone context.
        activateSpan: true,
      );

  @override
  Future<bool> testConnection() => _traced(
        OtelServerpodSemantics.dbOperationTestConnection,
        null,
        _inner.testConnection,
      );
}
