<!-- dartastic-header:start -->
# OpenTelemetry instrumentation for `serverpod`

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OpenTelemetry Specification](https://img.shields.io/badge/OpenTelemetry-Specification-blueviolet)](https://opentelemetry.io/docs/specs/otel/)

`otel_serverpod` is an [OpenTelemetry](https://opentelemetry.io/) instrumentation for `serverpod` that
easily adds standard observability to applications that use `serverpod`.  This package depends on 
[dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api).

This package can be used with any OTel backend because it's compliant with the OpenTelemetry Specification.

This package supports Linux, macOS and Windows, for versions of `serverpod` that support those platforms.

This Apache-2.0 package is professionally maintained and supported with 💙 by Michael Bushe,
Dart and Flutter Maintainer at OpenTelemetry and the creator of [dartastic_opentelemetry](https://pub.dev/packages/dartastic_opentelemetry)
and [dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api). This package is professionally supported by
[Dartastic.io](https://dartastic.io).

---
## Dartastic.io: AI Code Healing and Real User Monitoring for Flutter

**See what your users experience. Find problems with Flutter apps in production. Fix them with AI.**

[Dartastic.io](https://dartastic.io) brings AI code healing, real user monitoring, and OpenTelemetry observability together in one platform built for Dart and Flutter. (Patents pending)

![Dartastic AI answering "Why did crashes jump after the last release?" over a Flutter App Health dashboard](https://dartastic.io/img/pub-dev/HomePageCrashesQuestion.png)

### Dartastic AI — From Production Problems to Code Fixes

Dartastic AI analyzes production telemetry alongside your application source code to diagnose problems and propose fixes.

- **Investigate production issues** using crashes, errors, traces, metrics, and real user telemetry.
- **Find the offending code** by connecting observed problems with your application's source in Dartastic Pub or your source code repos.
- **Generate code patches** that address the underlying problems.
- **Create actionable issues** in your issue tracker, complete with findings and the proposed code patch.

### Dartastic RUM — See What Your Users See

Understand how people actually experience your Flutter application.

- **Replay user sessions** in the Dartastic Observatory session player.
- **Choose your replay fidelity**, from privacy-preserving widget outlines to pixel-level reproductions of the user experience.
- **Investigate real user problems** using session replay and production observability data.

![Dartastic RUM Session Replay](https://dartastic.io/img/pub-dev/session-replay.png)

### Dartastic Observatory — Observability Built for Flutter

A complete observability backend where Flutter and Dart are first-class citizens.

- **Flutter-specific dashboards** for application performance, health, and reliability.
- **Alerts and notifications** through email, Slack, and PagerDuty.
- **Dartastic Cloud Observatory** — Start with a 30-day free trial on isolated, shared infrastructure, as low as $39/mo.
- **Dartastic Hosted Observatory** — Run the observability stack in a private managed environment, sized from Mini to Enterprise XL.
- **Dartastic Self-Hosted Observatory** — The whole platform inside your own network. Your keys, your cluster, with nothing leaving your perimeter.

### Dartastic Native OTel Runtime — Native OpenTelemetry Performance

Collect production telemetry without burdening Flutter's main isolate.

- **Native OpenTelemetry runtime** that moves telemetry processing off the main isolate.
- **Native crash reporting** for problems that Dart can't catch.
- **Widget performance diagnostics** to identify janky widgets.
- **On-device PII filtering** before sensitive data leaves your application.
- **Source-level error diagnostics** powered by the Dartastic Symbolizer API.
- **Platform-native metrics** for iOS, Android, and Linux, including iOS MetricKit and Android Vitals.
- **OpenTelemetry compatibility** — Send telemetry to Dartastic Observatory or any OpenTelemetry platform.

### Dartastic Labs — OpenTelemetry Integrations

Instrument more of your application without writing everything yourself.

- **650+ open-source integrations** for Dart and Flutter libraries and services, including Dio, Shelf, Logger, Anthropic, AWS, Azure, and Stripe. Look for otel_* on pub.dev.

### More Dartastic Tools

**[Dartastic Pub](https://dartastic.io/pub)**

A private Dart package registry for sharing packages and plugins with your team, partners, and customers.

**[Dartastic Symbolizer](https://dartastic.io/symbolizer)**

Turn production errors into lines of source code through a web API, while keeping your source code artifacts private.

### Professional Support and Training

Dartastic.io offers commercial support for the open-source `dartastic_opentelemetry` and `dartastic_opentelemetry_api` packages and the complete Dartastic product suite.

- **Professional support** with available around-the-clock coverage and response times under four hours on qualifying plans.
- **OpenTelemetry training** for teams instrumenting Dart, Flutter, mobile, and web applications.

### Open Standards. No Mandatory Backend.

The Dartastic OpenTelemetry API and SDK are open source and standards-based. You can use them independently of Dartastic's commercial services and send telemetry to any compatible OpenTelemetry backend.

Dartastic's commercial products add native performance, advanced diagnostics, session replay, AI-assisted remediation, and managed observability services.

**[Explore Dartastic.io](https://dartastic.io)**

---
<!-- dartastic-header:end -->

OpenTelemetry instrumentation for
[Serverpod](https://serverpod.dev) — server-side complement to the
various client-side wrappers (http, dio, grpc, chopper). One
`http.server` span per endpoint method call, with W3C traceparent
extracted from inbound headers so distributed traces stitch
end-to-end, plus the standard HTTP server metrics. Everything
follows the OpenTelemetry semantic conventions and is standard
OTLP.

```dart
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show OTel;
import 'package:otel_serverpod/otel_serverpod.dart';
import 'package:serverpod/serverpod.dart';

Future<void> run(List<String> args) async {
  // Endpoint + auth come from the standard OTEL_EXPORTER_OTLP_*
  // environment variables.
  await OTel.initialize(serviceName: 'mypod');

  final pod = Serverpod(
    args,
    Protocol(),
    Endpoints(),
    // Database spans (`find person`, `insert order`, ...) per session.
    databaseInterceptor: OtelServerpod.databaseInterceptor,
  );

  // Endpoint spans and request metrics.
  OtelServerpod.install(pod);

  await pod.start();
}
```

This package depends on the OpenTelemetry API only; your app chooses
and initializes the SDK (above, `dartastic_opentelemetry`). Initialize
it *before* `OtelServerpod.install(pod)`: without an SDK the API hands
out no-op tracers and meters, so nothing is recorded.

## What one call gives you, zero config

- One SERVER span per endpoint method call, named
  `POST endpoint.method` (semconv `{method} {route}` form, e.g.
  `POST greeting.hello`) with `http.route = endpoint.method` —
  Serverpod routes `POST /<endpoint>` with the method in the JSON
  body, so the span is renamed once dispatch resolves the route.
- W3C context extraction (`traceparent`/`tracestate`/`baggage`)
  from inbound headers. A client using `otel_http`, `otel_dio`, or
  `otel_chopper` injects those headers automatically, and the
  endpoint span stitches into the same trace.
- `http.server.request.duration` histogram (registry bucket
  advice, labeled by method, route, and status code) and the
  `http.server.active_requests` up-down counter.
- Exceptions are recorded and rethrown, never swallowed. 5xx flips
  span status to Error; 4xx does not (per OTel HTTP semconv).

## Database spans, one more line

`OtelServerpod.databaseInterceptor` is a `Serverpod` constructor
parameter, so `install` cannot retrofit it:

```dart
Serverpod(args, Protocol(), Endpoints(),
    databaseInterceptor: OtelServerpod.databaseInterceptor);
```

Every typed database operation becomes a CLIENT span named
`{operation} {table}` (`find person`, `insert order`) parented to
whatever span is active — the endpoint span for session operations
inside an endpoint call — plus a `db.client.operation.duration`
measurement. `transaction` wraps its callback so inner operations
become children of the transaction span automatically.

### `db.query.text` privacy default

`db.query.text` is stamped ONLY on the `unsafe*` raw-SQL
operations and ONLY when you opt in with
`OtelServerpod.install(pod, captureDbStatements: true)` — raw SQL
can carry sensitive literals, so the default is OFF. The typed CRUD
operations never carry query text.

## Future calls

Each future-call run becomes an INTERNAL span named after the
registered future call, with `code.function.name`. Its database
operations are child spans. Nothing changes in your `FutureCall`
classes; the spans come from the same `databaseInterceptor` line,
plus one diagnostic handler so a call that throws is recorded:

```dart
final pod = Serverpod(
  args,
  Protocol(),
  Endpoints(),
  databaseInterceptor: OtelServerpod.databaseInterceptor,
  experimentalFeatures: ExperimentalFeatures(
    diagnosticEventHandlers: [OtelServerpod.diagnosticEventHandler],
  ),
);
```

Serverpod 4.0 runs future calls through generated wrappers and has
no invoke hook. Each run gets a fresh `FutureCallSession`, though,
and the span follows that session: it opens when Serverpod builds
the session's database, right before the call body, and ends when
Serverpod closes the session. A call that throws is reported by
Serverpod as a diagnostic event, which the handler records on the
span (exception event, `error.type`, Error status).

The call body does not run inside the span's zone, so other client
spans it starts (an HTTP call, say) are not children of it. Database
operations are, because they go through the session.

## What is instrumented, exactly

| Signal | Name                                       | Notes                                                                                                                                                                                                       |
|--------|--------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Span   | `POST {endpoint}.{method}`                 | kind `server`, `http.request.method`, `http.route`, `url.path`, `url.scheme`, `network.protocol.version`, `http.response.status_code`, `rpc.system.name = serverpod`, `rpc.method`, `error.type` on failure |
| Span   | `{operation} {table}` (e.g. `find person`) | kind `client`, `db.system.name`, `db.operation.name`, `db.collection.name`, `server.address`, `server.port`; `db.query.text` only on `unsafe*` ops and only with `captureDbStatements: true` (default off)  |
| Span   | future-call name                           | kind `internal`, `code.function.name`, via `databaseInterceptor` + `diagnosticEventHandler`                                                                                                                 |
| Metric | `http.server.request.duration`             | histogram, seconds, registry bucket advice                                                                                                                                                                  |
| Metric | `http.server.active_requests`              | up-down counter                                                                                                                                                                                             |
| Metric | `db.client.operation.duration`             | histogram, seconds                                                                                                                                                                                          |

Names not covered by the semconv registry enums are exported as
consts on `OtelServerpodSemantics`.

## Caveats

- **Serverpod version**: requires the 4.0 line
  (`>=4.0.0-beta.1 <4.1.0`). Serverpod 3.4.x is not supported —
  the `databaseInterceptor` constructor parameter and the stable
  `Database` surface this package wraps exist only on 4.0.
- **Hot reload (dev mode)** re-initializes Serverpod's endpoint
  connectors, which drops the span naming (`POST greeting.hello`
  reverts to `POST`) until you restart the server. Middleware and
  metrics keep flowing.
- **Websocket method streams** (`MethodStreamConnector`) pass
  through untouched in this release — streaming keeps working,
  stream spans are a tracked follow-up.

## License

Apache 2.0
