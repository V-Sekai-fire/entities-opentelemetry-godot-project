// SPDX-License-Identifier: MIT
#include "telemetry.h"

#include <cstring>

#include "opentelemetry/proto/collector/logs/v1/logs_service.upb.h"
#include "opentelemetry/proto/collector/metrics/v1/metrics_service.upb.h"
#include "opentelemetry/proto/collector/trace/v1/trace_service.upb.h"
#include "opentelemetry/proto/common/v1/common.upb.h"
#include "opentelemetry/proto/logs/v1/logs.upb.h"
#include "opentelemetry/proto/metrics/v1/metrics.upb.h"
#include "opentelemetry/proto/resource/v1/resource.upb.h"
#include "opentelemetry/proto/trace/v1/trace.upb.h"
#include "upb/mem/arena.h"

namespace telemetry {

namespace {

using AnyValue = opentelemetry_proto_common_v1_AnyValue;
using KeyValue = opentelemetry_proto_common_v1_KeyValue;
using Scope = opentelemetry_proto_common_v1_InstrumentationScope;
using Resource = opentelemetry_proto_resource_v1_Resource;
using TraceRequest = opentelemetry_proto_collector_trace_v1_ExportTraceServiceRequest;
using ResourceSpans = opentelemetry_proto_trace_v1_ResourceSpans;
using ScopeSpans = opentelemetry_proto_trace_v1_ScopeSpans;
using WireSpan = opentelemetry_proto_trace_v1_Span;
using WireEvent = opentelemetry_proto_trace_v1_Span_Event;
using WireStatus = opentelemetry_proto_trace_v1_Status;
using LogsRequest = opentelemetry_proto_collector_logs_v1_ExportLogsServiceRequest;
using ResourceLogs = opentelemetry_proto_logs_v1_ResourceLogs;
using ScopeLogs = opentelemetry_proto_logs_v1_ScopeLogs;
using WireLog = opentelemetry_proto_logs_v1_LogRecord;
using MetricsRequest = opentelemetry_proto_collector_metrics_v1_ExportMetricsServiceRequest;
using ResourceMetrics = opentelemetry_proto_metrics_v1_ResourceMetrics;
using ScopeMetrics = opentelemetry_proto_metrics_v1_ScopeMetrics;
using WireMetric = opentelemetry_proto_metrics_v1_Metric;
using WireGauge = opentelemetry_proto_metrics_v1_Gauge;
using WirePoint = opentelemetry_proto_metrics_v1_NumberDataPoint;

const std::string kScopeVersion = "1.0.0";

upb_StringView view(const std::string &s) {
	return upb_StringView_FromDataAndSize(s.data(), s.size());
}

void set_value(AnyValue *value, const Attribute &a) {
	switch (a.kind) {
		case ValueKind::String:
			opentelemetry_proto_common_v1_AnyValue_set_string_value(value, view(a.string_value));
			break;
		case ValueKind::Bool:
			opentelemetry_proto_common_v1_AnyValue_set_bool_value(value, a.bool_value);
			break;
		case ValueKind::Int:
			opentelemetry_proto_common_v1_AnyValue_set_int_value(value, a.int_value);
			break;
		case ValueKind::Double:
			opentelemetry_proto_common_v1_AnyValue_set_double_value(value, a.double_value);
			break;
	}
}

template <typename Message>
void add_attributes(Message *message, KeyValue *(*add)(Message *, upb_Arena *),
		const std::vector<Attribute> &attributes, upb_Arena *arena) {
	for (const Attribute &a : attributes) {
		KeyValue *kv = add(message, arena);
		opentelemetry_proto_common_v1_KeyValue_set_key(kv, view(a.key));
		set_value(opentelemetry_proto_common_v1_KeyValue_mutable_value(kv, arena), a);
	}
}

void set_scope(Scope *scope, const std::string &name) {
	opentelemetry_proto_common_v1_InstrumentationScope_set_name(scope, view(name));
	opentelemetry_proto_common_v1_InstrumentationScope_set_version(scope, view(kScopeVersion));
}

std::vector<uint8_t> copy_out(const char *data, size_t size) {
	const uint8_t *begin = reinterpret_cast<const uint8_t *>(data);
	return std::vector<uint8_t>(begin, begin + size);
}

void merge(std::vector<Attribute> &into, const std::vector<Attribute> &from) {
	for (const Attribute &a : from) {
		bool replaced = false;
		for (Attribute &existing : into) {
			if (existing.key == a.key) {
				existing = a;
				replaced = true;
				break;
			}
		}
		if (!replaced) {
			into.push_back(a);
		}
	}
}

} // namespace

std::string to_hex(const std::string &bytes) {
	static const char digits[] = "0123456789abcdef";
	std::string out;
	out.reserve(bytes.size() * 2);
	for (char c : bytes) {
		const uint8_t b = uint8_t(c);
		out.push_back(digits[b >> 4]);
		out.push_back(digits[b & 15]);
	}
	return out;
}

bool from_hex(const std::string &hex, std::string &bytes) {
	if (hex.size() % 2 != 0) {
		return false;
	}
	bytes.clear();
	for (size_t i = 0; i < hex.size(); i += 2) {
		int value = 0;
		for (size_t j = i; j < i + 2; ++j) {
			const char c = hex[j];
			int nibble = -1;
			if (c >= '0' && c <= '9') {
				nibble = c - '0';
			} else if (c >= 'a' && c <= 'f') {
				nibble = c - 'a' + 10;
			} else if (c >= 'A' && c <= 'F') {
				nibble = c - 'A' + 10;
			}
			if (nibble < 0) {
				return false;
			}
			value = value * 16 + nibble;
		}
		bytes.push_back(char(value));
	}
	return true;
}

int severity_number(const std::string &severity) {
	std::string s;
	for (char c : severity) {
		s.push_back((c >= 'a' && c <= 'z') ? char(c - 32) : c);
	}
	if (s == "TRACE") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_TRACE;
	}
	if (s == "DEBUG") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_DEBUG;
	}
	if (s == "INFO") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_INFO;
	}
	if (s == "WARN" || s == "WARNING") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_WARN;
	}
	if (s == "ERROR") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_ERROR;
	}
	if (s == "FATAL") {
		return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_FATAL;
	}
	return opentelemetry_proto_logs_v1_SEVERITY_NUMBER_UNSPECIFIED;
}

