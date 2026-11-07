module;
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstddef>
#include <cstring>
#include <cstdint>


#include <pcap/pcap.h>


export module telar.runtime.traffic.control_protocol;

import std;

export import telar.runtime.plugins.protocol;
export import telar.runtime.http.message;


export import telar.runtime.redirect.direction;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: traffic/protocol.cppm
export {
namespace telar::runtime::traffic {

inline constexpr std::string_view socket_suffix = ".traffic";

struct Limits {
  static constexpr std::size_t packet_bytes = 262144;
  static constexpr std::size_t metadata_bytes = 1024;
  static constexpr std::size_t frame_bytes = packet_bytes + metadata_bytes;
  static constexpr std::size_t http_frame_bytes = HttpMessageLimits::message_bytes + 2 * metadata_bytes;
  static constexpr std::size_t filter_bytes = 4096;
  static constexpr std::size_t interface_bytes = 64;
  static constexpr std::size_t interfaces = 128;
  static constexpr std::size_t subscribers = 32;
  static constexpr std::size_t pending_frames = 8;
  static constexpr std::size_t filter_link_types = 16;
  static constexpr std::size_t http_part_bytes = static_cast<long>(48) * 1024;
};

enum class Role : Byte {
  subscribe = 1,
  live_capture = 2,
  offline_capture = 3,
  intercept = 4,
};

enum class Kind : Byte {
  ready,
  packet,
  interface_open,
  interface_closed,
  interface_error,
  statistics,
  capture_started,
  capture_stopped,
  error,
  exchange,
  flow_open,
  stream_data,
  flow_close,
  flow_error,
  flow_gap,
  intercept_request,
  http_intercept_request,
  datagram,
};

enum class Selection : Byte {
  packets = 1,
  exchanges = 2,
  both = 3,
  flows = 4,
  datagrams = 8,
  all = 15,
};

struct Event {
  Kind kind = Kind::packet;
  std::uint64_t session = 0;
  std::uint64_t sequence = 0;
  std::uint64_t timestamp_us = 0;
  std::uint32_t interface_index = 0;
  std::uint32_t link_type = 0;
  std::uint32_t original_bytes = 0;
  std::uint64_t kernel_drops = 0;
  std::uint64_t capture_drops = 0;
  std::uint64_t runtime_drops = 0;
  bool offline = false;
  std::string_view interface;
  std::span<const Byte> bytes;
};

// The independent data socket keeps packet backpressure out of terminal control delivery.
class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31525454;
  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t) + sizeof(std::uint64_t);
  static constexpr std::size_t greeting_bytes = sizeof(std::uint32_t) + (2 * sizeof(Byte)) + sizeof(std::uint32_t);

  inline static auto greeting(std::span<Byte> output, Role role, std::string_view filter = {}, Selection selection = Selection::packets) -> std::span<const Byte> {
    if (filter.size() > Limits::filter_bytes || filter.contains('\0') || (role != Role::subscribe && !filter.empty())) {
      throw EncodingError{"Invalid traffic subscription"};
    }

    plugins::FrameWriter writer{output};
    writer.integer(magic);
    writer.tag(role);
    writer.tag(selection);
    writer.text(filter);
    return writer.finish();
  }

  inline static std::size_t encodedSize(const Event &event) {
    validate(event);
    constexpr auto fixed_bytes = 2 * sizeof(Byte) + 6 * sizeof(std::uint64_t) + 5 * sizeof(std::uint32_t);
    return fixed_bytes + event.interface.size() + event.bytes.size();
  }

  inline static auto encode(std::span<Byte> output, const Event &event) -> std::span<const Byte> {
    validate(event);
    plugins::FrameWriter writer{output};
    writer.tag(event.kind);
    writer.integer(event.session);
    writer.integer(event.sequence);
    writer.integer(event.timestamp_us);
    writer.integer(event.interface_index);
    writer.integer(event.link_type);
    writer.integer(event.original_bytes);
    writer.integer(event.kernel_drops);
    writer.integer(event.capture_drops);
    writer.integer(event.runtime_drops);
    writer.boolean(event.offline);
    writer.text(event.interface);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  inline static auto decode(std::span<const Byte> input) -> Event {
    if (input.size() > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    plugins::FrameReader reader{input};
    Event event;
    event.kind = reader.tag(Kind::datagram);
    event.session = reader.integer<std::uint64_t>();
    event.sequence = reader.integer<std::uint64_t>();
    event.timestamp_us = reader.integer<std::uint64_t>();
    event.interface_index = reader.integer<std::uint32_t>();
    event.link_type = reader.integer<std::uint32_t>();
    event.original_bytes = reader.integer<std::uint32_t>();
    event.kernel_drops = reader.integer<std::uint64_t>();
    event.capture_drops = reader.integer<std::uint64_t>();
    event.runtime_drops = reader.integer<std::uint64_t>();
    event.offline = reader.boolean();
    event.interface = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    validate(event);
    return event;
  }

  inline static auto prefix(std::size_t bytes, std::uint64_t dropped = 0) -> std::array<Byte, prefix_bytes> {
    if (bytes > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    std::array<Byte, prefix_bytes> output{};
    plugins::FrameWriter writer{output};
    writer.integer(static_cast<std::uint32_t>(bytes));
    writer.integer(dropped);
    return output;
  }

  inline static auto name(Kind kind) noexcept -> std::string_view {
    constexpr std::array names{"ready", "packet", "interface.open", "interface.closed", "interface.error", "statistics", "capture.started", "capture.stopped", "error", "exchange", "flow.open", "stream.data", "flow.close", "flow.error", "flow.gap", "intercept.request", "http.intercept.request", "datagram"};
    return names.at(static_cast<std::size_t>(kind));
  }

private:
  inline static void validate(const Event &event) {
    const auto maximum = event.kind == Kind::http_intercept_request ? HttpMessageLimits::message_bytes + Limits::metadata_bytes : Limits::packet_bytes;
    if (event.interface.size() > Limits::interface_bytes || event.interface.contains('\0') || event.bytes.size() > maximum || (event.kind == Kind::packet && event.bytes.size() > event.original_bytes)) {
      throw EncodingError{"Invalid traffic event"};
    }
  }
};

}
}

// Interface: traffic/recording_protocol.cppm
export {
namespace telar::runtime::traffic::recording {

struct Limits {
  static constexpr std::size_t sessions = 4;
  static constexpr std::size_t session_bytes = 64 * 1024 * 1024;
  static constexpr std::size_t total_bytes = 128 * 1024 * 1024;
  static constexpr std::size_t events = 4096;
  static constexpr std::uint32_t age_ms = 60 * 60 * 1000;
  static constexpr std::size_t page_bytes = 512 * 1024;
  static constexpr std::uint32_t page_events = 128;
};

enum class Operation : Byte { start, query, stop, erase, pcapng, list };
enum class Format : Byte { events, pcapng, list };

struct Request {
  Operation operation = Operation::query;
  std::uint64_t id = 0;
  std::uint64_t cursor = 0;
  std::uint64_t max_bytes = 8 * 1024 * 1024;
  std::uint32_t max_events = 4096;
  std::uint32_t max_age_ms = 60000;
  std::uint32_t limit = 64;
  Selection selection = Selection::all;
  std::string_view filter;
  std::string_view host;
};

struct Page {
  std::uint64_t id = 0;
  bool active = false;
  bool gap = false;
  Format format = Format::events;
  std::uint64_t oldest = 1;
  std::uint64_t next = 1;
  std::uint64_t end = 1;
  std::uint64_t evicted = 0;
  std::uint64_t dropped = 0;
  std::uint64_t contention_drops = 0;
  std::uint64_t bytes = 0;
  std::uint32_t count = 0;
  std::span<const Byte> rows;
};

class Protocol {
public:
  static constexpr std::size_t page_header_bytes = 8 * sizeof(std::uint64_t) + 3 * sizeof(Byte) + sizeof(std::uint32_t);

  inline static void write(plugins::FrameWriter &writer, const Request &request) {
    validate(request);
    writer.tag(request.operation);
    writer.integer(request.id);
    writer.integer(request.cursor);
    writer.integer(request.max_bytes);
    writer.integer(request.max_events);
    writer.integer(request.max_age_ms);
    writer.integer(request.limit);
    writer.tag(request.selection);
    writer.text(request.filter);
    writer.text(request.host);
  }

  inline static Request read(plugins::FrameReader &reader) {
    Request request;
    request.operation = reader.tag(Operation::list);
    request.id = reader.integer<std::uint64_t>();
    request.cursor = reader.integer<std::uint64_t>();
    request.max_bytes = reader.integer<std::uint64_t>();
    request.max_events = reader.integer<std::uint32_t>();
    request.max_age_ms = reader.integer<std::uint32_t>();
    request.limit = reader.integer<std::uint32_t>();
    request.selection = reader.tag(Selection::all);
    request.filter = reader.text();
    request.host = reader.text();
    validate(request);
    return request;
  }

  inline static void header(plugins::FrameWriter &writer, const Page &page) {
    writer.integer(page.id);
    writer.boolean(page.active);
    writer.boolean(page.gap);
    writer.tag(page.format);
    writer.integer(page.oldest);
    writer.integer(page.next);
    writer.integer(page.end);
    writer.integer(page.evicted);
    writer.integer(page.dropped);
    writer.integer(page.contention_drops);
    writer.integer(page.bytes);
    writer.integer(page.count);
  }

  inline static Page page(std::span<const Byte> input) {
    if (input.size() > Limits::page_bytes || input.size() < page_header_bytes) { throw EncodingError{"Invalid recording page size"}; }
    plugins::FrameReader reader{input.first(page_header_bytes)};
    Page page;
    page.id = reader.integer<std::uint64_t>();
    page.active = reader.boolean();
    page.gap = reader.boolean();
    page.format = reader.tag(Format::list);
    page.oldest = reader.integer<std::uint64_t>();
    page.next = reader.integer<std::uint64_t>();
    page.end = reader.integer<std::uint64_t>();
    page.evicted = reader.integer<std::uint64_t>();
    page.dropped = reader.integer<std::uint64_t>();
    page.contention_drops = reader.integer<std::uint64_t>();
    page.bytes = reader.integer<std::uint64_t>();
    page.count = reader.integer<std::uint32_t>();
    reader.finish();
    if (page.count > Limits::page_events || page.next > page.end || page.oldest > page.end) { throw EncodingError{"Invalid recording cursor"}; }
    page.rows = input.subspan(page_header_bytes);
    return page;
  }

private:
  inline static void validate(const Request &request) {
    const auto selection = static_cast<Byte>(request.selection);
    const bool no_identity = request.operation == Operation::start || request.operation == Operation::list;
    if (request.max_bytes == 0 || request.max_bytes > Limits::session_bytes || request.max_events == 0 || request.max_events > Limits::events || request.max_age_ms == 0 || request.max_age_ms > Limits::age_ms || request.limit == 0 || request.limit > Limits::page_events || selection == 0 || selection > static_cast<Byte>(Selection::all) || request.filter.size() > traffic::Limits::filter_bytes || request.filter.contains('\0') || request.host.size() > 255 || request.host.contains('\0') || (no_identity ? request.id != 0 : request.id == 0)) {
      throw EncodingError{"Invalid recording request"};
    }
    if (request.operation != Operation::start && !request.filter.empty()) { throw EncodingError{"A recording filter is set at creation"}; }
  }
};

}
}

// Interface: traffic/control_protocol.cppm
export {
namespace telar::runtime::traffic::control {

inline constexpr std::string_view socket_suffix = ".network";

struct Limits {
  static constexpr std::size_t request_bytes = 8192;
  static constexpr std::size_t reply_bytes = recording::Limits::page_bytes + 32768;
  static constexpr std::size_t certificate_bytes = 4096;
  static constexpr std::size_t targets = 16;
  static constexpr std::size_t target_bytes = 259;
  static constexpr std::size_t arguments = 80;
  static constexpr std::size_t processes = 16;
  static constexpr std::size_t peers = 16;
};

enum class Operation : Byte { status, capture_start, capture_stop, redirect_start, redirect_stop, ca_certificate, ca_install, ca_uninstall, ca_rotate, recording };
enum class Result : Byte { ok, disabled, authorization_required, busy, failed, cleanup_required };
enum class CaptureState : Byte { disabled, idle, live, offline };
enum class RedirectState : Byte { disabled, idle, starting, active, stopping, cleanup_required };
enum class TrustState : Byte { absent, installed, stale };

struct Request {
  Operation operation = Operation::status;
  std::array<std::string_view, Limits::targets> targets{};
  std::size_t target_count = 0;
  std::optional<recording::Request> recording;
  std::array<std::uint32_t, Limits::processes> processes{};
  std::size_t process_count = 0;
  redirect::Direction direction = redirect::Direction::outbound;
};

struct Status {
  CaptureState capture = CaptureState::disabled;
  RedirectState redirect = RedirectState::disabled;
  TrustState trust = TrustState::absent;
  bool proxy = false;
  bool transparent_tls = false;
  bool tls_accepting = false;
  bool interception = false;
  bool administration = false;
  std::uint16_t port = 0;
  std::uint64_t capture_session = 0;
  std::uint32_t interfaces = 0;
  std::uint32_t interface_errors = 0;
};

struct Reply {
  Result result = Result::ok;
  Status status{};
  std::string_view message;
  std::string_view fingerprint_sha1;
  std::string_view fingerprint_sha256;
  std::span<const Byte> certificate;
  std::array<std::string_view, Limits::arguments> authorization{};
  std::size_t argument_count = 0;
  std::span<const Byte> recording;
};

class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31434e54;
  static constexpr std::uint32_t recording_magic = 0x32434e54;
  static constexpr std::uint32_t selection_magic = 0x33434e54;
  static constexpr std::uint32_t direction_magic = 0x34434e54;
  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

  inline static Request action(std::string_view name) {
    constexpr std::array names{"status", "capture.start", "capture.stop", "redirect.start", "redirect.stop", "ca.certificate", "ca.install", "ca.uninstall", "ca.rotate"};
    const auto found = std::ranges::find(names, name);
    if (found != names.end()) { return {.operation = static_cast<Operation>(found - names.begin())}; }
    constexpr std::array recordings{"recording.start", "recording.query", "recording.stop", "recording.remove", "recording.export", "recording.list"};
    const auto recording = std::ranges::find(recordings, name);
    if (recording != recordings.end()) { return {.operation = Operation::recording, .recording = recording::Request{.operation = static_cast<recording::Operation>(recording - recordings.begin())}}; }
    throw EncodingError{"Unknown network control action"};
  }

  inline static std::array<Byte, prefix_bytes> prefix(std::size_t size) {
    if (size == 0 || size > Limits::reply_bytes) { throw EncodingError{"Invalid network control frame size"}; }
    std::array<Byte, prefix_bytes> output;
    plugins::FrameWriter writer{output};
    writer.integer(static_cast<std::uint32_t>(size));
    return output;
  }

  inline static std::span<const Byte> encode(std::span<Byte> output, const Request &request) {
    validate(request);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::request_bytes))};
    writer.integer(request.direction != redirect::Direction::outbound ? direction_magic : request.process_count != 0 ? selection_magic : request.recording ? recording_magic : magic);
    writer.tag(request.operation);
    writer.integer(static_cast<Byte>(request.target_count));
    for (const auto target : std::span{request.targets}.first(request.target_count)) { writer.text(target); }
    if (request.recording) { recording::Protocol::write(writer, *request.recording); }
    if (request.process_count != 0 || request.direction != redirect::Direction::outbound) {
      writer.integer(static_cast<Byte>(request.process_count));
      for (const auto pid : std::span{request.processes}.first(request.process_count)) { writer.integer(pid); }
    }
    if (request.direction != redirect::Direction::outbound) { writer.tag(request.direction); }
    return writer.finish();
  }

  inline static Request request(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::request_bytes) { throw EncodingError{"Network control request exceeds its bound"}; }
    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic && version != selection_magic && version != direction_magic) { throw EncodingError{"Incompatible network control protocol"}; }
    Request request;
    request.operation = reader.tag(version != magic ? Operation::recording : Operation::ca_rotate);
    request.target_count = reader.integer<Byte>();
    if (request.target_count > request.targets.size()) { throw EncodingError{"Too many redirect targets"}; }
    for (auto &target : std::span{request.targets}.first(request.target_count)) { target = reader.text(); }
    if (request.operation == Operation::recording) { request.recording = recording::Protocol::read(reader); }
    if (version == selection_magic || version == direction_magic) {
      request.process_count = reader.integer<Byte>();
      if (request.process_count > request.processes.size()) { throw EncodingError{"Too many selected processes"}; }
      for (auto &pid : std::span{request.processes}.first(request.process_count)) { pid = reader.integer<std::uint32_t>(); }
    }
    if (version == direction_magic) { request.direction = reader.tag(redirect::Direction::both); }
    reader.finish();
    validate(request);
    return request;
  }

  inline static std::span<const Byte> encode(std::span<Byte> output, const Reply &reply) {
    validate(reply);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::reply_bytes))};
    writer.integer(reply.recording.empty() ? magic : recording_magic);
    writer.tag(reply.result);
    writer.tag(reply.status.capture);
    writer.tag(reply.status.redirect);
    writer.tag(reply.status.trust);
    writer.boolean(reply.status.proxy);
    writer.boolean(reply.status.transparent_tls);
    writer.boolean(reply.status.tls_accepting);
    writer.boolean(reply.status.interception);
    writer.boolean(reply.status.administration);
    writer.integer(reply.status.port);
    writer.integer(reply.status.capture_session);
    writer.integer(reply.status.interfaces);
    writer.integer(reply.status.interface_errors);
    writer.text(reply.message);
    writer.text(reply.fingerprint_sha1);
    writer.text(reply.fingerprint_sha256);
    writer.bytes(reply.certificate);
    writer.integer(static_cast<Byte>(reply.argument_count));
    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) { writer.text(argument); }
    if (!reply.recording.empty()) { writer.bytes(reply.recording); }
    return writer.finish();
  }

  inline static Reply reply(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::reply_bytes) { throw EncodingError{"Network control reply exceeds its bound"}; }
    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic) { throw EncodingError{"Incompatible network control protocol"}; }
    Reply reply;
    reply.result = reader.tag(Result::cleanup_required);
    reply.status.capture = reader.tag(CaptureState::offline);
    reply.status.redirect = reader.tag(RedirectState::cleanup_required);
    reply.status.trust = reader.tag(TrustState::stale);
    reply.status.proxy = reader.boolean();
    reply.status.transparent_tls = reader.boolean();
    reply.status.tls_accepting = reader.boolean();
    reply.status.interception = reader.boolean();
    reply.status.administration = reader.boolean();
    reply.status.port = reader.integer<std::uint16_t>();
    reply.status.capture_session = reader.integer<std::uint64_t>();
    reply.status.interfaces = reader.integer<std::uint32_t>();
    reply.status.interface_errors = reader.integer<std::uint32_t>();
    reply.message = reader.text();
    reply.fingerprint_sha1 = reader.text();
    reply.fingerprint_sha256 = reader.text();
    reply.certificate = reader.bytes();
    reply.argument_count = reader.integer<Byte>();
    if (reply.argument_count > reply.authorization.size()) { throw EncodingError{"Too many authorization arguments"}; }
    for (auto &argument : std::span{reply.authorization}.first(reply.argument_count)) { argument = reader.text(); }
    if (version == recording_magic) { reply.recording = reader.bytes(); }
    reader.finish();
    validate(reply);
    return reply;
  }

