// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:serverpod/serverpod.dart' hide Server;
import 'package:serverpod/serverpod.dart' as serverpod show Server;
import 'package:test/fake.dart';
import 'package:test/test.dart';

class _TestEndpoints extends EndpointDispatch {
  @override
  void initializeEndpoints(serverpod.Server server) {}
}

class _TestEndpoint extends Endpoint {}

class _FakeServer extends Fake implements serverpod.Server {
  final List<Middleware> middleware = [];

  @override
  void addMiddleware(Middleware middleware) => this.middleware.add(middleware);
}

class _FakePod extends Fake implements Serverpod {
  final _FakeServer fakeServer = _FakeServer();
  final _TestEndpoints testEndpoints = _TestEndpoints();

  _FakePod() {
    testEndpoints.connectors['greeting'] = EndpointConnector(
      name: 'greeting',
      endpoint: _TestEndpoint(),
      methodConnectors: {
        'hello': MethodConnector(
            name: 'hello', params: {}, call: (session, params) async => null),
      },
    );
  }

  @override
  serverpod.Server get server => fakeServer;

  @override
  EndpointDispatch get endpoints => testEndpoints;
}

void main() {
  group('OtelServerpod.install', () {
    // NOTE: test order matters — the no-SDK test must run before any
    // OTel.initialize in this file (global, single-shot, per-isolate state).
    test('installs without an SDK and never throws', () {
      // API-only: with no SDK the API hands out no-op instruments, and
      // initializing an SDK is the application's job.
      expect(() => OtelServerpod.install(_FakePod()), returnsNormally);
      OtelServerpod.uninstall();
    });

    test('installs once — double-install is a no-op', () async {
      await otel.OTel.initialize(
        serviceName: 'test-service',
        endpoint: 'http://localhost:4318',
      );
      addTearDown(OtelServerpod.uninstall);

      final pod = _FakePod();
      final originalCall = (pod.testEndpoints.connectors['greeting']!
              .methodConnectors['hello']! as MethodConnector)
          .call;

      OtelServerpod.install(pod);
      final wrappedOnce = pod.testEndpoints.connectors['greeting']!
          .methodConnectors['hello']! as MethodConnector;
      expect(pod.fakeServer.middleware, hasLength(1));
      expect(wrappedOnce.call, isNot(same(originalCall)));

      OtelServerpod.install(pod);
      expect(pod.fakeServer.middleware, hasLength(1),
          reason: 'second install must not add a second middleware');
      expect(
        pod.testEndpoints.connectors['greeting']!.methodConnectors['hello'],
        same(wrappedOnce),
        reason: 'second install must not re-wrap the connectors',
      );
    });

    test('uninstall clears the installation so install works again', () async {
      // OTel is initialized by the previous test (same isolate).
      addTearDown(OtelServerpod.uninstall);

      final pod = _FakePod();
      OtelServerpod.install(pod);
      await OtelServerpod.uninstall();

      final freshPod = _FakePod();
      OtelServerpod.install(freshPod);
      expect(freshPod.fakeServer.middleware, hasLength(1));
    });
  });
}
