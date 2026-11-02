#pragma once

#include "../http/message.hpp"
#include "../http2/memory.hpp"
#include "../memory/byte_queue.hpp"
#include "../memory/sensitive_buffer.hpp"
#include "../traffic/flow.hpp"
#include "http2_capture_policy.hpp"
#include "socket_interest.hpp"
#include <charconv>

namespace telar::runtime {

template <ConcurrentAllocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
class Http2EndpointConnection {
  static constexpr std::size_t maximum_streams = 64;
  static constexpr std::size_t connection_bytes = 16 * 1024 * 1024;
  static constexpr std::size_t wire_body_bytes = HttpMessageLimits::body_bytes + HttpMessageLimits::head_bytes;
  static constexpr auto collection_timeout = std::chrono::seconds{30};
  using Local = SynchronizedAllocator<BudgetAllocator<Memory>>;
  using Secure = ErasingAllocator<Local>;
  using Time = traffic::FlowControl::Time;
  struct Stream;
  struct Endpoint;

  struct Half {
    Half(Local &memory, Stream &stream, bool response) : secure(memory), message(memory, response), queue(secure, wire_body_bytes), stream(stream) { message.version = HttpVersion::http2; }
    Secure secure;
    HttpMessage<Local> message;
    ByteQueue<Secure> queue;
    Stream &stream;
    std::optional<SensitiveAllocation<Local>> decision;
    traffic::HttpPolicy policy;
    Time collect_until{};
    std::uint64_t ticket = 0;
    std::size_t header_bytes = 0, uncredited = 0;
    bool headers_complete = false, trailer_block = false, ended = false, forwarded = false, streaming = false, discard_body = false;
    unsigned informational = 0;
  };

  struct Stream {
    Stream(Local &memory, std::int32_t id) : child_id(id), request(memory, *this, false), response(memory, *this, true) {
      request.message.stream = response.message.stream = static_cast<std::uint32_t>(id);
    }
    std::int32_t child_id, origin_id = 0;
    Half request, response;
    bool child_closed = false, origin_closed = false, rejected = false, original_head = false, origin_canceled_for_head = false;
  };