private:
  inline static void validate(const Request &request) {
    if ((!redirect::allowsIncoming(request.direction) && !redirect::allowsOutgoing(request.direction)) || (request.direction != redirect::Direction::outbound && request.operation != Operation::redirect_start) || (redirect::allowsIncoming(request.direction) && request.process_count != 0)) { throw EncodingError{"Incoming redirect selects local services by account; process selection is outbound only"}; }
    if (request.process_count > request.processes.size() || (request.process_count != 0 && request.operation != Operation::redirect_start)) { throw EncodingError{"Processes are only valid for redirect selection"}; }
    const auto processes = std::span{request.processes}.first(request.process_count);
    for (std::size_t index = 0; index < processes.size(); ++index) {
      if (processes[index] == 0 || processes[index] > INT32_MAX || std::ranges::find(processes.first(index), processes[index]) != processes.first(index).end()) { throw EncodingError{"Invalid or duplicate selected process"}; }
    }
    if ((request.operation == Operation::recording) != request.recording.has_value()) { throw EncodingError{"Recording operation requires a recording request"}; }
    if (request.target_count > request.targets.size() || (request.operation == Operation::redirect_start ? request.target_count == 0 : request.target_count != 0)) {
      throw EncodingError{"Redirect start requires targets; other operations accept none"};
    }
    for (const auto target : std::span{request.targets}.first(request.target_count)) {
      if (target.empty() || target.size() > Limits::target_bytes || target.find_first_of("\r\n\0", 0, 3) != std::string_view::npos) {
        throw EncodingError{"Invalid redirect target"};
      }
    }
  }

  inline static void validate(const Reply &reply) {
    if (reply.recording.size() > recording::Limits::page_bytes) { throw EncodingError{"Recording reply exceeds its bound"}; }
    if (reply.message.size() > 1024 || reply.certificate.size() > Limits::certificate_bytes || reply.argument_count > reply.authorization.size() || (!reply.fingerprint_sha1.empty() && reply.fingerprint_sha1.size() != 40) || (!reply.fingerprint_sha256.empty() && reply.fingerprint_sha256.size() != 64)) {
      throw EncodingError{"Invalid network control reply"};
    }
    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) {
      if (argument.empty() || argument.size() > 4096 || argument.contains('\0')) { throw EncodingError{"Invalid authorization argument"}; }
    }
  }
};

}
}