std::string Provider::fail(const std::string &reason) {
	error_ = reason;
	return reason;
}

std::string Provider::init(const std::string &name, const std::string &host, const std::vector<Attribute> &resource) {
	if (name.empty()) {
		return fail("the provider name is empty");
	}
	name_ = name;
	host_ = host;
	resource_.clear();
	bool has_service = false;
	for (const Attribute &a : resource) {
		has_service = has_service || a.key == "service.name";
	}
	if (!has_service) {
		Attribute service;
		service.key = "service.name";
		service.string_value = name;
		resource_.push_back(service);
	}
	merge(resource_, resource);
	open_.clear();
	ended_.clear();
	logs_.clear();
	gauges_.clear();
	initialized_ = true;
	error_.clear();
	return "";
}

void Provider::set_clock(uint64_t unix_nano) {
	clock_ = unix_nano;
}

void Provider::seed(uint64_t seed) {
	rng_ = seed;
}

std::string Provider::ready() const {
	if (!initialized_) {
		return "init_tracer_provider was not called";
	}
	if (clock_ == 0) {
		return "set_clock was not called";
	}
	return "";
}

// splitmix64; an all-zero id is invalid on the wire, so it is drawn again.
std::string Provider::random_id(size_t bytes) {
	std::string id;
	while (true) {
		id.clear();
		while (id.size() < bytes) {
			rng_ += 0x9e3779b97f4a7c15ull;
			uint64_t z = rng_;
			z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
			z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
			z ^= z >> 31;
			for (int shift = 56; shift >= 0 && id.size() < bytes; shift -= 8) {
				id.push_back(char((z >> shift) & 0xff));
			}
		}
		if (id.find_first_not_of('\0') != std::string::npos) {
			return id;
		}
	}
}

Span *Provider::find_open(const std::string &span_id) {
	for (Span &s : open_) {
		if (s.span_id == span_id) {
			return &s;
		}
	}
	return nullptr;
}

