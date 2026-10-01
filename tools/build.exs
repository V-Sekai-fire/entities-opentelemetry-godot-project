# One step, as the pen's tools/build.exs: elixir tools/build.exs [options]
#
# Checks the tools, gets the riscv64 sysroot and the two pinned source trees, generates the OTLP
# message code with protoc's upb plugins, cross-builds telemetry.elf and the planted
# telemetry_planted.elf into project/ at double precision, as the pen's addon is, and imports the
# project when GODOT names an engine.
#
#   --sysroot=<dir>   the riscv64 sysroot (else $RISCV64_SYSROOT, else the workspace's, else fetched)
#   --jobs=N          build parallelism (default: the machine's cores)
#
# Environment: PROTOC_BIN (protoc, protoc-gen-upb, protoc-gen-upb_minitable), GODOT, WEFT_ROOT.
defmodule Build do
  @root Path.expand("..", __DIR__)
  @weft System.get_env("WEFT_ROOT") || Path.expand("../..", @root)
  @protoc_bin System.get_env("PROTOC_BIN") || Path.join(@root, ".pixi/envs/default/bin")
  @sysroot_repo "https://github.com/V-Sekai-fire/interactor-mujoco-sandbox-demo"
  @sysroot_sub "third_party/riscv64-sysroot"
  @sources [
    {"third_party/otlp-proto", "https://github.com/open-telemetry/opentelemetry-proto", "v1.11.1",
     "b3f75588eb23c5fca62264edd05d382de49beb1a", []},
    {"third_party/protobuf", "https://github.com/protocolbuffers/protobuf", "v36.2",
     "2c74169b34066ceb8ddb6b882fcb3fb32d737a55", ["upb", "third_party/utf8_range"]}
  ]
  @protos ~w(collector/trace/v1/trace_service collector/logs/v1/logs_service
             collector/metrics/v1/metrics_service common/v1/common resource/v1/resource trace/v1/trace
             logs/v1/logs metrics/v1/metrics)
  # The planted guest encodes these three fields at numbers no reader expects.
  @plants [
    {"trace/v1/trace.proto", "  string name = 5;", "  string name = 50;"},
    {"logs/v1/logs.proto", "  opentelemetry.proto.common.v1.AnyValue body = 5;",
     "  opentelemetry.proto.common.v1.AnyValue body = 50;"},
    {"metrics/v1/metrics.proto", "    double as_double = 4;", "    double as_double = 40;"}
  ]

  def main(argv) do
    {kv, _, _} = OptionParser.parse(argv, switches: [sysroot: :string, jobs: :integer])
    jobs = kv[:jobs] || System.schedulers_online()
    say("checkout #{@root}")
    tools()
    sysroot = sysroot(kv[:sysroot] || System.get_env("RISCV64_SYSROOT"))
    Enum.each(@sources, &source/1)
    proto_root = Path.join(@root, "third_party/otlp-proto")
    codegen(proto_root, Path.join(@root, "gen/otlp"))
    codegen(plant(proto_root), Path.join(@root, "gen/otlp-planted"))
    elf(sysroot, "build/rv64", "gen/otlp", "telemetry", jobs)
    elf(sysroot, "build/rv64-planted", "gen/otlp-planted", "telemetry_planted", jobs)
    import_project()
    say("done")
  end

  defp tools do
    for t <- ~w(cmake ninja clang++ ld.lld git), do: need(t)
    for t <- ~w(protoc protoc-gen-upb protoc-gen-upb_minitable) do
      File.exists?(Path.join(@protoc_bin, t)) || fail("no #{t} in PROTOC_BIN=#{@protoc_bin}")
    end
    {targets, 0} = System.cmd("clang++", ["--print-targets"])
    unless targets =~ "riscv64", do: fail("clang++ has no riscv64 target")
    {version, 0} = System.cmd(Path.join(@protoc_bin, "protoc"), ["--version"])
    say("tools: ok, #{String.trim(version)}")
  end

  defp sysroot(dir) when is_binary(dir) do
    unless File.exists?(Path.join(dir, "toolchain.cmake")), do: fail("no toolchain.cmake under #{dir}")
    say("sysroot: #{dir}")
    dir
  end

  defp sysroot(nil) do
    placed = Path.join(@weft, "5-repository/riscv64-sysroot")
    if File.exists?(Path.join(placed, "toolchain.cmake")) do
      sysroot(placed)
    else
      dir = Path.join(@root, "build/riscv64-sysroot-src")
      unless File.exists?(Path.join([dir, @sysroot_sub, "toolchain.cmake"])) do
        File.rm_rf!(dir)
        run("git", ~w(clone -q --depth 1 --filter=blob:none --sparse #{@sysroot_repo} #{dir}))
        run("git", ~w(-C #{dir} sparse-checkout set #{@sysroot_sub}))
      end
      sysroot(Path.join(dir, @sysroot_sub))
    end
  end

  defp source({rel, url, tag, sha, sparse}) do
    dir = Path.join(@root, rel)
    unless File.dir?(Path.join(dir, ".git")) do
      filter = if sparse == [], do: [], else: ~w(--filter=blob:none --sparse)
      run("git", ~w(-c advice.detachedHead=false clone -q --depth 1 --branch #{tag}) ++ filter ++ [url, dir])
      if sparse != [], do: run("git", ["-C", dir, "sparse-checkout", "set" | sparse])
    end
    {head, 0} = System.cmd("git", ~w(-C #{dir} rev-parse HEAD))
    unless String.trim(head) == sha, do: fail("#{rel} is at #{String.trim(head)}, not #{tag} (#{sha})")
    say("source: #{rel} #{tag} #{sha}")
  end

  defp plant(proto_root) do
    dst = Path.join(@root, "build/planted-proto")
    File.rm_rf!(dst)
    File.mkdir_p!(dst)
    File.cp_r!(Path.join(proto_root, "opentelemetry"), Path.join(dst, "opentelemetry"))
    for {rel, from, to} <- @plants do
      path = Path.join([dst, "opentelemetry/proto", rel])
      text = File.read!(path)
      hits = length(String.split(text, from <> "\n")) - 1
      unless hits == 1, do: fail("plant #{rel}: #{inspect(from)} matched #{hits} lines, not 1")
      File.write!(path, String.replace(text, from <> "\n", to <> "\n"))
      say("plant: #{rel} #{String.trim(from)} -> #{String.trim(to)}")
    end
    dst
  end

  defp codegen(proto_root, out) do
    File.rm_rf!(out)
    File.mkdir_p!(out)
    bin = @protoc_bin
    args = [
      "--plugin=protoc-gen-upb=#{bin}/protoc-gen-upb",
      "--plugin=protoc-gen-upb_minitable=#{bin}/protoc-gen-upb_minitable",
      "--upb_out=#{out}", "--upb_minitable_out=#{out}", "-I", proto_root
    ] ++ Enum.map(@protos, &"opentelemetry/proto/#{&1}.proto")
    run(Path.join(bin, "protoc"), args)
    files = Path.wildcard(Path.join(out, "**/*.{h,c}"))
    say("codegen: #{length(files)} files in #{Path.relative_to(out, @root)}")
  end

  defp elf(sysroot, build, gen, name, jobs) do
    dir = Path.join(@root, build)
    unless File.exists?(Path.join(dir, "build.ninja")) do
      run("cmake", ~w(-S #{Path.join(@root, "guest")} -B #{dir} -G Ninja
                     -DCMAKE_TOOLCHAIN_FILE=#{Path.join(sysroot, "toolchain.cmake")}
                     -DCMAKE_BUILD_TYPE=Release -DSANDBOX_RISCV_EXT_V=OFF -DDOUBLE_PRECISION=ON
                     -DOTLP_GEN=#{Path.join(@root, gen)} -DELF_NAME=#{name}
                     -DSANDBOX_API_ROOT=#{Path.join(@weft, "2-contract/guest-runtime/vendor/sandbox-api")}))
    end
    run("cmake", ~w(--build #{dir} -- -j#{jobs}))
    out = Path.join(@root, "project/#{name}.elf")
    File.exists?(out) || fail("no #{out}")
    say("elf: project/#{name}.elf #{File.stat!(out).size} bytes")
  end

  defp import_project do
    case System.get_env("GODOT") do
      nil -> say("GODOT is not set; project import skipped")
      godot -> run(godot, ~w(--headless --path #{Path.join(@root, "project")} --import), allow_fail: true)
    end
  end

  defp run(cmd, args, o \\ []) do
    say("$ #{cmd} #{Enum.join(args, " ")}")
    {_, rc} = System.cmd(cmd, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true, cd: @root)
    if rc != 0 and not Keyword.get(o, :allow_fail, false), do: fail("#{cmd} exited #{rc}")
    rc
  end

  defp need(tool), do: System.find_executable(tool) || fail("#{tool} is not on PATH")
  defp say(msg), do: IO.puts("== #{msg}")

  defp fail(msg) do
    IO.puts(:stderr, "build: #{msg}")
    System.halt(1)
  end
end

Build.main(System.argv())