// Interface: traffic/filter.cppm
export {
namespace telar::runtime::traffic {

// Outside Filter, so its optional entries see a complete, default
// constructible type: Clang rejects emplace on a nested class whose member
// initializers it has not yet parsed.
struct FilterProgram {
  bpf_program value{};
  inline ~FilterProgram() { pcap_freecode(&value); }
};

struct FilterEntry {
  std::uint32_t link_type = 0;
  FilterProgram program;
};

class Filter {
public:
  Filter(const Filter &) = delete;
  Filter &operator=(const Filter &) = delete;

  inline explicit Filter(std::string_view expression) {
    if (expression.contains('\0')) {
      throw std::invalid_argument{"Traffic filter contains NUL"};
    }
    expression_.assign(expression);

    // Validate syntax before accepting a subscription, including before capture starts.
    if (!expression.empty()) {
      compile(DLT_EN10MB, validation_);
    }
  }

  inline bool matches(const Event &event) {
    if (event.kind != Kind::packet || expression_.view().empty()) {
      return true;
    }

    for (auto &entry : programs_) {
      if (entry && entry->link_type == event.link_type) {
        return apply(entry->program, event);
      }
    }
    for (auto &entry : programs_) {
      if (!entry) {
        entry.emplace();
        entry->link_type = event.link_type;
        compile(static_cast<int>(event.link_type), entry->program);
        return apply(entry->program, event);
      }
    }
    throw std::runtime_error{"Traffic filter link-type limit reached"};
  }

private:
  using Program = FilterProgram;
  using Entry = FilterEntry;

  inline void compile(int link_type, Program &program) {
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> dead{pcap_open_dead(link_type, Limits::packet_bytes), &pcap_close};
    if (!dead) {
      throw std::runtime_error{"Unable to compile traffic filter for link type"};
    }

    std::array<char, Limits::filter_bytes + 1> expression{};
    std::ranges::copy(expression_.view(), expression.begin());
    if (pcap_compile(dead.get(), &program.value, expression.data(), 1, PCAP_NETMASK_UNKNOWN) < 0) {
      throw std::invalid_argument{pcap_geterr(dead.get())};
    }
  }

  inline static bool apply(const Program &program, const Event &event) noexcept {
    pcap_pkthdr header{};
    header.caplen = static_cast<bpf_u_int32>(event.bytes.size());
    header.len = event.original_bytes;
    return pcap_offline_filter(&program.value, &header, event.bytes.data()) != 0;
  }

  FixedText<Limits::filter_bytes> expression_;
  Program validation_;
  std::array<std::optional<Entry>, Limits::filter_link_types> programs_;
};

}
}

