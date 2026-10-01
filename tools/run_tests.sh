#!/usr/bin/env bash
# The round trip three ways against this prototype's own stores: the guest as built, the planted
# guest that encodes a drifted schema, and the as-built guest posted to a closed port. Exit 0 only
# when the first run passes all nine tests and each planted run fails all three unit tests.
#   GODOT=<engine that loads the addon> [PROJECT=<dir>] [LOGS=<dir>] tools/run_tests.sh [--keep-stores]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:?set GODOT to an engine that loads addons/godot_sandbox}"
PROJECT="${PROJECT:-$HERE/project}"
PROTOC_BIN="${PROTOC_BIN:-$HERE/.pixi/envs/default/bin}"
WEFT_ROOT="${WEFT_ROOT:-$(cd "$HERE/../.." && pwd)}"
if [ ! -e "$PROJECT/addons/godot_sandbox" ]; then
	mkdir -p "$PROJECT/addons"
	ln -s "$WEFT_ROOT/1-transport/meshing-pen/addons/godot_sandbox" "$PROJECT/addons/godot_sandbox"
fi
if [ ! -f "$PROJECT/.godot/extension_list.cfg" ]; then
	"$GODOT" --headless --path "$PROJECT" --import >/dev/null 2>&1 || true
fi
LOGS="${LOGS:-$HERE/build/test-logs}"
PAYLOADS="$LOGS/payloads"
mkdir -p "$LOGS"
rm -rf "$PAYLOADS"

"$HERE/tools/stores.sh" start || exit 1

run() {
	local name="$1"
	shift
	echo "### run: $name"
	"$GODOT" --headless --path "$PROJECT" --script res://tests/telemetry_test.gd -- "$@" 2>&1 |
		grep -v -e '^\[' -e '^Godot Engine' -e '^$' | tee "$LOGS/$name.log"
	local rc=${PIPESTATUS[0]}
	echo "### exit: $name $rc"
	return "$rc"
}

run as-built --dump="$PAYLOADS"
rc_built=$?
echo "### decode: the posted bytes through protoc's own parser"
decode_fail=0
for pair in traces:trace logs:logs metrics:metrics; do
	file="${pair%%:*}"
	sig="${pair##*:}"
	type="opentelemetry.proto.collector.$sig.v1.Export$(tr '[:lower:]' '[:upper:]' <<<"${sig:0:1}")${sig:1}ServiceRequest"
	if "$PROTOC_BIN/protoc" --decode="$type" -I "$HERE/third_party/otlp-proto" \
		"opentelemetry/proto/collector/$sig/v1/${sig}_service.proto" <"$PAYLOADS/$file.bin" >"$LOGS/$file.decoded.txt" 2>&1; then
		echo "decoded $file.bin as $type: $(wc -l <"$LOGS/$file.decoded.txt" | tr -d ' ') lines"
	else
		echo "FAIL decode $file.bin as $type: $(head -3 "$LOGS/$file.decoded.txt")"
		decode_fail=1
	fi
done

run wrong-field --elf=res://telemetry_planted.elf
rc_planted=$?
run closed-port --plant=closed-port
rc_closed=$?

[ "${1:-}" = "--keep-stores" ] || "$HERE/tools/stores.sh" stop

verdict=0
units_failed() { grep -c '^FAIL unit ' "$LOGS/$1.log"; }
echo "### verdict"
if [ "$rc_built" -eq 0 ] && [ "$(grep -c '^PASS ' "$LOGS/as-built.log")" -eq 9 ] && [ "$decode_fail" -eq 0 ]; then
	echo "PASS as-built: exit 0, 9 of 9 tests PASS, 3 payloads decode"
else
	echo "FAIL as-built: exit $rc_built, $(grep -c '^PASS ' "$LOGS/as-built.log") of 9 PASS, decode failures $decode_fail"
	verdict=1
fi
for name in wrong-field closed-port; do
	rc_var="rc_planted"
	[ "$name" = "closed-port" ] && rc_var="rc_closed"
	if [ "${!rc_var}" -ne 0 ] && [ "$(units_failed "$name")" -eq 3 ]; then
		echo "PASS planted $name: exit ${!rc_var}, 3 of 3 unit tests FAIL as they must"
	else
		echo "FAIL planted $name: exit ${!rc_var}, $(units_failed "$name") of 3 unit tests FAIL"
		verdict=1
	fi
done
exit "$verdict"
