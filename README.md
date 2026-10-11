# otel_serverpod

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