// Interface: traffic/flow.cppm
export {
namespace telar::runtime::traffic {

enum class Direction : Byte { outbound, inbound };
enum class Visibility : Byte { wire, plaintext };
enum class FlowSource : Byte { proxy, capture };
enum class Verdict : Byte { pending, allow, replace, reject };
class HttpControl;

struct FlowEvent {
  std::uint64_t id = 0;
  Direction direction = Direction::outbound;
  Visibility visibility = Visibility::wire;
  FlowSource source = FlowSource::proxy;
  std::uint64_t offset = 0;
  std::uint64_t ticket = 0;
  std::string_view client;
  std::string_view server;
  std::string_view host;
  std::string_view reason;
  std::span<const Byte> bytes;
};

class FlowCodec {
public:
  inline static auto encode(std::span<Byte> output, const FlowEvent &event) -> std::span<const Byte> {
    plugins::FrameWriter writer{output};
    writer.integer(event.id);
    writer.tag(event.direction);
    writer.tag(event.visibility);
    writer.tag(event.source);
    writer.integer(event.offset);
    writer.integer(event.ticket);
    writer.text(event.client);
    writer.text(event.server);
    writer.text(event.host);
    writer.text(event.reason);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  inline static FlowEvent decode(std::span<const Byte> input) {
    plugins::FrameReader reader{input};
    FlowEvent event;
    event.id = reader.integer<std::uint64_t>();
    event.direction = reader.tag(Direction::inbound);
    event.visibility = reader.tag(Visibility::plaintext);
    event.source = reader.tag(FlowSource::capture);
    event.offset = reader.integer<std::uint64_t>();
    event.ticket = reader.integer<std::uint64_t>();
    event.client = reader.text();
    event.server = reader.text();
    event.host = reader.text();
    event.reason = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    if (event.client.size() > 128 || event.server.size() > 128 || event.host.size() > 253 || event.reason.size() > 128) {
      throw EncodingError{"Invalid flow metadata"};
    }
    return event;
  }
};

class FlowControl {
public:
  using Time = std::chrono::steady_clock::time_point;
  static constexpr std::size_t chunk_bytes = 64 * 1024;
  struct Decision { Verdict verdict; std::size_t bytes = 0; };

  virtual ~FlowControl() = default;
  virtual void observeFlow(Kind kind, const FlowEvent &event) noexcept = 0;
  virtual std::uint64_t intercept(const FlowEvent &event) noexcept = 0;
  virtual Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
  virtual void cancel(std::uint64_t ticket) noexcept = 0;
  virtual std::optional<Time> deadline(std::uint64_t ticket) noexcept = 0;
  virtual int descriptor() const noexcept = 0;
  virtual void drain() noexcept = 0;
  inline virtual HttpControl *http() noexcept { return nullptr; }
};

struct HttpPolicy {
  bool enabled = false;
  bool fail_closed = false;
};

class HttpControl {
public:
  virtual ~HttpControl() = default;
  virtual HttpPolicy policy(const FlowEvent &context) noexcept = 0;
  virtual std::uint64_t interceptHttp(const FlowEvent &event) noexcept = 0;
  virtual FlowControl::Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
  virtual void cancelHttp(std::uint64_t ticket) noexcept = 0;
  virtual std::optional<FlowControl::Time> httpDeadline(std::uint64_t ticket) noexcept = 0;
  virtual void httpUnavailable(const FlowEvent &event) noexcept = 0;
};

inline bool isFlow(Kind kind) noexcept {
  return kind >= Kind::flow_open && kind <= Kind::flow_gap;
}

inline bool selects(Selection selection, Selection flag) noexcept {
  return (static_cast<Byte>(selection) & static_cast<Byte>(flag)) != 0;
}

}
}

// Interface: traffic/pcapng.cppm
export {
namespace telar::runtime::traffic {

class Pcapng {
public:
  static constexpr std::size_t section_bytes = 28;

  inline static void section(plugins::FrameWriter &writer) {
    writer.integer<std::uint32_t>(0x0a0d0d0a);
    writer.integer<std::uint32_t>(section_bytes);
    writer.integer<std::uint32_t>(0x1a2b3c4d);
    writer.integer<std::uint16_t>(1);
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint64_t>(UINT64_MAX);
    writer.integer<std::uint32_t>(section_bytes);
  }

  inline static std::size_t packetBytes(const Event &event) { return 20 + 8 + padded(event.interface.size()) + 32 + padded(event.bytes.size()); }

  inline static void packet(plugins::FrameWriter &writer, const Event &event, std::uint32_t interface) {
    if (event.kind != Kind::packet || event.link_type > UINT16_MAX) { throw EncodingError{"Packet cannot be represented in PCAPNG"}; }
    const auto interface_bytes = static_cast<std::uint32_t>(20 + 8 + padded(event.interface.size()));
    writer.integer<std::uint32_t>(1);
    writer.integer(interface_bytes);
    writer.integer(static_cast<std::uint16_t>(event.link_type));
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint32_t>(Limits::packet_bytes);
    writer.integer<std::uint16_t>(2);
    writer.integer(static_cast<std::uint16_t>(event.interface.size()));
    raw(writer, {reinterpret_cast<const Byte *>(event.interface.data()), event.interface.size()});
    writer.integer<std::uint32_t>(0);
    writer.integer(interface_bytes);
    const auto packet_bytes = static_cast<std::uint32_t>(32 + padded(event.bytes.size()));
    writer.integer<std::uint32_t>(6);
    writer.integer(packet_bytes);
    writer.integer(interface);
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us >> 32));
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us));
    writer.integer(static_cast<std::uint32_t>(event.bytes.size()));
    writer.integer(event.original_bytes);
    raw(writer, event.bytes);
    writer.integer(packet_bytes);
  }

private:
  inline static std::size_t padded(std::size_t size) noexcept { return (size + 3) & ~std::size_t{3}; }

  inline static void raw(plugins::FrameWriter &writer, std::span<const Byte> bytes) {
    writer.append(bytes);
    for (std::size_t index = bytes.size(); index < padded(bytes.size()); ++index) { writer.integer<Byte>(0); }
  }
};

}
}
