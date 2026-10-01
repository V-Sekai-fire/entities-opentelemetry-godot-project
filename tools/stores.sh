#!/usr/bin/env bash
# Start, stop or check this prototype's three telemetry stores (never the 8428/9428/10428 set).
#   tools/stores.sh start|stop|status
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${STORE_BIN:-$HERE/third_party/victoria}"
RUN="$HERE/stores"
STORES="metrics:victoria-metrics-prod:18428 logs:victoria-logs-prod:19428 traces:victoria-traces-prod:20428"

# The three stores' release archives for this host, each checked against its sha256.
fetch() {
	case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) plat=darwin-arm64 sums="e2092b103d3f874d8d52fecb42ee35c0d73a3b27ee6cc5b73892d3b18e8e26ce bc882ae04989b7827daaaf397f6d245dcc6cad1593f14e5481c40bbd77c1c35e 4bd3dbe20f73784567efd6ad07da2c6286d83365f7a800b805d1ce8040857858" ;;
	Linux-x86_64) plat=linux-amd64 sums="1b495bde563825cf83dc7c0425a9d8fa03e7214858e0949f9177efc6bb1f8bfc 8ad858111778b211a98729dca1bd640edbd06c4d5b2acece8e040be0c1aa5a83 67be031fb00635929b2d02a6e2ce7e5ebc8b2929f8e0d79fb54ab48bff0ca966" ;;
	*) echo "FAIL: no pinned store release for $(uname -s)-$(uname -m); set STORE_BIN"; exit 1 ;;
	esac
	mkdir -p "$BIN"
	set -- $sums
	for spec in "VictoriaMetrics victoria-metrics v1.153.0" "VictoriaLogs victoria-logs v1.51.1" "VictoriaTraces victoria-traces v0.12.0"; do
		read -r repo exe ver <<<"$spec"
		[ -x "$BIN/$exe-prod" ] && { shift; continue; }
		curl -fsSL -o "$BIN/pkg.tar.gz" "https://github.com/VictoriaMetrics/$repo/releases/download/$ver/$exe-$plat-$ver.tar.gz"
		echo "$1  $BIN/pkg.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "FAIL: $exe $ver sha256 mismatch"; exit 1; }
		tar -xzf "$BIN/pkg.tar.gz" -C "$BIN" && rm "$BIN/pkg.tar.gz"
		shift
	done
}

start() {
	[ -n "${STORE_BIN:-}" ] || fetch
	for s in $STORES; do
		IFS=: read -r name exe port <<<"$s"
		if [ -f "$RUN/$name.pid" ] && kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
			echo "$name: already running (pid $(cat "$RUN/$name.pid"))"; continue
		fi
		mkdir -p "$RUN/data/$name"
		nohup "$BIN/$exe" -storageDataPath="$RUN/data/$name" -httpListenAddr="127.0.0.1:$port" >"$RUN/$name.log" 2>&1 &
		echo $! >"$RUN/$name.pid"
	done
	for s in $STORES; do
		IFS=: read -r name exe port <<<"$s"
		ok=0
		for _ in $(seq 1 50); do
			if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ok=1; break; fi
			sleep 0.2
		done
		[ "$ok" = 1 ] || { echo "$name: FAIL, no /health on $port"; tail -5 "$RUN/$name.log"; exit 1; }
		echo "$name: up on 127.0.0.1:$port (pid $(cat "$RUN/$name.pid"))"
	done
}

stop() {
	for s in $STORES; do
		IFS=: read -r name exe port <<<"$s"
		if [ -f "$RUN/$name.pid" ]; then
			pid="$(cat "$RUN/$name.pid")"
			if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "$name: stopped pid $pid"; else echo "$name: pid $pid not running"; fi
			rm -f "$RUN/$name.pid"
		else
			echo "$name: no pidfile"
		fi
	done
}

status() {
	for s in $STORES; do
		IFS=: read -r name exe port <<<"$s"
		if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then echo "$name: up on $port"; else echo "$name: down on $port"; fi
	done
}

case "${1:-status}" in
	start) start ;;
	stop) stop ;;
	status) status ;;
	*) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