const Span *Provider::find_any(const std::string &span_id) const {
	for (const Span &s : open_) {
		if (s.span_id == span_id) {
			return &s;
		}
	}
	for (const Span &s : ended_) {
		if (s.span_id == span_id) {
			return &s;
		}
	}
	return nullptr;
}

std::string Provider::start_span(const std::string &name, const std::string &parent_hex) {
	const std::string not_ready = ready();
	if (!not_ready.empty()) {
		fail(not_ready);
		return "";
	}
	Span span;
	span.name = name;
	if (!parent_hex.empty()) {
		std::string parent;
		if (parent_hex.size() != 16 || !from_hex(parent_hex, parent)) {
			fail("parent span id is not 16 hex digits: " + parent_hex);
			return "";
		}
		const Span *p = find_any(parent);
		if (p == nullptr) {
			fail("unknown parent span " + parent_hex);
			return "";
		}
		span.trace_id = p->trace_id;
		span.parent_span_id = parent;
	} else {
		span.trace_id = random_id(16);
	}
	span.span_id = random_id(8);
	span.start_time_unix_nano = clock_;
	open_.push_back(span);
	error_.clear();
	return to_hex(span.span_id);
}

std::string Provider::add_event(const std::string &span_hex, const std::string &event_name) {
	std::string id;
	Span *span = from_hex(span_hex, id) ? find_open(id) : nullptr;
	if (span == nullptr) {
		return fail("no open span " + span_hex);
	}
	Event e;
	e.name = event_name;
	e.time_unix_nano = clock_;
	span->events.push_back(e);
	return "";
}

std::string Provider::set_attributes(const std::string &span_hex, const std::vector<Attribute> &attributes) {
	std::string id;
	Span *span = from_hex(span_hex, id) ? find_open(id) : nullptr;
	if (span == nullptr) {
		return fail("no open span " + span_hex);
	}
	merge(span->attributes, attributes);
	return "";
}

std::string Provider::record_error(const std::string &span_hex, const std::string &error) {
	std::string id;
	Span *span = from_hex(span_hex, id) ? find_open(id) : nullptr;
	if (span == nullptr) {
		return fail("no open span " + span_hex);
	}
	span->error = true;
	span->status_message = error;
	Event e;
	e.name = "error";
	e.time_unix_nano = clock_;
	span->events.push_back(e);
	return "";
}

std::string Provider::end_span(const std::string &span_hex) {
	std::string id;
	if (!from_hex(span_hex, id)) {
		return fail("no open span " + span_hex);
	}
	for (size_t i = 0; i < open_.size(); ++i) {
		if (open_[i].span_id == id) {
			open_[i].end_time_unix_nano = clock_;
			ended_.push_back(open_[i]);
			open_.erase(open_.begin() + long(i));
			return "";
		}
	}
	return fail("no open span " + span_hex);
}

std::string Provider::trace_id(const std::string &span_hex) const {
	std::string id;
	const Span *span = from_hex(span_hex, id) ? find_any(id) : nullptr;
	return span == nullptr ? std::string() : to_hex(span->trace_id);
}

std::string Provider::log(const std::string &severity, const std::string &body, const std::vector<Attribute> &attributes) {
	const std::string not_ready = ready();
	if (!not_ready.empty()) {
		return fail(not_ready);
	}
	LogRecord r;
	r.time_unix_nano = clock_;
	r.severity_number = severity_number(severity);
	r.severity_text = severity;
	r.body = body;
	r.attributes = attributes;
	logs_.push_back(r);
	return "";
}

std::string Provider::gauge(const std::string &name, double value, const std::vector<Attribute> &attributes) {
	const std::string not_ready = ready();
	if (!not_ready.empty()) {
		return fail(not_ready);
	}
	if (name.empty()) {
		return fail("the gauge name is empty");
	}
	GaugePoint p;
	p.name = name;
	p.value = value;
	p.time_unix_nano = clock_;
	p.attributes = attributes;
	gauges_.push_back(p);
	return "";
}

