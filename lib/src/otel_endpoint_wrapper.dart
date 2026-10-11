// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    as otel;
import 'package:serverpod/serverpod.dart';

import 'otel_serverpod_semantics.dart';
import 'request_telemetry.dart';

/// Layer B of the endpoint instrumentation: rewrap every [MethodConnector]
/// in [endpoints] (top-level `connectors` plus each entry in `modules`) so
/// the middleware's server span gets its real name.
///
/// Serverpod has no endpoint interceptor API; the connectors live in public
/// mutable maps with public constructors, and dispatch re-reads them per
/// request, so replacing the entries is the supported-shape seam. Module
/// connectors are qualified `module.endpoint`, matching how
/// `EndpointDispatch.getConnectorByName` addresses them (max depth 2 — there
/// are no modules of modules to recurse into).
///
/// [MethodStreamConnector]s (websocket method streams) are passed through
/// UNWRAPPED in 0.1.0 — streaming keeps working, stream spans are a tracked
/// follow-up.
///
/// Dev-mode caveat: on hot reload Serverpod re-initializes the connector
/// maps, dropping these wrappers until restart (middleware and metrics
/// survive). See the README troubleshooting section.
void wrapEndpointDispatch(EndpointDispatch endpoints) {
  _wrapConnectors(endpoints.connectors, modulePrefix: null);
  for (final module in endpoints.modules.entries) {
    _wrapConnectors(module.value.connectors, modulePrefix: module.key);
  }
}

void _wrapConnectors(
  Map<String, EndpointConnector> connectors, {
  required String? modulePrefix,
}) {
  for (final connector in connectors.values) {
    final endpointPath = modulePrefix == null
        ? connector.name
        : '$modulePrefix.${connector.name}';
    connector.methodConnectors.updateAll(
      (name, methodConnector) => methodConnector is MethodConnector
          ? wrapMethodConnector(methodConnector, endpointPath: endpointPath)
          : methodConnector,
    );
  }
}

/// Rebuild [connector] with a wrapped [MethodCall] that upgrades the active
/// server span opened by the middleware (dispatch runs inside the
/// middleware's `next()` future, so the span arrives via the zone context):
///
/// - renames it `POST {endpoint}.{method}` (semconv `{method} {route}`),
/// - sets `http.route` = `{endpoint}.{method}` (the standard route-level
///   grouping key for dashboards), `rpc.system.name` = `serverpod`
///   and fully-qualified `rpc.method` (registry keys only — `rpc.system` and
///   `rpc.service` are deprecated in rc.1),
/// - writes endpoint/method into the [RequestTelemetry] holder so the
///   duration metric gets `http.route` too,
/// - records + rethrows exceptions (never swallows). Serverpod
///   [SerializableException]s are declared API contract errors answered
///   with a 4xx, so they get the exception event and `error.type` but leave
///   the span status governed by the resulting HTTP code; anything else
///   marks the span [otel.SpanStatusCode.Error].
///
/// Name, params and returnsVoid are preserved so dispatch validation is
/// untouched.
MethodConnector wrapMethodConnector(
  MethodConnector connector, {
  required String endpointPath,
}) {
  final route = OtelServerpodSemantics.httpRoute(endpointPath, connector.name);
  final original = connector.call;

  Future<dynamic> wrappedCall(
      Session session, Map<String, dynamic> params) async {
    final context = otel.Context.current;
    final span = context.span;

    final telemetry = context.get(RequestTelemetry.contextKey);
    telemetry
      ?..endpointPath = endpointPath
      ..method = connector.name;

    if (span != null) {
      // The middleware named the span `{http.request.method}` (the semconv
      // unrouted fallback), so span.name IS the method prefix here.
      span.updateName(OtelServerpodSemantics.endpointSpanName(
          span.name, endpointPath, connector.name));
      span.setStringAttribute<String>(otel.Http.httpRoute.key, route);
      span.setStringAttribute<String>(otel.Rpc.rpcSystemName.key,
          OtelServerpodSemantics.rpcSystemServerpod);
      span.setStringAttribute<String>(otel.Rpc.rpcMethod.key, route);
    }

    try {
      return await original(session, params);
    } catch (e, stackTrace) {
      if (span != null) {
        span.recordException(e, stackTrace: stackTrace, escaped: true);
        span.setStringAttribute<String>(
            otel.ErrorAttributes.errorType.key, e.runtimeType.toString());
        if (e is! SerializableException) {
          span.setStatus(otel.SpanStatusCode.Error);
        }
      }
      rethrow;
    }
  }

  return MethodConnector(
    name: connector.name,
    params: connector.params,
    call: wrappedCall,
    returnsVoid: connector.returnsVoid,
  );
}
