# entities-opentelemetry-godot-project

A godot-sandbox guest that encodes the engine's spans, logs and gauges as OTLP, tested round trip against the telemetry stores.

## What it is for

The guest's OTLP messages are generated from the official schema with `protoc`'s upb generators, so no encoder is written by hand. Guests have no sockets, so the guest returns request bytes and the host posts them. The test passes only when the guest as built round-trips and the planted failures fail.

## Build and run

With a `clang++` that has a riscv64 target on `PATH`:

```sh
pixi install
pixi run elixir tools/build.exs
GODOT=<an engine that loads the godot_sandbox addon> tools/run_tests.sh
```

## Licence

MIT; see `LICENSE`.
