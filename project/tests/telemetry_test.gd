# Telemetry round trip: telemetry.elf encodes OTLP export requests, this script posts them to the
# trace, log and metric stores and reads every record back. One line per test; exit 1 on any FAIL.
#   godot --headless --path project --script res://tests/telemetry_test.gd -- \
#       [--elf=res://telemetry.elf] [--plant=closed-port] [--trace-wait=90] [--dump=<dir>]
extends SceneTree

const HOST := "127.0.0.1"
const TRACE_PORT := 20428
const LOG_PORT := 19428
const METRIC_PORT := 18428
const CLOSED_PORT := 20499
const TRACE_PATH := "/insert/opentelemetry/v1/traces"
const LOG_PATH := "/insert/opentelemetry/v1/logs"
const METRIC_PATH := "/opentelemetry/v1/metrics"
const SERVICE := "godot-telemetry"
const ABSENT := "<absent>"
const REQUIRED := ["init_tracer_provider", "set_clock", "seed_ids", "start_span", "start_span_with_parent",
		"add_event", "set_attributes", "record_error", "end_span", "trace_id", "log", "gauge", "export_traces",
		"export_logs", "export_metrics", "last_error", "shutdown"]
# Fields the stores add on their own; identity ignores only these.
const SPAN_STORE_FIELDS := ["_msg", "_stream", "_stream_id"]
const LOG_STORE_FIELDS := ["_stream", "_stream_id"]

var failures := 0
var unchecked: PackedStringArray = []