  struct Endpoint {
    Endpoint(Local &memory, Http2EndpointConnection &owner, bool child) : memory(memory), owner(owner), child(child) {
      nghttp2_session_callbacks *raw_callbacks = nullptr;
      if (nghttp2_session_callbacks_new(&raw_callbacks) != 0) { throw std::bad_alloc{}; }
      const auto callbacks = std::unique_ptr<nghttp2_session_callbacks, decltype(&nghttp2_session_callbacks_del)>{raw_callbacks, &nghttp2_session_callbacks_del};
      nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks.get(), &beginHeaders);
      nghttp2_session_callbacks_set_on_header_callback(callbacks.get(), &header);
      nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks.get(), &data);
      nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks.get(), &frame);
      nghttp2_session_callbacks_set_on_stream_close_callback(callbacks.get(), &closed);
      nghttp2_session_callbacks_set_on_frame_not_send_callback(callbacks.get(), &notSent);
      nghttp2_option *raw_options = nullptr;
      if (nghttp2_option_new(&raw_options) != 0) { throw std::bad_alloc{}; }
      const auto options = std::unique_ptr<nghttp2_option, decltype(&nghttp2_option_del)>{raw_options, &nghttp2_option_del};
      nghttp2_option_set_no_auto_window_update(options.get(), 1);
      nghttp2_option_set_max_outbound_ack(options.get(), maximum_streams);
      const auto result = child ? nghttp2_session_server_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks()) : nghttp2_session_client_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks());
      if (result != 0) { throw std::bad_alloc{}; }
      const std::array<nghttp2_settings_entry, 4> settings{{{NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, maximum_streams}, {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, wire_body_bytes}, {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, HttpMessageLimits::head_bytes}, {NGHTTP2_SETTINGS_ENABLE_PUSH, 0}}};
      if (nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, settings.data(), child ? settings.size() - 1 : settings.size()) != 0) { close(); throw std::bad_alloc{}; }
    }
    ~Endpoint() { close(); }
    void close() noexcept { if (session) { nghttp2_session_del(session); session = nullptr; } }
    auto stream(std::int32_t id) const noexcept -> Stream * { return static_cast<Stream *>(nghttp2_session_get_stream_user_data(session, id)); }
    auto half(Stream &stream) const noexcept -> Half & { return child ? stream.request : stream.response; }

    static int beginHeaders(nghttp2_session *, const nghttp2_frame *frame, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      try { return endpoint.owner.beginHeaders(endpoint, *frame); }
      catch (...) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    }
    // These signatures are fixed by nghttp2's C callback ABI.
    static int header(nghttp2_session *, const nghttp2_frame *frame, const std::uint8_t *name, std::size_t name_size, const std::uint8_t *value, std::size_t value_size, std::uint8_t, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      auto *stream = endpoint.stream(frame->hd.stream_id);
      if (!stream || stream->rejected) { return 0; }
      try { endpoint.owner.header(endpoint, *stream, {reinterpret_cast<const char *>(name), name_size}, {reinterpret_cast<const char *>(value), value_size}); return 0; }
      catch (...) { endpoint.owner.reject(*stream, "http2_invalid_headers"); return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    }
    static int data(nghttp2_session *, std::uint8_t flags, std::int32_t id, const std::uint8_t *data, std::size_t size, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (nghttp2_session_consume_connection(endpoint.session, size) != 0) { return NGHTTP2_ERR_CALLBACK_FAILURE; }
      auto *stream = endpoint.stream(id);
      if (!stream || stream->rejected) { return 0; }
      try { endpoint.owner.data(endpoint, *stream, {data, size}, (flags & NGHTTP2_FLAG_END_STREAM) != 0); }
      catch (...) { endpoint.owner.reject(*stream, "http2_buffer_limit"); }
      return 0;
    }
    static int frame(nghttp2_session *, const nghttp2_frame *frame, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      try { endpoint.owner.frame(endpoint, *frame); return 0; }
      catch (...) {
        if (auto *stream = endpoint.stream(frame->hd.stream_id)) { endpoint.owner.reject(*stream, "http2_message_failed"); return 0; }
        return NGHTTP2_ERR_CALLBACK_FAILURE;
      }
    }
    static int closed(nghttp2_session *, std::int32_t id, std::uint32_t error, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (auto *stream = endpoint.stream(id)) {
        (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
        if (endpoint.child && error == NGHTTP2_NO_ERROR && stream->response.discard_body && stream->response.streaming && stream->origin_id && !stream->origin_closed && !stream->rejected) {
          stream->origin_canceled_for_head = true;
          nghttp2_submit_rst_stream(endpoint.owner.origin_.session, 0, stream->origin_id, NGHTTP2_CANCEL);
        }
        if (error != NGHTTP2_NO_ERROR && !endpoint.owner.closing_) {
          if (!endpoint.child && stream->origin_canceled_for_head) { endpoint.owner.capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream->child_id)}); }
          else { endpoint.owner.reject(*stream, "http2_stream_reset", error); }
        }
      }
      return 0;
    }
    static int notSent(nghttp2_session *, const nghttp2_frame *frame, int, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (frame->hd.type != NGHTTP2_HEADERS) { return 0; }
      for (auto &stream : endpoint.owner.streams_) {
        if (!stream || (endpoint.child ? stream->child_id : stream->origin_id) != frame->hd.stream_id) { continue; }
        (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
        endpoint.owner.reject(*stream, "http2_headers_not_sent");
        break;
      }
      return 0;
    }

    Http2Memory<Local> memory;
    Http2EndpointConnection &owner;
    bool child;
    nghttp2_session *session = nullptr;
    std::optional<SensitiveAllocation<Local>> output;
    std::size_t output_offset = 0;
    StreamReadiness read_wait = StreamReadiness::readable, write_wait = StreamReadiness::writable;
    bool eof = false;
  };

  class Fields {
  public:
    explicit Fields(Secure &memory) : names_(AllocatorRef<String<Secure>, Secure>{memory}), fields_(AllocatorRef<nghttp2_nv, Secure>{memory}) { names_.reserve(HttpFields<Local>::maximum_fields + 4); fields_.reserve(HttpFields<Local>::maximum_fields + 4); }
    void add(std::string_view name, std::string_view value) {
      names_.emplace_back(name, AllocatorRef<char, Secure>{names_.get_allocator().memory()});
      auto &lower = names_.back();
      std::ranges::transform(lower, lower.begin(), asciiLower);
      fields_.push_back({reinterpret_cast<std::uint8_t *>(lower.data()), reinterpret_cast<std::uint8_t *>(const_cast<char *>(value.data())), lower.size(), value.size(), NGHTTP2_NV_FLAG_NONE});
    }
    auto bytes() const noexcept -> std::span<const nghttp2_nv> { return fields_; }
  private:
    Vector<String<Secure>, Secure> names_;
    Vector<nghttp2_nv, Secure> fields_;
  };

