// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:test/test.dart';

void main() {
  group('OtelServerpodSemantics', () {
    // The deliberate literal comparisons: these names ARE the wire contract
    // that dashboards and queries downstream depend on; a drift here
    // silently empties panels. This test guards the no-string-keys rule for
    // everything the package emits.

    test('instrumentation scope', () {
      expect(OtelServerpodSemantics.instrumentationScopeName, 'otel_serverpod');
      expect(
          OtelServerpodSemantics.instrumentationScopeVersion, '0.1.0-beta.1');
    });

    test('rpc.system.name value', () {
      expect(OtelServerpodSemantics.rpcSystemServerpod, 'serverpod');
    });

    test('http.server.request.duration boundaries are the registry advice', () {
      expect(OtelServerpodSemantics.httpServerRequestDurationBoundaries, const [
        0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, //
        5, 7.5, 10,
      ]);
    });

    test('metric names come from the rc.1 registry enums', () {
      expect(otel.HttpMetric.httpServerRequestDuration.name,
          'http.server.request.duration');
      expect(otel.HttpMetric.httpServerRequestDuration.unit, 's');
      expect(otel.HttpMetric.httpServerActiveRequests.name,
          'http.server.active_requests');
      expect(otel.DbMetric.dbClientOperationDuration.name,
          'db.client.operation.duration');
      expect(otel.DbMetric.dbClientOperationDuration.unit, 's');
    });

    test('span name / route builders', () {
      expect(OtelServerpodSemantics.httpRoute('greeting', 'hello'),
          'greeting.hello');
      expect(
          OtelServerpodSemantics.endpointSpanName('POST', 'greeting', 'hello'),
          'POST greeting.hello');
      expect(
          OtelServerpodSemantics.dbSpanName('find', 'person'), 'find person');
      expect(OtelServerpodSemantics.dbSpanName('transaction', null),
          'transaction');
    });

    test('db.operation.name values are the typed Database API verbs', () {
      expect(OtelServerpodSemantics.dbOperationFind, 'find');
      expect(OtelServerpodSemantics.dbOperationFindFirstRow, 'findFirstRow');
      expect(OtelServerpodSemantics.dbOperationFindById, 'findById');
      expect(OtelServerpodSemantics.dbOperationInsertRow, 'insertRow');
      expect(OtelServerpodSemantics.dbOperationUnsafeQuery, 'unsafeQuery');
      expect(OtelServerpodSemantics.dbOperationTransaction, 'transaction');
    });
  });
}
