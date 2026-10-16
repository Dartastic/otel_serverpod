# Changelog

## [0.3.1-wip]

### Changed

- README: standard header naming the instrumented library, its supported platforms and project links; pubspec description to match.

## [0.3.0] - 2026-10-11

### Added

- Future-call spans for Serverpod 4.0. Each run is an INTERNAL span
  named after the future call, opened by
  `OtelServerpod.databaseInterceptor` when Serverpod builds the call's
  session and ended when the session closes. The call's database
  operations are its children.
- `OtelServerpod.diagnosticEventHandler`: pass it in
  `ExperimentalFeatures(diagnosticEventHandlers: ...)` so a future call
  that throws records the exception and ends with Error status.

### Removed

- `OtelFutureCall`. Serverpod 4.0 no longer calls `FutureCall.invoke`,
  so its spans never fired on 4.0 releases. Extend `FutureCall` again;
  the spans now come from the database interceptor.

### Changed

- **Breaking:** `OtelServerpod.install` no longer throws when no SDK is
  initialized; this package depends on the API only and the app
  initializes the SDK. Without `install`, `databaseInterceptor` leaves
  the database unwrapped and reports the mistake through the
  OpenTelemetry error handler instead of throwing `StateError`.
- Inbound context is extracted with the app's configured propagators
  (`OTelAPI.textMapPropagator`: W3C trace context and baggage by
  default, `OTEL_PROPAGATORS` to change them).
- `http.server.request.duration` passes its bucket boundaries as
  `InstrumentAdvisory(explicitBucketBoundaries: ...)`.
- Requires `dartastic_opentelemetry_api >=1.0.0-rc.4 <1.0.0-rc.5`.
- **Breaking:** depends on `dartastic_opentelemetry_api` only, no
  longer on the SDK. The application chooses and initializes the
  OpenTelemetry SDK. Parameters and fields typed with SDK classes
  now use the API types (`APITracer`, `APISpan`, `APILogger`, ...);
  SDK instances are still accepted wherever an API type is expected.

## [0.2.0] - 2026-08-10

## [0.1.0-beta.1] - 2026-08-04

### Added

- `OtelServerpod.install(pod)` — one call installs, on the Serverpod 4.0
  line:
  - W3C context extraction (`traceparent`/`tracestate`/`baggage`) and one
    `http.server` span per endpoint method call, named
    `POST endpoint.method` with `http.route = endpoint.method` and the
    `rpc.system.name`/`rpc.method` registry attributes;
  - `http.server.request.duration` (registry bucket advice) and
    `http.server.active_requests` metrics.
- `OtelServerpod.databaseInterceptor` — pass to the
  `Serverpod(databaseInterceptor:)` constructor parameter for `db.*` client
  spans (`find person`, `insert order`, ...) and
  `db.client.operation.duration` per typed database operation.
  `db.query.text` only on `unsafe*` raw-SQL operations and only with
  `captureDbStatements: true` (privacy default OFF).
- `OtelFutureCall` — one-line-per-call traced `FutureCall` base class
  (`extends OtelFutureCall`, override `run` instead of `invoke`).
- `OtelServerpodSemantics` — exported consts for every emitted name not in
  the rc.1 semconv enums.

### Known limitations

- `MethodStreamConnector` (websocket method streams) passes through
  unwrapped — streaming works, stream spans are a tracked follow-up.
- Dev-mode hot reload re-initializes Serverpod's connectors, dropping the
  endpoint span names until restart; middleware and metrics survive.
- Serverpod 3.4.x is not supported: the `databaseInterceptor` constructor
  parameter and the stable `Database` surface this package wraps exist only
  on the 4.0 line (constraint `>=4.0.0-beta.1 <4.1.0`, capped because
  upstream reserves the right to break the Database API in minor bumps).