public:
  explicit Http2EndpointConnection(Memory &memory, Capture capture, traffic::HttpControl *control, traffic::FlowEvent context) : budget_(memory, connection_bytes), memory_(budget_), secure_(memory_), capture_(std::move(capture)), control_(control), context_(context), child_(memory_, *this, true), origin_(memory_, *this, false), streams_(makeSlots(memory_)) {}
  ~Http2EndpointConnection() {
    closing_ = true;
    for (auto &stream : streams_) { if (stream) { cancel(stream->request); cancel(stream->response); } }
    child_.close(); origin_.close();
    capture_.finish(Http2Direction::request); capture_.finish(Http2Direction::response);
  }

  template <ByteStream Child, ByteStream Origin>
  bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    if (failed_) { return false; }
    bool active = false;
    for (unsigned round = 0; round < maximum_rounds; ++round) {
      bool progress = false;
      progress = send(child_, child, readiness.child) || progress;
      progress = send(origin_, origin, readiness.origin) || progress;
      progress = receive(child_, child, readiness.child) || progress;
      progress = receive(origin_, origin, readiness.origin) || progress;
      for (auto &stream : streams_) {
        if (!stream) { continue; }
        if (!stream->rejected) { resolve(stream->request); resolve(stream->response); }
        if (stream->child_closed && (stream->origin_closed || stream->origin_id == 0)) { stream.reset(); }
      }
      active |= progress;
      if (!progress || failed_) { break; }
    }
    const bool drained_origin = origin_.eof || (!origin_.output && !nghttp2_session_want_write(origin_.session));
    if ((origin_.eof || child_.eof || draining_) && inflight() == 0 && !child_.output && !nghttp2_session_want_write(child_.session) && drained_origin) { failed_ = true; }
    if (failed_) { child.halfClose(); origin.halfClose(); }
    return active;
  }

  bool finished() const noexcept { return failed_; }
  bool halfClosed() const noexcept { return child_.eof || origin_.eof; }
  bool readsChild() const noexcept { return !failed_ && !child_.eof; }
  bool readsOrigin() const noexcept { return !failed_ && !origin_.eof; }
  std::uint32_t inflight() const noexcept { return static_cast<std::uint32_t>(std::ranges::count_if(streams_, [](const auto &stream) { return bool(stream); })); }
  auto childInterest() const noexcept -> SocketInterest { return interest(child_); }
  auto originInterest() const noexcept -> SocketInterest { return interest(origin_); }
  auto deadline() const noexcept -> std::optional<Time> {
    std::optional<Time> result;
    for (const auto &stream : streams_) {
      if (!stream || stream->rejected) { continue; }
      for (const auto *half : {&stream->request, &stream->response}) {
        const auto next = half->ticket ? control_->httpDeadline(half->ticket) : half->policy.enabled && half->headers_complete && !half->ended && !half->streaming ? std::optional{half->collect_until} : std::nullopt;
        if (next && (!result || *next < *result)) { result = next; }
      }
    }
    return result;
  }

