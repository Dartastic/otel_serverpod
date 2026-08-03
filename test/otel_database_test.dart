// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:otel_serverpod/src/otel_database.dart';
import 'package:serverpod/serverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

final _personTable = Table<int?>(tableName: 'person');

class _Person extends Fake implements TableRow<int?> {
  @override
  Table<int?> get table => _personTable;
}

class _FakeSerializationManager extends Fake
    implements DatabaseSerializationManager {
  @override
  Table? getTableForType(Type t) => t == _Person ? _personTable : null;
}

class _FakeTransaction extends Fake implements Transaction {}

class _Boom implements Exception {}

class _FakeDatabase extends Fake implements Database {
  final List<String> calls = [];

  @override
  DatabaseDialect get dialect => DatabaseDialect.postgres;

  @override
  DatabaseSerializationManager get serializationManager =>
      _FakeSerializationManager();

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
  }) async {
    calls.add('find');
    return [];
  }

  @override
  Future<T> insertRow<T extends TableRow>(T row,
      {Transaction? transaction}) async {
    calls.add('insertRow');
    return row;
  }

  @override
  Future<int> count<T extends TableRow>({
    Expression? where,
    int? limit,
    bool useCache = true,
    Transaction? transaction,
  }) async {
    calls.add('count');
    throw _Boom();
  }

  @override
  Future<int> unsafeExecute(String query,
      {int? timeoutInSeconds,
      Transaction? transaction,
      QueryParameters? parameters}) async {
    calls.add('unsafeExecute');
    return 1;
  }

  @override
  Future<R> transaction<R>(TransactionFunction<R> transactionFunction,
      {TransactionSettings? settings}) {
    calls.add('transaction');
    return transactionFunction(_FakeTransaction());
  }

  @override
  Future<bool> testConnection() async {
    calls.add('testConnection');
    return true;
  }
}

class _RecordingSpanProcessor implements otel.SpanProcessor {
  final List<otel.Span> ended = [];

  @override
  Future<void> onStart(otel.Span span, otel.Context? parentContext) async {}

  @override
  Future<void> onEnd(otel.Span span) async => ended.add(span);

  @override
  Future<void> onNameUpdate(otel.Span span, String newName) async {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

class _FakeHistogram extends Fake implements otel.APIHistogram<double> {
  final List<(double, otel.Attributes?)> records = [];

  @override
  void record(double value, [otel.Attributes? attributes]) =>
      records.add((value, attributes));
}

void main() {
  group('OtelDatabase', () {
    final recorder = _RecordingSpanProcessor();

    setUpAll(() async {
      await otel.OTel.initialize(
        serviceName: 'test-service',
        endpoint: 'http://localhost:4318',
      );
      otel.OTel.tracerProvider().addSpanProcessor(recorder);
    });

    tearDown(() async {
      recorder.ended.clear();
      await OtelServerpod.uninstall();
    });

    late _FakeDatabase inner;
    late _FakeHistogram histogram;

    OtelDatabase build({bool captureDbStatements = false}) {
      inner = _FakeDatabase();
      histogram = _FakeHistogram();
      return OtelDatabase(
        inner: inner,
        tracer: otel.OTel.tracerProvider().getTracer(
          OtelServerpodSemantics.instrumentationScopeName,
          version: OtelServerpodSemantics.instrumentationScopeVersion,
        ),
        operationDuration: histogram,
        captureDbStatements: captureDbStatements,
        serverAddress: 'localhost',
        serverPort: 5432,
      );
    }

    test('find delegates and emits `find person` client span + duration',
        () async {
      final db = build();
      final rows = await db.find<_Person>();

      expect(rows, isEmpty);
      expect(inner.calls, ['find']);

      final span = recorder.ended.single;
      expect(span.name, 'find person');
      expect(span.kind, otel.SpanKind.client);
      expect(span.attributes.getString(otel.Db.dbSystemName.key),
          otel.DbSystemName.postgresql.value);
      expect(span.attributes.getString(otel.Db.dbOperationName.key),
          OtelServerpodSemantics.dbOperationFind);
      expect(span.attributes.getString(otel.Db.dbCollectionName.key), 'person');
      expect(span.attributes.getString(otel.Server.serverAddress.key),
          'localhost');
      expect(span.attributes.getInt(otel.Server.serverPort.key), 5432);
      expect(span.attributes.getString(otel.Db.dbQueryText.key), isNull);

      final (value, attributes) = histogram.records.single;
      expect(value, greaterThanOrEqualTo(0));
      expect(attributes!.getString(otel.Db.dbOperationName.key),
          OtelServerpodSemantics.dbOperationFind);
      expect(attributes.getString(otel.Db.dbCollectionName.key), 'person');
    });

    test('row-based operations take the collection from the row', () async {
      final db = build();
      await db.insertRow(_Person());

      expect(inner.calls, ['insertRow']);
      expect(recorder.ended.single.name, 'insertRow person');
      expect(
          recorder.ended.single.attributes
              .getString(otel.Db.dbOperationName.key),
          OtelServerpodSemantics.dbOperationInsertRow);
    });

    test('db.query.text is absent on unsafe* by default', () async {
      final db = build();
      await db.unsafeExecute('DELETE FROM person');

      final span = recorder.ended.single;
      expect(span.name, OtelServerpodSemantics.dbOperationUnsafeExecute);
      expect(span.attributes.getString(otel.Db.dbQueryText.key), isNull);
    });

    test('db.query.text is present on unsafe* with captureDbStatements: true',
        () async {
      final db = build(captureDbStatements: true);
      await db.unsafeExecute('DELETE FROM person');

      final span = recorder.ended.single;
      expect(span.attributes.getString(otel.Db.dbQueryText.key),
          'DELETE FROM person');
    });

    test(
        'db.query.text never appears on typed operations, even with '
        'captureDbStatements: true', () async {
      final db = build(captureDbStatements: true);
      await db.find<_Person>();

      expect(
          recorder.ended.single.attributes.getString(otel.Db.dbQueryText.key),
          isNull);
    });

    test('transaction span parents the operations inside the callback',
        () async {
      final db = build();
      await db.transaction((tx) => db.find<_Person>(transaction: tx));

      expect(inner.calls, ['transaction', 'find']);
      expect(recorder.ended, hasLength(2));
      final findSpan = recorder.ended[0];
      final transactionSpan = recorder.ended[1];
      expect(
          transactionSpan.name, OtelServerpodSemantics.dbOperationTransaction);
      expect(findSpan.name, 'find person');
      expect(findSpan.spanContext.traceId, transactionSpan.spanContext.traceId);
      expect(findSpan.parentSpan?.spanContext.spanId,
          transactionSpan.spanContext.spanId);
    });

    test('failed operation records the exception, marks Error and rethrows',
        () async {
      final db = build();
      await expectLater(db.count<_Person>(), throwsA(isA<_Boom>()));

      final span = recorder.ended.single;
      expect(span.status, otel.SpanStatusCode.Error);
      expect(span.spanEvents, isNotEmpty);
      expect(span.attributes.getString(otel.ErrorAttributes.errorType.key),
          '_Boom');
      // The duration metric still records the failed operation.
      expect(histogram.records, hasLength(1));
    });

    test('testConnection delegates', () async {
      final db = build();
      expect(await db.testConnection(), isTrue);
      expect(inner.calls, ['testConnection']);
      expect(recorder.ended.single.name,
          OtelServerpodSemantics.dbOperationTestConnection);
    });
  });
}
