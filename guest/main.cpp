// SPDX-License-Identifier: MIT
// telemetry.elf: a tracer provider that encodes OTLP export requests; the host posts the bytes.
#include <api.hpp>

#include <string>
#include <vector>

#include "telemetry.h"

static telemetry::Provider g_provider;

static Variant text(const std::string &s) {
	return Variant(String(s));
}

static Variant bytes(const std::vector<uint8_t> &data) {
	return Variant(PackedArray<uint8_t>(data));
}

static std::string to_attributes(const Dictionary &dict, std::vector<telemetry::Attribute> &out) {
	// A double-precision addon hands back container scalars as scoped indices, so numbers come
	// through packed arrays; elements one at a time, since to_vector() assumes a 24-byte Variant.
	const Array keys = dict.keys().as_array();
	const Array values = dict.values().as_array();
	PackedArray<int64_t> ints(std::vector<int64_t>{});
	PackedArray<double> floats(std::vector<double>{});
	ints("append_array", Variant(values));
	floats("append_array", Variant(values));
	const std::vector<int64_t> int_values = ints.fetch();
	const std::vector<double> float_values = floats.fetch();
	const size_t count = size_t(keys.size());
	if (size_t(values.size()) != count || int_values.size() != count || float_values.size() != count) {
		return "attribute values did not convert one to one";
	}
	for (size_t i = 0; i < count; ++i) {
		const Variant key = keys.at(int(i));
		if (key.get_type() != Variant::STRING && key.get_type() != Variant::STRING_NAME) {
			return "attribute keys must be strings";
		}
		telemetry::Attribute a;
		a.key = key.as_std_string();
		const Variant value = values.at(int(i));
		switch (value.get_type()) {
			case Variant::BOOL:
				a.kind = telemetry::ValueKind::Bool;
				a.bool_value = int_values[i] != 0;
				break;
			case Variant::INT:
				a.kind = telemetry::ValueKind::Int;
				a.int_value = int_values[i];
				break;
			case Variant::FLOAT:
				a.kind = telemetry::ValueKind::Double;
				a.double_value = float_values[i];
				break;
			case Variant::STRING:
			case Variant::STRING_NAME:
				a.kind = telemetry::ValueKind::String;
				a.string_value = value.as_std_string();
				break;
			default:
				return "attribute " + a.key + " is not a bool, int, float or String";
		}
		out.push_back(a);
	}
	return "";
}

static Variant init_tracer_provider(String name, String host, Dictionary attributes) {
	std::vector<telemetry::Attribute> resource;
	const std::string bad = to_attributes(attributes, resource);
	if (!bad.empty()) {
		return text(bad);
	}
	return text(g_provider.init(name.utf8(), host.utf8(), resource));
}

static Variant set_clock(int64_t unix_nano) {
	g_provider.set_clock(uint64_t(unix_nano));
	return Variant();
}

static Variant seed_ids(int64_t seed) {
	g_provider.seed(uint64_t(seed));
	return Variant();
}

static Variant start_span(String name) {
	return text(g_provider.start_span(name.utf8(), ""));
}

static Variant start_span_with_parent(String name, String parent_span_id) {
	return text(g_provider.start_span(name.utf8(), parent_span_id.utf8()));
}

static Variant add_event(String span_id, String event_name) {
	return text(g_provider.add_event(span_id.utf8(), event_name.utf8()));
}

static Variant set_attributes(String span_id, Dictionary attributes) {
	std::vector<telemetry::Attribute> list;
	const std::string bad = to_attributes(attributes, list);
	if (!bad.empty()) {
		return text(bad);
	}
	return text(g_provider.set_attributes(span_id.utf8(), list));
}

static Variant record_error(String span_id, String error) {
	return text(g_provider.record_error(span_id.utf8(), error.utf8()));
}

static Variant end_span(String span_id) {
	return text(g_provider.end_span(span_id.utf8()));
}

static Variant trace_id(String span_id) {
	return text(g_provider.trace_id(span_id.utf8()));
}

static Variant log_record(String severity, String body, Dictionary attributes) {
	std::vector<telemetry::Attribute> list;
	const std::string bad = to_attributes(attributes, list);
	if (!bad.empty()) {
		return text(bad);
	}
	return text(g_provider.log(severity.utf8(), body.utf8(), list));
}

static Variant gauge(String name, double value, Dictionary attributes) {
	std::vector<telemetry::Attribute> list;
	const std::string bad = to_attributes(attributes, list);
	if (!bad.empty()) {
		return text(bad);
	}
	return text(g_provider.gauge(name.utf8(), value, list));
}

static Variant export_traces() {
	return bytes(g_provider.export_traces());
}

static Variant export_logs() {
	return bytes(g_provider.export_logs());
}

static Variant export_metrics() {
	return bytes(g_provider.export_metrics());
}

static Variant last_error() {
	return text(g_provider.last_error());
}

static Variant host() {
	return text(g_provider.host());
}

static Variant shutdown() {
	return text(g_provider.shutdown());
}

int main() {
	ADD_API_FUNCTION(init_tracer_provider, "String", "String name, String host, Dictionary attributes",
			"Starts a provider; the attributes become the resource. \"\" or the reason");
	ADD_API_FUNCTION(set_clock, "void", "int unix_nano", "The time every later record is stamped with");
	ADD_API_FUNCTION(seed_ids, "void", "int seed", "Seeds the trace and span id generator");
	ADD_API_FUNCTION(start_span, "String", "String name", "A root span in a new trace; its id, or \"\"");
	ADD_API_FUNCTION(start_span_with_parent, "String", "String name, String parent_span_id",
			"A child span in its parent's trace; its id, or \"\"");
	ADD_API_FUNCTION(add_event, "String", "String span_id, String event_name", "\"\" or the reason");
	ADD_API_FUNCTION(set_attributes, "String", "String span_id, Dictionary attributes", "\"\" or the reason");
	ADD_API_FUNCTION(record_error, "String", "String span_id, String error", "Error status and event");
	ADD_API_FUNCTION(end_span, "String", "String span_id", "Queues the span for export_traces");
	ADD_API_FUNCTION(trace_id, "String", "String span_id", "The span's trace id, or \"\"");
	add_sandbox_api_function("log", log_record, "String", "String severity, String body, Dictionary attributes",
			"Queues a log record for export_logs");
	ADD_API_FUNCTION(gauge, "String", "String name, float value, Dictionary attributes",
			"Queues a gauge point for export_metrics");
	ADD_API_FUNCTION(export_traces, "PackedByteArray", "", "ExportTraceServiceRequest bytes for the ended spans");
	ADD_API_FUNCTION(export_logs, "PackedByteArray", "", "ExportLogsServiceRequest bytes for the queued logs");
	ADD_API_FUNCTION(export_metrics, "PackedByteArray", "", "ExportMetricsServiceRequest bytes for the gauges");
	ADD_API_FUNCTION(last_error, "String", "", "Why the last call failed");
	ADD_API_FUNCTION(host, "String", "", "The host given to init_tracer_provider");
	ADD_API_FUNCTION(shutdown, "String", "", "Drops the provider; names anything never exported");
	halt();
}
