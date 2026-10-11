// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

// Drives serverpod 4.0's real FutureCallSession and diagnostic event
// dispatcher through the same sequence FutureCallManager._runFutureCall
// uses: build the session (which builds its database through the pod's
// databaseInterceptor), run the call, and on failure submit an
// ExceptionEvent for the session before closing it with the error.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:otel_serverpod/src/otel_serverpod_state.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod/src/server/diagnostic_events/event_dispatcher.dart';
import 'package:serverpod/src/server/diagnostic_events/operation_context_helpers.dart';
import 'package:serverpod/src/server/features.dart';
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

class _FakeDatabase extends Fake implements Database {
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
  }) async =>
      [];
}

final _config = ServerpodConfig(
  apiServer: ServerConfig(
    port: 8080,
    publicScheme: 'http',
    publicHost: 'localhost',
    publicPort: 8080,
  ),
  database: DatabaseConfig(
    host: 'db.internal',
    port: 5432,
    user: 'postgres',
    password: 'unused',
    name: 'app',
  ),
);

class _FakePod extends Fake implements Serverpod {
  @override
  ServerpodConfig get config => _config;
}

/// Mirrors serverpod 4.0.4 `Server.createDatabase`: the pod's
/// databaseInterceptor wraps the session's database at construction.
class _FakeServer extends Fake implements Server {
  @override
  final Serverpod serverpod = _FakePod();

  @override
  final MessageCentral messageCentral = MessageCentral();

  @override
  String get name => 'Server test';

  @override
  String get serverId => 'test';

  @override
  String get runMode => 'test';

  @override
  Database createDatabase(Session session) =>
      OtelServerpod.databaseInterceptor(session, _FakeDatabase());
}

class _MemoryExporter implements otel.SpanExporter {
  final spans = <otel.Span>[];

  @override
  Future<void> export(List<otel.Span> s) async => spans.addAll(s);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

class _Boom implements Exception {}

void main() {
  late _MemoryExporter exporter;
  const dispatcher =
      DiagnosticEventDispatcher([OtelServerpod.diagnosticEventHandler]);

  setUpAll(() => Features(_config));

  setUp(() async {
    await otel.OTel.reset();
    exporter = _MemoryExporter();
    await otel.OTel.initialize(
      serviceName: 'future-call-test',
      detectPlatformResources: false,
      spanProcessor: otel.SimpleSpanProcessor(exporter),
    );
    OtelServerpodInstallation.current = OtelServerpodInstallation(
      tracer: otel.OTel.tracerProvider().getTracer('otel_serverpod'),
      dbOperationDuration:
          otel.OTel.meterProvider().getMeter(name: 'test').createHistogram(
                name: 'db.client.operation.duration',
              ),
      captureDbStatements: false,
    );
  });

  tearDown(() async {
    await OtelServerpod.uninstall();
    await otel.OTel.shutdown();
    await otel.OTel.reset();
  });

  /// Runs [body] the way serverpod 4.0.4's FutureCallManager does.
  Future<void> runFutureCall(
    String name,
    Future<void> Function(Session session) body,
  ) async {
    final session = FutureCallSession(
      server: _FakeServer(),
      futureCallName: name,
      enableLogging: false,
    );
    try {
      await body(session);
      await session.close();
    } catch (error, stackTrace) {
      dispatcher.handleEvent(
        ExceptionEvent(error, stackTrace),
        space: OriginSpace.application,
        context: contextFromSession(session),
      );
      await session.close(error: error, stackTrace: stackTrace);
    }
  }

  otel.Span spanNamed(String name) =>
      exporter.spans.singleWhere((s) => s.name == name);

  test('a future call emits one INTERNAL span named after the call', () async {
    await runFutureCall('birthdayReminder', (session) async {
      await session.db.find<_Person>();
    });

    final span = spanNamed('birthdayReminder');
    expect(span.kind, otel.SpanKind.internal);
    expect(
      span.attributes.getString(otel.Code.codeFunctionName.key),
      'birthdayReminder',
    );
    expect(span.status, otel.SpanStatusCode.Unset);
    expect(span.isEnded, isTrue);
  });

  test('database operations in the call are children of its span', () async {
    await runFutureCall('birthdayReminder', (session) async {
      await session.db.find<_Person>();
    });

    final call = spanNamed('birthdayReminder');
    final find = spanNamed('find person');
    expect(find.parentSpanContext?.spanId, call.spanContext.spanId);
    expect(find.spanContext.traceId, call.spanContext.traceId);
  });

  test('a call that throws ends Error with the exception recorded', () async {
    await runFutureCall('birthdayReminder', (session) async {
      throw _Boom();
    });

    final span = spanNamed('birthdayReminder');
    expect(span.status, otel.SpanStatusCode.Error);
    expect(
      span.attributes.getString(otel.ErrorAttributes.errorType.key),
      '_Boom',
    );
    expect(span.spanEvents?.map((e) => e.name), contains('exception'));
  });

  test('exception events for other sessions are ignored', () async {
    await runFutureCall('quiet', (session) async {});
    dispatcher.handleEvent(
      ExceptionEvent(_Boom(), StackTrace.current),
      space: OriginSpace.application,
      context: const FutureCallOpContext(
        serverName: 'Server test',
        serverId: 'test',
        serverRunMode: 'test',
        sessionId: null,
        futureCallName: 'quiet',
      ),
    );
    await Future<void>(() {});

    expect(spanNamed('quiet').status, otel.SpanStatusCode.Unset);
  });
}