std::vector<uint8_t> Provider::export_traces() {
	std::vector<uint8_t> out;
	if (ended_.empty()) {
		return out;
	}
	upb_Arena *arena = upb_Arena_New();
	TraceRequest *request = opentelemetry_proto_collector_trace_v1_ExportTraceServiceRequest_new(arena);
	ResourceSpans *rs = opentelemetry_proto_collector_trace_v1_ExportTraceServiceRequest_add_resource_spans(request, arena);
	Resource *resource = opentelemetry_proto_trace_v1_ResourceSpans_mutable_resource(rs, arena);
	add_attributes(resource, opentelemetry_proto_resource_v1_Resource_add_attributes, resource_, arena);
	ScopeSpans *ss = opentelemetry_proto_trace_v1_ResourceSpans_add_scope_spans(rs, arena);
	set_scope(opentelemetry_proto_trace_v1_ScopeSpans_mutable_scope(ss, arena), name_);
	for (const Span &s : ended_) {
		WireSpan *span = opentelemetry_proto_trace_v1_ScopeSpans_add_spans(ss, arena);
		opentelemetry_proto_trace_v1_Span_set_trace_id(span, view(s.trace_id));
		opentelemetry_proto_trace_v1_Span_set_span_id(span, view(s.span_id));
		if (!s.parent_span_id.empty()) {
			opentelemetry_proto_trace_v1_Span_set_parent_span_id(span, view(s.parent_span_id));
		}
		opentelemetry_proto_trace_v1_Span_set_name(span, view(s.name));
		opentelemetry_proto_trace_v1_Span_set_kind(span, opentelemetry_proto_trace_v1_Span_SPAN_KIND_INTERNAL);
		opentelemetry_proto_trace_v1_Span_set_start_time_unix_nano(span, s.start_time_unix_nano);
		opentelemetry_proto_trace_v1_Span_set_end_time_unix_nano(span, s.end_time_unix_nano);
		add_attributes(span, opentelemetry_proto_trace_v1_Span_add_attributes, s.attributes, arena);
		for (const Event &e : s.events) {
			WireEvent *event = opentelemetry_proto_trace_v1_Span_add_events(span, arena);
			opentelemetry_proto_trace_v1_Span_Event_set_time_unix_nano(event, e.time_unix_nano);
			opentelemetry_proto_trace_v1_Span_Event_set_name(event, view(e.name));
		}
		if (s.error) {
			WireStatus *status = opentelemetry_proto_trace_v1_Span_mutable_status(span, arena);
			opentelemetry_proto_trace_v1_Status_set_code(status, opentelemetry_proto_trace_v1_Status_STATUS_CODE_ERROR);
			opentelemetry_proto_trace_v1_Status_set_message(status, view(s.status_message));
		}
	}
	size_t size = 0;
	const char *data = opentelemetry_proto_collector_trace_v1_ExportTraceServiceRequest_serialize(request, arena, &size);
	if (data == nullptr) {
		fail("the trace request did not serialize");
	} else {
		out = copy_out(data, size);
		ended_.clear();
	}
	upb_Arena_Free(arena);
	return out;
}

std::vector<uint8_t> Provider::export_logs() {
	std::vector<uint8_t> out;
	if (logs_.empty()) {
		return out;
	}
	upb_Arena *arena = upb_Arena_New();
	LogsRequest *request = opentelemetry_proto_collector_logs_v1_ExportLogsServiceRequest_new(arena);
	ResourceLogs *rl = opentelemetry_proto_collector_logs_v1_ExportLogsServiceRequest_add_resource_logs(request, arena);
	Resource *resource = opentelemetry_proto_logs_v1_ResourceLogs_mutable_resource(rl, arena);
	add_attributes(resource, opentelemetry_proto_resource_v1_Resource_add_attributes, resource_, arena);
	ScopeLogs *sl = opentelemetry_proto_logs_v1_ResourceLogs_add_scope_logs(rl, arena);
	set_scope(opentelemetry_proto_logs_v1_ScopeLogs_mutable_scope(sl, arena), name_);
	for (const LogRecord &r : logs_) {
		WireLog *log = opentelemetry_proto_logs_v1_ScopeLogs_add_log_records(sl, arena);
		opentelemetry_proto_logs_v1_LogRecord_set_time_unix_nano(log, r.time_unix_nano);
		opentelemetry_proto_logs_v1_LogRecord_set_observed_time_unix_nano(log, r.time_unix_nano);
		opentelemetry_proto_logs_v1_LogRecord_set_severity_number(log, r.severity_number);
		opentelemetry_proto_logs_v1_LogRecord_set_severity_text(log, view(r.severity_text));
		AnyValue *body = opentelemetry_proto_logs_v1_LogRecord_mutable_body(log, arena);
		opentelemetry_proto_common_v1_AnyValue_set_string_value(body, view(r.body));
		add_attributes(log, opentelemetry_proto_logs_v1_LogRecord_add_attributes, r.attributes, arena);
	}
	size_t size = 0;
	const char *data = opentelemetry_proto_collector_logs_v1_ExportLogsServiceRequest_serialize(request, arena, &size);
	if (data == nullptr) {
		fail("the logs request did not serialize");
	} else {
		out = copy_out(data, size);
		logs_.clear();
	}
	upb_Arena_Free(arena);
	return out;
}