private:
  auto source(Half &half) noexcept -> Endpoint & { return half.message.response ? origin_ : child_; }
  auto target(Half &half) noexcept -> Endpoint & { return half.message.response ? child_ : origin_; }
  auto sourceId(Half &half) const noexcept -> std::int32_t { return half.message.response ? half.stream.origin_id : half.stream.child_id; }
  auto targetId(Half &half) const noexcept -> std::int32_t { return half.message.response ? half.stream.child_id : half.stream.origin_id; }
  auto context(const Half &half) const noexcept -> traffic::FlowEvent {
    auto event = context_;
    event.direction = half.message.response ? traffic::Direction::inbound : traffic::Direction::outbound;
    return event;
  }

  int beginHeaders(Endpoint &endpoint, const nghttp2_frame &frame) {
    if (frame.hd.type != NGHTTP2_HEADERS) { return 0; }
    auto *stream = endpoint.stream(frame.hd.stream_id);
    if (!stream && endpoint.child && frame.headers.cat == NGHTTP2_HCAT_REQUEST && !draining_) {
      for (auto &slot : streams_) {
        if (slot) { continue; }
        slot = makeOwned<Stream>(memory_, memory_, frame.hd.stream_id);
        stream = slot.get();
        if (nghttp2_session_set_stream_user_data(endpoint.session, frame.hd.stream_id, stream) != 0) { throw std::runtime_error{"Set HTTP/2 stream identity"}; }
        break;
      }
    }
    if (!stream || stream->rejected) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    auto &half = endpoint.half(*stream);
    half.trailer_block = half.headers_complete;
    if (!half.trailer_block) {
      half.header_bytes = 0;
      half.message.headers.clear();
      half.message.status = 0;
      if (!endpoint.child) { half.message.response_to_head = stream->request.message.method == "HEAD"; }
    }
    return 0;
  }

  void header(Endpoint &endpoint, Stream &stream, std::string_view name, std::string_view value) {
    auto &half = endpoint.half(stream);
    if (name.size() + value.size() + 4 > HttpMessageLimits::head_bytes - half.header_bytes) { throw std::length_error{"HTTP/2 header limit"}; }
    half.header_bytes += name.size() + value.size() + 4;
    const auto direction = endpoint.child ? Http2Direction::request : Http2Direction::response;
    capture_.observe(direction, {.kind = endpoint.child ? Http2Event::Kind::request_header : Http2Event::Kind::response_header, .stream = static_cast<std::uint32_t>(stream.child_id), .name = name, .value = value});
    if (half.trailer_block) { half.message.trailers.append(name, value); return; }
    if (name == ":method") { half.message.method.assign(value); }
    else if (name == ":path") { half.message.target.assign(value); }
    else if (name == ":scheme") { half.message.scheme.assign(value); }
    else if (name == ":authority") { half.message.authority.assign(value); }
    else if (name == ":status") {
      unsigned status = 0;
      const auto parsed = std::from_chars(value.data(), value.data() + value.size(), status);
      if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || status < 100 || status > 599) { throw std::invalid_argument{"Invalid HTTP/2 status"}; }
      half.message.status = static_cast<std::uint16_t>(status);
    } else if (name.starts_with(':')) { throw std::invalid_argument{"Unsupported HTTP/2 pseudo field"}; }
    else { half.message.headers.append(name, value); }
  }

  void frame(Endpoint &endpoint, const nghttp2_frame &frame) {
    if (frame.hd.type == NGHTTP2_GOAWAY) {
      draining_ = true;
      if (!endpoint.child) {
        for (auto &stream : streams_) {
          if (stream && (stream->origin_id == 0 || stream->origin_id > frame.goaway.last_stream_id)) { reject(*stream, "http2_origin_goaway", NGHTTP2_REFUSED_STREAM); }
        }
      }
      auto &other = endpoint.child ? origin_ : child_;
      check(nghttp2_submit_goaway(other.session, NGHTTP2_FLAG_NONE, endpoint.child ? 0 : highest_forwarded_, frame.goaway.error_code, nullptr, 0));
      return;
    }
    auto *stream = endpoint.stream(frame.hd.stream_id);
    if (!stream || stream->rejected || (frame.hd.type != NGHTTP2_HEADERS && frame.hd.type != NGHTTP2_DATA)) { return; }
    auto &half = endpoint.half(*stream);
    if (frame.hd.type == NGHTTP2_HEADERS && !half.trailer_block) {
      if (!endpoint.child && half.message.status < 200) { informational(half); return; }
      half.headers_complete = true;
      half.collect_until = std::chrono::steady_clock::now() + collection_timeout;
      if (endpoint.child) {
        stream->original_head = half.message.method == "HEAD";
        if (half.message.authority.empty()) { if (const auto host = half.message.headers.get("host")) { half.message.authority.assign(*host); } }
      }
      half.message.validateHttp2();
      half.policy = control_ ? control_->policy(context(half)) : traffic::HttpPolicy{};
      half.streaming = !half.policy.enabled;
      if (half.policy.enabled) {
        if (const auto length = half.message.headers.get("content-length")) {
          std::uint64_t size = 0;
          const auto parsed = std::from_chars(length->data(), length->data() + length->size(), size);
          if (parsed.ec == std::errc{} && size > wire_body_bytes) { unavailable(half, "http2_body_limit"); }
        }
      }
      const bool tunnel = endpoint.child ? half.message.method == "CONNECT" : stream->request.message.method == "CONNECT" && half.message.status >= 200 && half.message.status < 300;
      const auto type = half.message.headers.get("content-type");
      const bool event_stream = type && asciiEqualIgnoreCase(trimText(type->substr(0, type->find(';')), " \t"), "text/event-stream");
      if (half.policy.enabled && (tunnel || event_stream)) { unavailable(half, tunnel ? "http2_tunnel_body" : "http2_streaming_body"); }
      if (half.streaming && !stream->rejected) { forward(half, false); }
      if (endpoint.child && half.policy.enabled && !half.streaming && !stream->rejected) {
        if (const auto expect = half.message.headers.get("expect"); expect && asciiEqualIgnoreCase(*expect, "100-continue") && !(frame.hd.flags & NGHTTP2_FLAG_END_STREAM)) {
          Fields fields{secure_}; fields.add(":status", "100");
          check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, stream->child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
          half.message.headers.remove("expect");
        }
      }
    }
    if ((frame.hd.flags & NGHTTP2_FLAG_END_STREAM) && !stream->rejected) {
      half.ended = true;
      capture_.observe(endpoint.child ? Http2Direction::request : Http2Direction::response, {.kind = endpoint.child ? Http2Event::Kind::request_finished : Http2Event::Kind::response_ended, .stream = static_cast<std::uint32_t>(stream->child_id), .status = half.message.status});
      if (half.streaming) { resume(half); }
      else { complete(half); }
    }
  }

  void data(Endpoint &endpoint, Stream &stream, std::span<const Byte> bytes, bool end) {
    auto &half = endpoint.half(stream);
    half.uncredited += bytes.size();
    capture_.observe(endpoint.child ? Http2Direction::request : Http2Direction::response, {.kind = endpoint.child ? Http2Event::Kind::request_body : Http2Event::Kind::response_body, .stream = static_cast<std::uint32_t>(stream.child_id), .bytes = bytes});
    if (half.discard_body && half.streaming) { credit(half, bytes.size()); return; }
    if (bytes.size() > wire_body_bytes - half.queue.size()) { unavailable(half, "http2_body_limit"); }
    if (stream.rejected) { return; }
    half.queue.append(bytes);
    if (!half.streaming && half.queue.size() == wire_body_bytes && !end) { unavailable(half, "http2_body_limit"); }
    if (half.streaming) { resume(half); }
  }

  void complete(Half &half) {
    try {
      if (!half.message.bodyless()) { half.message.decodeBody(half.queue.readable()); }
      half.decision.emplace(memory_, HttpMessageLimits::message_bytes);
      auto event = context(half);
      event.bytes = HttpMessageCodec::encodeMessage(half.decision->bytes(), half.message);
      half.ticket = control_->interceptHttp(event);
      if (!half.ticket) { forward(half, false); }
    } catch (...) { unavailable(half, "http2_entity_unavailable"); }
  }

  void resolve(Half &half) noexcept {
    if (half.ticket) {
      const auto decision = control_->pollHttp(half.ticket, half.decision->bytes());
      if (decision.verdict == traffic::Verdict::pending) { return; }
      half.ticket = 0;
      if (decision.verdict == traffic::Verdict::reject) { reject(half.stream, "http2_interception_rejected"); return; }
      try {
        if (decision.verdict == traffic::Verdict::replace) { HttpMessageCodec::readMessage(half.message, half.decision->bytes().first(decision.bytes)); }
        forward(half, decision.verdict == traffic::Verdict::replace);
      } catch (...) { reject(half.stream, "http2_invalid_decision"); }
    } else if (half.headers_complete && !half.ended && !half.streaming && std::chrono::steady_clock::now() >= half.collect_until) {
      unavailable(half, "http2_collection_timeout");
    }
  }

  void unavailable(Half &half, std::string_view reason) noexcept {
    if (half.stream.rejected) { return; }
    if (half.policy.fail_closed) { reject(half.stream, reason); return; }
    auto event = context(half); event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
    cancel(half);
    half.streaming = true;
    try { if (!half.forwarded) { forward(half, false); } }
    catch (...) { reject(half.stream, "http2_forwarding_failed"); }
  }

  void informational(Half &half) {
    if (++half.informational > maximum_informational) { reject(half.stream, "http2_informational_limit"); return; }
    Fields fields{secure_};
    std::array<char, 3> status{};
    std::to_chars(status.data(), status.data() + status.size(), half.message.status);
    fields.add(":status", {status.data(), status.size()});
    for (const auto &field : half.message.headers.fields()) { fields.add(field.name(), field.value()); }
    check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, half.stream.child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
  }

  void forward(Half &half, bool changed) {
    if (half.forwarded || half.stream.rejected) { return; }
    half.message.validateHttp2();
    const bool source_head = half.message.response_to_head;
    if (half.message.response) {
      changed |= source_head != half.stream.original_head;
      half.message.response_to_head = half.stream.original_head;
      half.discard_body = half.message.bodyless();
    }
    if (changed) {
      half.queue.clear();
      const bool head_representation = half.message.response && half.message.response_to_head && half.message.status >= 200 && half.message.status != 204 && half.message.status != 205 && half.message.status != 304;
      const bool materialized_head = head_representation && (half.message.body_materialized || !half.message.body.empty());
      if (!half.message.bodyless() || materialized_head) { const auto body = half.message.encodeBody(); half.queue.append(body.bytes()); }
      if (!head_representation || materialized_head) { half.message.headers.remove("content-length"); }
      if (!half.message.bodyless() || half.message.status == 205 || materialized_head) {
        std::array<char, 32> length;
        const auto formatted = std::to_chars(length.data(), length.data() + length.size(), half.queue.size());
        half.message.headers.append("content-length", {length.data(), formatted.ptr});
      }
    }
    Fields fields{secure_};
    std::array<char, 3> status{};
    if (half.message.response) {
      std::to_chars(status.data(), status.data() + status.size(), half.message.status);
      fields.add(":status", {status.data(), status.size()});
    } else {
      fields.add(":method", half.message.method);
      if (half.message.method != "CONNECT") { fields.add(":scheme", half.message.scheme); fields.add(":path", half.message.target); }
      fields.add(":authority", half.message.authority);
    }
    for (const auto &field : half.message.headers.fields()) { fields.add(field.name(), field.value()); }
    nghttp2_data_provider2 provider{.source = {.ptr = &half}, .read_callback = &readBody};
    auto &endpoint = target(half);
    if (half.message.response) {
      check(nghttp2_submit_response2(endpoint.session, half.stream.child_id, fields.bytes().data(), fields.bytes().size(), half.message.bodyless() ? nullptr : &provider));
    } else {
      const auto id = nghttp2_submit_request2(endpoint.session, nullptr, fields.bytes().data(), fields.bytes().size(), &provider, &half.stream);
      check(id);
      half.stream.origin_id = id;
      highest_forwarded_ = std::max(highest_forwarded_, half.stream.child_id);
    }
    half.forwarded = true;
    half.message.response_to_head = source_head;
    if (half.discard_body) { half.queue.clear(); credit(half, half.uncredited); }
    if (half.ended && !half.streaming) { credit(half, half.uncredited); }
    half.decision.reset();
  }

  // Returning DEFERRED parks only this data provider; nghttp2 can send every other stream.
  static nghttp2_ssize readBody(nghttp2_session *session, std::int32_t id, std::uint8_t *output, std::size_t capacity, std::uint32_t *flags, nghttp2_data_source *source, void *context) noexcept {
    auto &endpoint = *static_cast<Endpoint *>(context);
    auto &half = *static_cast<Half *>(source->ptr);
    if (half.stream.rejected) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    const auto bytes = half.queue.readable().first(std::min(capacity, half.queue.size()));
    if (bytes.empty() && !half.ended) { return NGHTTP2_ERR_DEFERRED; }
    std::ranges::copy(bytes, output);
    half.queue.consume(bytes.size());
    if (half.streaming) { endpoint.owner.credit(half, bytes.size()); }
    if (half.queue.empty() && half.ended) {
      *flags |= NGHTTP2_DATA_FLAG_EOF;
      if (!half.message.trailers.fields().empty()) {
        try {
          Fields fields{endpoint.owner.secure_};
          for (const auto &field : half.message.trailers.fields()) { fields.add(field.name(), field.value()); }
          *flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
          check(nghttp2_submit_trailer(session, id, fields.bytes().data(), fields.bytes().size()));
        } catch (...) { endpoint.owner.reject(half.stream, "http2_trailer_failed"); return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
      }
    }
    return static_cast<nghttp2_ssize>(bytes.size());
  }

  void credit(Half &half, std::size_t count) noexcept {
    count = std::min(count, half.uncredited);
    if (count) { nghttp2_session_consume_stream(source(half).session, sourceId(half), count); half.uncredited -= count; }
  }
  void resume(Half &half) noexcept {
    if (half.forwarded && !half.stream.rejected) { nghttp2_session_resume_data(target(half).session, targetId(half)); }
  }
  void cancel(Half &half) noexcept { if (half.ticket) { control_->cancelHttp(half.ticket); half.ticket = 0; } half.decision.reset(); }
  void reject(Stream &stream, std::string_view reason, std::uint32_t code = NGHTTP2_CANCEL) noexcept {
    if (stream.rejected) { return; }
    stream.rejected = true;
    cancel(stream.request); cancel(stream.response);
    if (!stream.child_closed) { nghttp2_submit_rst_stream(child_.session, NGHTTP2_FLAG_NONE, stream.child_id, code); }
    if (stream.origin_id && !stream.origin_closed) { nghttp2_submit_rst_stream(origin_.session, NGHTTP2_FLAG_NONE, stream.origin_id, code); }
    auto event = context_; event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
    capture_.observe(Http2Direction::request, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
    capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
  }

  template <ByteStream Source>
  bool receive(Endpoint &endpoint, Source &source, SocketInterest readiness) noexcept {
    if (endpoint.eof || !readiness.satisfies(endpoint.read_wait)) { return false; }
    SensitiveBuffer<io_bytes> input;
    const auto read = source.read(input.bytes());
    if (read.state == StreamResult::State::blocked) { endpoint.read_wait = read.waiting; return false; }
    if (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed) {
      endpoint.eof = true;
      if (!endpoint.child) {
        draining_ = true;
        endpoint.output.reset();
        for (auto &stream : streams_) { if (stream && !stream->origin_closed) { reject(*stream, "http2_origin_closed"); } }
      }
      return true;
    }
    endpoint.read_wait = StreamReadiness::readable;
    const auto consumed = nghttp2_session_mem_recv2(endpoint.session, input.bytes().data(), read.bytes);
    if (consumed < 0 || static_cast<std::size_t>(consumed) != read.bytes) { fail("http2_connection_failed"); }
    return read.bytes != 0;
  }

  template <ByteStream Destination>
  bool send(Endpoint &endpoint, Destination &destination, SocketInterest readiness) noexcept {
    if (endpoint.eof && !endpoint.child) { return false; }
    if (!readiness.satisfies(endpoint.write_wait)) { return false; }
    try {
      if (!endpoint.output) {
        const std::uint8_t *bytes = nullptr;
        const auto size = nghttp2_session_mem_send2(endpoint.session, &bytes);
        if (size < 0) { fail("http2_output_failed"); return false; }
        if (size == 0) { return false; }
        endpoint.output.emplace(memory_, static_cast<std::size_t>(size));
        std::copy_n(bytes, size, endpoint.output->bytes().data());
        endpoint.output_offset = 0;
      }
      const auto result = destination.write(endpoint.output->bytes().subspan(endpoint.output_offset));
      if (result.state == StreamResult::State::blocked) { endpoint.write_wait = result.waiting; return false; }
      if (result.state != StreamResult::State::data || result.bytes == 0) { fail("http2_socket_write_failed"); return false; }
      endpoint.write_wait = StreamReadiness::writable;
      endpoint.output_offset += result.bytes;
      if (endpoint.output_offset == endpoint.output->bytes().size()) { endpoint.output.reset(); }
      return true;
    } catch (...) { fail("http2_output_limit"); return false; }
  }

  static auto interest(const Endpoint &endpoint) noexcept -> SocketInterest {
    SocketInterest result;
    if (!endpoint.eof) { result.include(endpoint.read_wait); }
    if ((!endpoint.eof || endpoint.child) && (endpoint.output || nghttp2_session_want_write(endpoint.session))) { result.include(endpoint.write_wait); }
    return result;
  }
  static void check(int result) { if (result < 0) { throw std::runtime_error{nghttp2_strerror(result)}; } }

  void fail(std::string_view reason) noexcept {
    if (failed_) { return; }
    failed_ = true;
    auto event = context_; event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
  }

  static auto makeSlots(Local &memory) {
    return [&]<std::size_t... Index>(std::index_sequence<Index...>) { return std::array<Owned<Stream, Local>, maximum_streams>{((void)Index, Owned<Stream, Local>{nullptr, AllocationDeleter<Stream, Local>{memory}})...}; }(std::make_index_sequence<maximum_streams>{});
  }

  static constexpr unsigned maximum_rounds = 8, maximum_informational = 8;
  static constexpr std::size_t io_bytes = 16 * 1024;
  BudgetAllocator<Memory> budget_;
  Local memory_;
  Secure secure_;
  Capture capture_;
  traffic::HttpControl *control_;
  traffic::FlowEvent context_;
  Endpoint child_, origin_;
  std::array<Owned<Stream, Local>, maximum_streams> streams_;
  std::int32_t highest_forwarded_ = 0;
  bool failed_ = false, closing_ = false, draining_ = false;
};

}
