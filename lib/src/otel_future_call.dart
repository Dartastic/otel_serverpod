// Licensed under the Apache License, Version 2.0
// Copyright 2026, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:serverpod/serverpod.dart';

import 'otel_serverpod_state.dart';

/// Traced [FutureCall]: one line per call — change `extends FutureCall` to
/// `extends OtelFutureCall` and rename your `invoke` override to [run].
///
/// ```dart
/// class BirthdayReminder extends OtelFutureCall<Birthday> {
///   @override
///   Future<void> run(Session session, Birthday? object) async { ... }
/// }
/// ```
///
/// [invoke] is the template: it opens an [otel.SpanKind.internal] span named
/// after the registered future-call name with `code.function.name`, runs
/// [run] inside the span's zone context (so `session.db` operations become
/// child spans), and records + rethrows any exception. Do not override
/// [invoke] — override [run].
///
/// Serverpod exposes no invoke hook, so zero-config future-call spans are
/// not possible; this decorator is the documented one-line opt-in.
abstract class OtelFutureCall<T extends SerializableModel>
    extends FutureCall<T> {
  @override
  Future<void> invoke(Session session, T? object) async {
    final tracer = OtelServerpodInstallation.require().tracer;
    final span = tracer.startSpan(
      name,
      kind: otel.SpanKind.internal,
      attributes: otel.OTel.attributesFromSemanticMap({
        otel.Code.codeFunctionName: name,
      }),
    );
    try {
      await otel.Context.current.withSpan(span).run(() => run(session, object));
    } catch (e, stackTrace) {
      span.recordException(e, stackTrace: stackTrace, escaped: true);
      span.setStringAttribute<String>(
          otel.ErrorAttributes.errorType.key, e.runtimeType.toString());
      span.setStatus(otel.SpanStatusCode.Error);
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Your future call's work — what `invoke` would have been.
  Future<void> run(Session session, T? object);
}
