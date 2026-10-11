// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:serverpod/serverpod.dart';

import 'otel_serverpod_state.dart';

/// Future-call spans for Serverpod 4.0.
///
/// Serverpod 4.0 runs a future call through a generated
/// `InvokableFutureCall` wrapper and exposes no invoke hook. What it does
/// expose, for every run, is a fresh [FutureCallSession]:
///
/// - the session's constructor asks the pod's `databaseInterceptor` for
///   its database, immediately before the call body runs, so
///   `OtelServerpod.databaseInterceptor` opens the span there
///   ([startFutureCallSpan]);
/// - Serverpod closes the session when the call returns or throws, which
///   runs the session's will-close listeners: the span ends there;
/// - a call that throws is reported as an [ExceptionEvent] with a
///   [FutureCallOpContext] to the pod's diagnostic event handlers, where
///   [OtelFutureCallExceptionHandler] records it on the span.
///
/// Serverpod submits the exception event before closing the session, but
/// dispatches it to handlers one event-loop turn later. The will-close
/// listener therefore waits one turn before ending the span, so the
/// exception is recorded on a live span.
///
/// The call body does not run inside the span's zone (Serverpod invokes it
/// from its own code path), so only operations that know the session can
/// parent to the span: `OtelDatabase` does, other client spans started in
/// the body (HTTP, say) do not.
final _openSpans = <UuidValue, otel.APISpan>{};

/// Opens the INTERNAL span for [session]'s future call and arranges for it
/// to end when Serverpod closes the session. Returns the span so the
/// session's database operations can parent to it.
otel.APISpan startFutureCallSpan(FutureCallSession session) {
  final tracer = OtelServerpodInstallation.require().tracer;
  final name = session.futureCallName;
  final span = tracer.startSpan(
    name,
    kind: otel.SpanKind.internal,
    attributes: otel.OTel.attributesFromSemanticMap({
      otel.Code.codeFunctionName: name,
    }),
  );
  final sessionId = session.sessionId;
  _openSpans[sessionId] = span;
  session.addWillCloseListener((_) async {
    // Let the exception event, dispatched one turn after submission,
    // reach OtelFutureCallExceptionHandler before the span ends.
    await Future<void>(() {});
    _openSpans.remove(sessionId);
    span.end();
  });
  return span;
}

/// Records future-call exceptions on the future call's span.
///
/// Register it with the pod:
///
/// ```dart
/// Serverpod(args, Protocol(), Endpoints(),
///     databaseInterceptor: OtelServerpod.databaseInterceptor,
///     experimentalFeatures: ExperimentalFeatures(
///       diagnosticEventHandlers: [OtelServerpod.diagnosticEventHandler],
///     ));
/// ```
final class OtelFutureCallExceptionHandler
    extends TypedEventHandler<ExceptionEvent> {
  /// Creates the handler. Stateless; one instance serves the whole pod.
  const OtelFutureCallExceptionHandler();

  @override
  void handleTypedEvent(
    ExceptionEvent event, {
    required OriginSpace space,
    required DiagnosticEventContext context,
  }) {
    if (context is! FutureCallOpContext) return;
    final sessionId = context.sessionId;
    if (sessionId == null) return;
    final span = _openSpans[sessionId];
    if (span == null) return;
    // Spec order: recordException first, THEN setStatus.
    span.recordException(event.exception,
        stackTrace: event.stackTrace, escaped: true);
    span.addAttributes(otel.OTel.attributesFromSemanticMap({
      otel.ErrorAttributes.errorType: event.exception.runtimeType.toString(),
    }));
    span.setStatus(otel.SpanStatusCode.Error);
  }
}
