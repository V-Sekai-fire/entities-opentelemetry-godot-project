// SPDX-License-Identifier: MIT
// The tracer provider state behind the guest's public functions, in std types only.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace telemetry {

enum class ValueKind : uint8_t {
	String,
	Bool,
	Int,
	Double,
};

struct Attribute {
	std::string key;
	ValueKind kind = ValueKind::String;
	std::string string_value;
	bool bool_value = false;
	int64_t int_value = 0;
	double double_value = 0.0;
};

struct Event {
	std::string name;
	uint64_t time_unix_nano = 0;
};

struct Span {
	std::string name;
	std::string trace_id;
	std::string span_id;
	std::string parent_span_id;
	uint64_t start_time_unix_nano = 0;
	uint64_t end_time_unix_nano = 0;
	bool error = false;
	std::string status_message;
	std::vector<Attribute> attributes;
	std::vector<Event> events;
};

struct LogRecord {
	uint64_t time_unix_nano = 0;
	int severity_number = 0;
	std::string severity_text;
	std::string body;
	std::vector<Attribute> attributes;
};

struct GaugePoint {
	std::string name;
	double value = 0.0;
	uint64_t time_unix_nano = 0;
	std::vector<Attribute> attributes;
};

// Every String result is "" on success and the reason otherwise, except the id getters.
class Provider {
public:
	std::string init(const std::string &name, const std::string &host, const std::vector<Attribute> &resource);
	void set_clock(uint64_t unix_nano);
	void seed(uint64_t seed);
	std::string start_span(const std::string &name, const std::string &parent_hex);
	std::string add_event(const std::string &span_hex, const std::string &event_name);
	std::string set_attributes(const std::string &span_hex, const std::vector<Attribute> &attributes);
	std::string record_error(const std::string &span_hex, const std::string &error);
	std::string end_span(const std::string &span_hex);
	std::string trace_id(const std::string &span_hex) const;
	std::string log(const std::string &severity, const std::string &body, const std::vector<Attribute> &attributes);
	std::string gauge(const std::string &name, double value, const std::vector<Attribute> &attributes);
	std::vector<uint8_t> export_traces();
	std::vector<uint8_t> export_logs();
	std::vector<uint8_t> export_metrics();
	std::string shutdown();
	const std::string &last_error() const { return error_; }
	const std::string &host() const { return host_; }

private:
	std::string ready() const;
	std::string random_id(size_t bytes);
	Span *find_open(const std::string &span_id);
	const Span *find_any(const std::string &span_id) const;
	std::string fail(const std::string &reason);

	bool initialized_ = false;
	std::string name_;
	std::string host_;
	std::vector<Attribute> resource_;
	uint64_t clock_ = 0;
	uint64_t rng_ = 0x6a09e667f3bcc909ull;
	std::vector<Span> open_;
	std::vector<Span> ended_;
	std::vector<LogRecord> logs_;
	std::vector<GaugePoint> gauges_;
	std::string error_;
};

std::string to_hex(const std::string &bytes);
bool from_hex(const std::string &hex, std::string &bytes);
int severity_number(const std::string &severity);

} // namespace telemetry