std::vector<uint8_t> Provider::export_metrics() {
	std::vector<uint8_t> out;
	if (gauges_.empty()) {
		return out;
	}
	upb_Arena *arena = upb_Arena_New();
	MetricsRequest *request = opentelemetry_proto_collector_metrics_v1_ExportMetricsServiceRequest_new(arena);
	ResourceMetrics *rm = opentelemetry_proto_collector_metrics_v1_ExportMetricsServiceRequest_add_resource_metrics(request, arena);
	Resource *resource = opentelemetry_proto_metrics_v1_ResourceMetrics_mutable_resource(rm, arena);
	add_attributes(resource, opentelemetry_proto_resource_v1_Resource_add_attributes, resource_, arena);
	ScopeMetrics *sm = opentelemetry_proto_metrics_v1_ResourceMetrics_add_scope_metrics(rm, arena);
	set_scope(opentelemetry_proto_metrics_v1_ScopeMetrics_mutable_scope(sm, arena), name_);
	std::vector<std::string> names;
	std::vector<WireGauge *> metrics;
	for (const GaugePoint &p : gauges_) {
		WireGauge *gauge = nullptr;
		for (size_t i = 0; i < names.size(); ++i) {
			if (names[i] == p.name) {
				gauge = metrics[i];
			}
		}
		if (gauge == nullptr) {
			WireMetric *metric = opentelemetry_proto_metrics_v1_ScopeMetrics_add_metrics(sm, arena);
			opentelemetry_proto_metrics_v1_Metric_set_name(metric, view(p.name));
			gauge = opentelemetry_proto_metrics_v1_Metric_mutable_gauge(metric, arena);
			names.push_back(p.name);
			metrics.push_back(gauge);
		}
		WirePoint *point = opentelemetry_proto_metrics_v1_Gauge_add_data_points(gauge, arena);
		opentelemetry_proto_metrics_v1_NumberDataPoint_set_time_unix_nano(point, p.time_unix_nano);
		opentelemetry_proto_metrics_v1_NumberDataPoint_set_as_double(point, p.value);
		add_attributes(point, opentelemetry_proto_metrics_v1_NumberDataPoint_add_attributes, p.attributes, arena);
	}
	size_t size = 0;
	const char *data = opentelemetry_proto_collector_metrics_v1_ExportMetricsServiceRequest_serialize(request, arena, &size);
	if (data == nullptr) {
		fail("the metrics request did not serialize");
	} else {
		out = copy_out(data, size);
		gauges_.clear();
	}
	upb_Arena_Free(arena);
	return out;
}

std::string Provider::shutdown() {
	const size_t pending = open_.size() + ended_.size() + logs_.size() + gauges_.size();
	std::string result;
	if (pending > 0) {
		result = "dropped " + std::to_string(open_.size()) + " open spans, " + std::to_string(ended_.size()) +
				" ended spans, " + std::to_string(logs_.size()) + " logs and " + std::to_string(gauges_.size()) +
				" gauge points that were never exported";
	}
	open_.clear();
	ended_.clear();
	logs_.clear();
	gauges_.clear();
	initialized_ = false;
	clock_ = 0;
	return result;
}

} // namespace telemetry
