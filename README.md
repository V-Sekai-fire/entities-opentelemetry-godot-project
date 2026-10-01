# opentelemetry-godot-project

A godot-sandbox guest that encodes Godot's spans, logs and gauges as OTLP, tested round trip against the telemetry stores.

`project/telemetry.elf` is the C++ guest. Its OTLP messages are generated from the official `.proto`
schema (v1.11.1) by `protoc` 36.2's upb generators, and the upb runtime is compiled in, so no encoder is
written by hand. It keeps the archived module's API (`init_tracer_provider`, `start_span`,
`start_span_with_parent`, `add_event`, `set_attributes`, `record_error`, `end_span`, `shutdown`) and adds
`log`, `gauge`, `set_clock`, `seed_ids` and `export_traces` / `export_logs` / `export_metrics`, which
return the request bytes. Guests have no sockets, so the host posts them.

## Build

    pixi install
    pixi run sh -c 'PATH=<clang with a riscv64 target>:$PATH elixir tools/build.exs'

The build fetches the schema and protobuf at pinned commits, generates the code, and cross-builds
`telemetry.elf` and `telemetry_planted.elf` (the same guest with three fields renumbered) against the
manifest's `5-repository/riscv64-sysroot` and `contract-guest-runtime`'s sandbox API. Two builds give
the same bytes.

## Test

    GODOT=<an engine that loads the pen's godot_sandbox addon> tools/run_tests.sh

The run starts the three stores from pinned, sha256-checked releases. It then makes three runs:
- **as built:** a span, a log and a gauge each pass a unit, a falsifiable and an identity test;
- **planted wrong-field guest:** the three unit tests must fail;
- **as built, posted to a closed port:** the three unit tests must fail.

It exits 0 only when all three runs go that way. The posted bytes also go through `protoc --decode`.

The pen's addon is double-precision, and godot-sandbox there corrupts numbers read out of a Dictionary
or Array. The guest reads keys one at a time and numbers through packed arrays until the addon's fix
lands.