func _initialize() -> void:
	var elf := _arg("elf", "res://telemetry.elf")
	var plant := _arg("plant", "none")
	var trace_wait := float(_arg("trace-wait", "90"))
	var dump := _arg("dump", "")
	print("config: elf=%s plant=%s trace_wait=%ss engine=%s" % [elf, plant, trace_wait,
			Engine.get_version_info().string])

	var sb = _sandbox(elf)
	if sb == null:
		quit(1)
		return

	var crypto := Crypto.new()
	var nonce := crypto.generate_random_bytes(4).hex_encode()
	var id_seed := crypto.generate_random_bytes(8).decode_s64(0) & 0x7fffffffffffffff
	var base := (int(Time.get_unix_time_from_system() * 1000.0) - 2000) * 1000000
	var t := {
		"root_start": base + 111111111, "child_start": base + 222222222, "child_end": base + 333333333,
		"root_end": base + 444444444, "log": base + 555555555, "gauge": base + 666000000,
	}
	print("run: nonce=%s seed=%d base_unix_nano=%d" % [nonce, id_seed, base])

	var resource := {"deployment.environment": "scratch", "run.nonce": nonce}
	var root_attrs := {"fps": 60, "delta": 0.25, "vsync": true, "scene": "res://main.tscn"}
	var child_attrs := {"bodies": 12}
	var log_attrs := {"frame": 1234, "budget_ms": 16.5, "dropped": false, "stage": "physics"}
	var gauge_attrs := {"scene": "main", "gpu": "metal"}
	var span_name := "physics-" + nonce
	var root_name := "frame-" + nonce
	var body := "frame budget exceeded " + nonce
	var metric := "godot_fps_" + nonce
	var gauge_value := 59.75

	var calls := PackedStringArray()
	calls.append(_vm(sb, "init_tracer_provider", [SERVICE, HOST, resource]))
	sb.vmcall("seed_ids", id_seed)
	sb.vmcall("set_clock", t.root_start)
	var root: String = sb.vmcall("start_span", root_name)
	calls.append(_vm(sb, "set_attributes", [root, root_attrs]))
	sb.vmcall("set_clock", t.child_start)
	var child: String = sb.vmcall("start_span_with_parent", span_name, root)
	calls.append(_vm(sb, "add_event", [child, "physics-step-started"]))
	calls.append(_vm(sb, "set_attributes", [child, child_attrs]))
	sb.vmcall("set_clock", t.child_end)
	calls.append(_vm(sb, "end_span", [child]))
	sb.vmcall("set_clock", t.root_end)
	calls.append(_vm(sb, "record_error", [root, "frame over budget"]))
	calls.append(_vm(sb, "end_span", [root]))
	var trace_hex: String = sb.vmcall("trace_id", child)
	var root_trace_hex: String = sb.vmcall("trace_id", root)
	sb.vmcall("set_clock", t.log)
	calls.append(_vm(sb, "log", ["WARN", body, log_attrs]))
	sb.vmcall("set_clock", t.gauge)
	calls.append(_vm(sb, "gauge", [metric, gauge_value, gauge_attrs]))
	var payload := {
		"traces": sb.vmcall("export_traces"), "logs": sb.vmcall("export_logs"),
		"metrics": sb.vmcall("export_metrics"),
	}
	calls.append(_vm(sb, "shutdown", []))
	var guest_ok := root.length() == 16 and child.length() == 16 and trace_hex.length() == 32 \
			and trace_hex == root_trace_hex and "".join(calls) == ""
	print("guest: root=%s child=%s trace=%s calls=%s bytes traces=%d logs=%d metrics=%d" % [root, child,
			trace_hex, "ok" if "".join(calls) == "" else str(calls), payload.traces.size(), payload.logs.size(),
			payload.metrics.size()])
	if not guest_ok:
		print("guest: last_error=%s" % sb.vmcall("last_error"))
	sb.free()

	if dump != "":
		DirAccess.make_dir_recursive_absolute(dump)
		for k in payload:
			var f := FileAccess.open(dump.path_join(k + ".bin"), FileAccess.WRITE)
			f.store_buffer(payload[k])
			f.close()

	var ports := {"traces": TRACE_PORT, "logs": LOG_PORT, "metrics": METRIC_PORT}
	var paths := {"traces": TRACE_PATH, "logs": LOG_PATH, "metrics": METRIC_PATH}
	var posted := {}
	for k in ["traces", "logs", "metrics"]:
		var port: int = CLOSED_PORT if plant == "closed-port" else ports[k]
		var r := _http(port, HTTPClient.METHOD_POST, paths[k], ["Content-Type: application/x-protobuf"],
				payload[k])
		posted[k] = r.ok and int(r.code) / 100 == 2
		print("post %s: %d bytes to %s:%d%s -> %s" % [k, payload[k].size(), HOST, port, paths[k],
				("HTTP %d %s" % [r.code, r.body.strip_edges()]) if r.ok else r.error])

	# No Status message is sent for the child; the wire format defines that as code 0, unset.
	var spans := {
		span_name: {
			"name": span_name, "trace_id": trace_hex, "span_id": child, "parent_span_id": root, "kind": "1",
			"start_time_unix_nano": str(t.child_start), "end_time_unix_nano": str(t.child_end),
			"duration": str(t.child_end - t.child_start), "_time": _rfc3339(t.child_start),
			"span_attr:bodies": "12",
			"event:event_name:0": "physics-step-started", "event:event_time_unix_nano:0": str(t.child_start),
			"status_code": "0", "status_message": ABSENT,
		},
		root_name: {
			"name": root_name, "trace_id": trace_hex, "span_id": root, "parent_span_id": ABSENT, "kind": "1",
			"start_time_unix_nano": str(t.root_start), "end_time_unix_nano": str(t.root_end),
			"duration": str(t.root_end - t.root_start), "_time": _rfc3339(t.root_start),
			"span_attr:fps": "60", "span_attr:delta": "0.25", "span_attr:vsync": "true",
			"span_attr:scene": "res://main.tscn",
			"event:event_name:0": "error", "event:event_time_unix_nano:0": str(t.root_end),
			"status_code": "2", "status_message": "frame over budget",
		},
	}
	for n in spans:
		spans[n].merge({"resource_attr:service.name": SERVICE, "resource_attr:deployment.environment": "scratch",
				"resource_attr:run.nonce": nonce, "scope_name": SERVICE, "scope_version": "1.0.0"})
	var log_expected := {
		"_msg": body, "_time": _rfc3339(t.log), "severity_text": "WARN", "severity_number": "13",
		"frame": "1234", "budget_ms": "16.5", "dropped": "false", "stage": "physics",
		"service.name": SERVICE, "deployment.environment": "scratch", "run.nonce": nonce,
		"scope.name": SERVICE, "scope.version": "1.0.0", "trace_id": ABSENT, "span_id": ABSENT,
	}
	var gauge_expected := {
		"metric.__name__": metric, "metric.scene": "main", "metric.gpu": "metal",
		"metric.service.name": SERVICE, "metric.deployment.environment": "scratch", "metric.run.nonce": nonce,
		"metric.scope.name": SERVICE, "metric.scope.version": "1.0.0",
		"values": str([gauge_value]), "timestamps": str([t.gauge / 1000000]),
	}

	_span_tests(spans, span_name, root_name, nonce, trace_wait, posted.traces)
	_log_tests(log_expected, body, nonce, posted.logs)
	_gauge_tests(gauge_expected, metric, nonce, posted.metrics)

	unchecked.append_array([
		"host() is never called",
		"last_error() is called only when a guest step fails, and none did",
		"error return: init_tracer_provider with an empty name",
		"error return: a record made before set_clock",
		"error return: start_span_with_parent with a malformed or unknown parent id",
		"error return: add_event, set_attributes, record_error or end_span on an unknown or ended span",
		"error return: non-string attribute keys, and values that are not bool, int, float or String",
		"shutdown() with records still queued (its dropped-records message)",
		"export_* with nothing queued (an empty PackedByteArray)",
		"a NULL arena or a failed serialize in the guest",
		"two gauge points with one name (grouped into one Metric)",
		"observed_time_unix_nano: encoded, but the log store does not return it",
		"store-added fields left out of identity: _msg, _stream, _stream_id (traces); _stream, _stream_id (logs)",
		"doubles that need 17 significant digits and ints past 2^53 through the stores (only exact values are sent)",
		"gauge timestamps below millisecond precision (the gauge is sent ms-aligned)",
		"read stability after the stores merge parts (the two reads are about a second apart)",
		"absent parent_span_id and status_code 0 as the stores' spelling of not sent (matched by the OTLP spec only)",
		"the cost of the guest's packed-array attribute path (two host calls and two fetches per Dictionary)",
	])
	print("unchecked (%d):" % unchecked.size())
	for u in unchecked:
		print("  - " + u)
	print("RESULT: %s (%d FAIL)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)


func _span_tests(spans: Dictionary, span_name: String, root_name: String, nonce: String, wait: float,
		posted: bool) -> void:
	var found := {}
	var t0 := Time.get_ticks_msec()
	for n in [span_name, root_name]:
		var left := maxf(0.0, wait - (Time.get_ticks_msec() - t0) / 1000.0)
		found[n] = _poll(TRACE_PORT, "_time:1h name:=\"%s\" | limit 5" % n, left)
		found[n]["waited_ms"] = Time.get_ticks_msec() - t0
	var unit_keys := ["name", "trace_id", "span_id", "start_time_unix_nano"]
	var lines := PackedStringArray()
	var bad := PackedStringArray()
	for n in found:
		var r: Dictionary = found[n]
		if not r.ok or r.rows.size() == 0:
			bad.append("%s: absent after %.0fs (%s)" % [n, r.get("waited_ms", 0) / 1000.0, r.get("error", "0 rows")])
			continue
		var sub := {}
		for k in unit_keys:
			sub[k] = spans[n][k]
		bad.append_array(_compare(sub, r.rows[0]))
		lines.append("%s %s" % [n, _shown(sub, r.rows[0])])
	if not posted:
		bad.append("the post did not succeed")
	_report("unit span", bad, "; ".join(lines))

	var record_found: bool = found[span_name].ok and found[span_name].rows.size() > 0
	if not record_found:
		_report("falsifiable span", PackedStringArray(["precondition: %s was never read back, nothing to compare" % span_name]), "")
	else:
		var wrong: Dictionary = spans[span_name].duplicate()
		wrong["span_attr:bodies"] = "13"
		var caught := _compare(wrong, found[span_name].rows[0])
		var never := _logsql(TRACE_PORT, "_time:1h name:=\"never-sent-%s\" | limit 5" % nonce)
		var fbad := PackedStringArray()
		if not _names(caught, "span_attr:bodies"):
			fbad.append("a wrong expectation (span_attr:bodies=13) was not reported")
		if not never.ok:
			fbad.append("never-sent query failed: " + never.error)
		elif never.rows.size() != 0:
			fbad.append("never-sent-%s read back %d rows" % [nonce, never.rows.size()])
		_report("falsifiable span", fbad, "wrong expectation -> %s; never-sent-%s -> %s rows" % [
				" | ".join(caught), nonce, str(never.rows.size()) if never.ok else "error"])

	var ibad := PackedStringArray()
	var ilines := PackedStringArray()
	for n in [span_name, root_name]:
		var r: Dictionary = found[n]
		if not r.ok or r.rows.size() == 0:
			ibad.append("precondition: %s was never read back" % n)
			continue
		if r.rows.size() != 1:
			ibad.append("%s: %d records, expected exactly 1" % [n, r.rows.size()])
		ibad.append_array(_compare(spans[n], r.rows[0]))
		ibad.append_array(_extras(spans[n], r.rows[0], SPAN_STORE_FIELDS))
		var again := _logsql(TRACE_PORT, "_time:1h name:=\"%s\" | limit 5" % n)
		if not again.ok or again.raw != r.raw:
			ibad.append("%s: second read differs" % n)
		ilines.append("%s: %d fields equal, second read identical=%s" % [n, spans[n].size(),
				str(again.ok and again.raw == r.raw)])
	_report("identity span", ibad, "; ".join(ilines))


func _log_tests(expected: Dictionary, body: String, nonce: String, posted: bool) -> void:
	var query := "_time:1h _msg:=\"%s\" | limit 5" % body
	var r := _poll(LOG_PORT, query, 30.0)
	var have: bool = r.ok and r.rows.size() > 0
	var bad := PackedStringArray()
	var shown := ""
	if not have:
		bad.append("body \"%s\" absent after %.0fs (%s)" % [body, r.get("waited_ms", 0) / 1000.0,
				r.get("error", "0 rows")])
	else:
		var sub := {"_msg": expected["_msg"], "severity_text": expected["severity_text"], "frame": expected["frame"]}
		bad.append_array(_compare(sub, r.rows[0]))
		shown = _shown(sub, r.rows[0])
	if not posted:
		bad.append("the post did not succeed")
	_report("unit log", bad, shown)

	if not have:
		_report("falsifiable log", PackedStringArray(["precondition: the log was never read back, nothing to compare"]), "")
	else:
		var wrong := expected.duplicate()
		wrong["frame"] = "1235"
		var caught := _compare(wrong, r.rows[0])
		var never := _logsql(LOG_PORT, "_time:1h _msg:=\"never sent %s\" | limit 5" % nonce)
		var fbad := PackedStringArray()
		if not _names(caught, "frame"):
			fbad.append("a wrong expectation (frame=1235) was not reported")
		if not never.ok:
			fbad.append("never-sent query failed: " + never.error)
		elif never.rows.size() != 0:
			fbad.append("\"never sent %s\" read back %d rows" % [nonce, never.rows.size()])
		_report("falsifiable log", fbad, "wrong expectation -> %s; \"never sent %s\" -> %s rows" % [
				" | ".join(caught), nonce, str(never.rows.size()) if never.ok else "error"])

	if not have:
		_report("identity log", PackedStringArray(["precondition: the log was never read back"]), "")
	else:
		var ibad := PackedStringArray()
		if r.rows.size() != 1:
			ibad.append("%d records, expected exactly 1" % r.rows.size())
		ibad.append_array(_compare(expected, r.rows[0]))
		ibad.append_array(_extras(expected, r.rows[0], LOG_STORE_FIELDS))
		var again := _logsql(LOG_PORT, query)
		var same: bool = again.ok and again.raw == r.raw
		if not same:
			ibad.append("second read differs")
		_report("identity log", ibad, "%d fields equal (_time=%s), second read identical=%s" % [expected.size(),
				r.rows[0].get("_time", ABSENT), str(same)])


func _gauge_tests(expected: Dictionary, metric: String, nonce: String, posted: bool) -> void:
	var r := _poll_series(metric, 30.0)
	var have: bool = r.ok and r.rows.size() > 0
	var bad := PackedStringArray()
	var shown := ""
	if not have:
		bad.append("series %s absent after %.0fs (%s)" % [metric, r.get("waited_ms", 0) / 1000.0,
				r.get("error", "0 series")])
	else:
		var sub := {"metric.__name__": expected["metric.__name__"], "values": expected["values"],
				"timestamps": expected["timestamps"]}
		bad.append_array(_compare(sub, r.rows[0]))
		shown = _shown(sub, r.rows[0])
	if not posted:
		bad.append("the post did not succeed")
	_report("unit gauge", bad, shown)

	if not have:
		_report("falsifiable gauge", PackedStringArray(["precondition: the series was never read back, nothing to compare"]), "")
	else:
		var wrong := expected.duplicate()
		wrong["values"] = str([59.5])
		var caught := _compare(wrong, r.rows[0])
		var never := _export_series("godot_never_sent_" + nonce)
		var fbad := PackedStringArray()
		if not _names(caught, "values"):
			fbad.append("a wrong expectation (value 59.5) was not reported")
		if not never.ok:
			fbad.append("never-sent query failed: " + never.error)
		elif never.rows.size() != 0:
			fbad.append("godot_never_sent_%s read back %d series" % [nonce, never.rows.size()])
		_report("falsifiable gauge", fbad, "wrong expectation -> %s; godot_never_sent_%s -> %s series" % [
				" | ".join(caught), nonce, str(never.rows.size()) if never.ok else "error"])

	if not have:
		_report("identity gauge", PackedStringArray(["precondition: the series was never read back"]), "")
	else:
		var ibad := PackedStringArray()
		if r.rows.size() != 1:
			ibad.append("%d series, expected exactly 1" % r.rows.size())
		ibad.append_array(_compare(expected, r.rows[0]))
		ibad.append_array(_extras(expected, r.rows[0], []))
		var again := _export_series(metric)
		var same: bool = again.ok and again.raw == r.raw
		if not same:
			ibad.append("second read differs")
		_report("identity gauge", ibad, "%d fields equal (value=%s at %s ms), second read identical=%s" % [
				expected.size(), r.rows[0].get("values", ABSENT), r.rows[0].get("timestamps", ABSENT), str(same)])


func _sandbox(elf: String):
	if not ClassDB.class_exists("Sandbox"):
		_report("setup", PackedStringArray(["the Sandbox class is not registered (addon did not load)"]), "")
		return null
	if not ResourceLoader.exists(elf):
		_report("setup", PackedStringArray(["%s does not exist or was not imported" % elf]), "")
		return null
	var sb = ClassDB.instantiate("Sandbox")
	sb.references_max = 4096
	sb.allocations_max = 1000000
	sb.program = load(elf)
	var missing := PackedStringArray()
	for fn in REQUIRED:
		if not sb.has_function(fn):
			missing.append(fn)
	if not missing.is_empty():
		_report("setup", PackedStringArray(["%s lacks %s" % [elf, ", ".join(missing)]]), "")
		sb.free()
		return null
	return sb


func _vm(sb, fn: String, args: Array) -> String:
	var r = sb.callv("vmcall", [fn] + args)
	return "" if r == null or str(r) == "" else "%s: %s; " % [fn, str(r)]


func _compare(expected: Dictionary, record: Dictionary) -> PackedStringArray:
	var bad := PackedStringArray()
	for k in expected:
		var want := str(expected[k])
		var has := record.has(k)
		var got := str(record[k]) if has else ABSENT
		if want != got:
			bad.append("%s: sent %s, read %s" % [k, want, got])
	return bad


func _names(mismatches: PackedStringArray, key: String) -> bool:
	for m in mismatches:
		if m.begins_with(key + ":"):
			return true
	return false


func _extras(expected: Dictionary, record: Dictionary, allowed: Array) -> PackedStringArray:
	var bad := PackedStringArray()
	for k in record:
		if not expected.has(k) and not allowed.has(k):
			bad.append("%s: never sent, read %s" % [k, str(record[k])])
	return bad


func _shown(expected: Dictionary, record: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in expected:
		parts.append("%s=%s/%s" % [k, str(expected[k]), str(record[k]) if record.has(k) else ABSENT])
	return "(sent/read) " + " ".join(parts)


func _report(test: String, bad: PackedStringArray, detail: String) -> void:
	if bad.is_empty():
		print("PASS %s: %s" % [test, detail])
	else:
		failures += 1
		print("FAIL %s: %s%s" % [test, " | ".join(bad), (" || " + detail) if detail != "" else ""])


func _poll(port: int, query: String, seconds: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		var r := _logsql(port, query)
		r["waited_ms"] = Time.get_ticks_msec() - t0
		if (r.ok and r.rows.size() > 0) or Time.get_ticks_msec() - t0 > int(seconds * 1000.0):
			return r
		OS.delay_msec(1000)
	return {}


func _poll_series(metric: String, seconds: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		var r := _export_series(metric)
		r["waited_ms"] = Time.get_ticks_msec() - t0
		if (r.ok and r.rows.size() > 0) or Time.get_ticks_msec() - t0 > int(seconds * 1000.0):
			return r
		OS.delay_msec(500)
	return {}


func _logsql(port: int, query: String) -> Dictionary:
	var r := _http(port, HTTPClient.METHOD_GET, "/select/logsql/query?query=" + query.uri_encode(), [],
			PackedByteArray())
	if not r.ok:
		return {"ok": false, "error": r.error, "rows": [], "raw": PackedStringArray()}
	if r.code != 200:
		return {"ok": false, "error": "HTTP %d %s" % [r.code, r.body.left(200)], "rows": [], "raw": PackedStringArray()}
	var rows: Array = []
	var raw := PackedStringArray()
	for line in r.body.split("\n", false):
		var v = JSON.parse_string(line)
		if typeof(v) == TYPE_DICTIONARY:
			rows.append(v)
			raw.append(line)
	return {"ok": true, "rows": rows, "raw": raw}


# One flat Dictionary per series: metric.<label>, values and timestamps (as the store wrote them).
func _export_series(metric: String) -> Dictionary:
	var r := _http(METRIC_PORT, HTTPClient.METHOD_GET, "/api/v1/export?match%5B%5D=" + metric.uri_encode(), [],
			PackedByteArray())
	if not r.ok:
		return {"ok": false, "error": r.error, "rows": [], "raw": PackedStringArray()}
	if r.code != 200:
		return {"ok": false, "error": "HTTP %d %s" % [r.code, r.body.left(200)], "rows": [], "raw": PackedStringArray()}
	var rows: Array = []
	var raw := PackedStringArray()
	for line in r.body.split("\n", false):
		var v = JSON.parse_string(line)
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var flat := {}
		for label in v.get("metric", {}):
			flat["metric." + label] = v["metric"][label]
		var ts: Array = []
		for x in v.get("timestamps", []):
			ts.append(int(x))
		flat["values"] = str(v.get("values", []))
		flat["timestamps"] = str(ts)
		rows.append(flat)
		raw.append(line)
	return {"ok": true, "rows": rows, "raw": raw}


func _http(port: int, method: int, path: String, headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var c := HTTPClient.new()
	var err := c.connect_to_host(HOST, port)
	if err != OK:
		return {"ok": false, "error": "connect_to_host: " + error_string(err)}
	var deadline := Time.get_ticks_msec() + 10000
	while c.get_status() == HTTPClient.STATUS_RESOLVING or c.get_status() == HTTPClient.STATUS_CONNECTING:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "error": "connect timeout"}
		OS.delay_msec(2)
	if c.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "error": "cannot connect to %s:%d (HTTPClient status %d)" % [HOST, port, c.get_status()]}
	err = c.request_raw(method, path, headers, body)
	if err != OK:
		return {"ok": false, "error": "request: " + error_string(err)}
	while c.get_status() == HTTPClient.STATUS_REQUESTING:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "error": "request timeout"}
		OS.delay_msec(2)
	if not c.has_response():
		return {"ok": false, "error": "no response (HTTPClient status %d)" % c.get_status()}
	var code := c.get_response_code()
	var out := PackedByteArray()
	while c.get_status() == HTTPClient.STATUS_BODY:
		c.poll()
		var chunk := c.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(1)
		else:
			out.append_array(chunk)
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "error": "body timeout"}
	c.close()
	return {"ok": true, "code": code, "body": out.get_string_from_utf8()}


# The stores print times as RFC 3339 with up to nine fraction digits and trailing zeros dropped.
static func _rfc3339(unix_nano: int) -> String:
	var s := Time.get_datetime_string_from_unix_time(unix_nano / 1000000000)
	var frac := "%09d" % (unix_nano % 1000000000)
	while frac.ends_with("0"):
		frac = frac.substr(0, frac.length() - 1)
	return s + ("." + frac if frac != "" else "") + "Z"


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.substr(name.length() + 3)
	return fallback
