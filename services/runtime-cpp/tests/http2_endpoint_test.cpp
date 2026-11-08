#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstring>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#include <zstd.h>
#include <nghttp2/nghttp2.h>
#include <cassert>
#include <cerrno>
#include <arpa/inet.h>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.tests.test_byte_stream;
import telar.runtime.proxy.runtime;
import telar.runtime.traffic.control_backend;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::traffic;
using telar::Byte;

namespace {
struct Owner : HttpControl {
  SystemAllocator &memory;
  Interception<SystemAllocator, HttpMessageLimits::message_bytes> broker;
  struct Request { std::uint64_t ticket; std::vector<Byte> bytes; };
  std::vector<Request> requests;
  std::vector<std::string> errors;
  Owner(SystemAllocator &memory, bool fail_closed = true, std::string_view host = "fixture.test", std::uint32_t timeout_ms = 5000) : memory(memory), broker(memory) { broker.configure({.host = host, .visibility = 3, .timeout_ms = timeout_ms, .fail_closed = fail_closed}); }
  HttpPolicy policy(const FlowEvent &event) noexcept override { return broker.policy(event); }
  std::uint64_t interceptHttp(const FlowEvent &event) noexcept override { return broker.begin(event); }
  FlowControl::Decision pollHttp(std::uint64_t ticket, std::span<Byte> output) noexcept override { return broker.poll(ticket, output); }
  void cancelHttp(std::uint64_t ticket) noexcept override { broker.cancel(ticket); }
  std::optional<FlowControl::Time> httpDeadline(std::uint64_t ticket) noexcept override { return broker.deadline(ticket); }
  void httpUnavailable(const FlowEvent &event) noexcept override { errors.emplace_back(event.reason); }
  void collect() {
    broker.deliver(1, [&](const FlowEvent &event) { requests.push_back({event.ticket, {event.bytes.begin(), event.bytes.end()}}); return true; });
  }
  void answer(const Request &request, bool edit = true) {
    auto message = HttpMessageCodec::decode(request.bytes);
    if (!edit) { broker.decide(request.ticket, Verdict::allow, {}); return; }
    const auto prefix = message.response ? std::string{"response\0", 9} : std::string{"request\0", 8};
    auto body = prefix + std::string{reinterpret_cast<const char *>(message.body.data()), message.body.size()};
    message.body = {reinterpret_cast<const Byte *>(body.data()), body.size()};
    const auto path = std::string{"/edited"} + std::string{message.target};
    if (!message.response) { message.target = path; }
    if (!message.response && path == "/edited/be-head") { message.method = "HEAD"; }
    if (!message.response && path == "/edited/be-get") { message.method = "GET"; }
    if (message.response) { message.status = 202; }
    SensitiveAllocation output{memory, HttpMessageLimits::message_bytes};
    broker.decide(request.ticket, Verdict::replace, HttpMessageCodec::encode(output.bytes(), message));
  }
};

class Peer {
public:
  struct Stream {
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body, outgoing;
    std::size_t sent = 0;
    bool complete = false, responded = false;
    std::uint32_t reset = 0;
    auto field(std::string_view name) const -> std::string_view {
      for (const auto &field : headers) { if (field.first == name) { return field.second; } }
      return {};
    }
  };
  explicit Peer(bool server) {
    nghttp2_session_callbacks *callbacks = nullptr;
    check(nghttp2_session_callbacks_new(&callbacks) == 0);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, &header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, &data);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, &frame);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, &closed);
    check((server ? nghttp2_session_server_new(&session_, callbacks, this) : nghttp2_session_client_new(&session_, callbacks, this)) == 0);
    nghttp2_session_callbacks_del(callbacks);
    check(nghttp2_submit_settings(session_, NGHTTP2_FLAG_NONE, nullptr, 0) == 0);
  }
  ~Peer() { nghttp2_session_del(session_); }
  Peer(const Peer &) = delete;
  Peer &operator=(const Peer &) = delete;

  auto request(std::string_view path, std::string body, std::string_view method = "POST") -> std::int32_t {
    const auto id = nghttp2_session_get_next_stream_id(session_);
    auto &stream = streams[id];
    stream.outgoing = std::move(body);
    const std::array<std::pair<std::string_view, std::string_view>, 4> fields{{{":method", method}, {":scheme", "https"}, {":authority", "fixture.test"}, {":path", path}}};
    const auto native = nativeFields(fields);
    const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};
    check(nghttp2_submit_request2(session_, nullptr, native.data(), native.size(), &provider, nullptr) == static_cast<std::int32_t>(id));
    return static_cast<std::int32_t>(id);
  }
  void respond(std::int32_t id, std::string body) {
    auto &stream = streams.at(id);
    stream.outgoing = std::move(body);
    stream.sent = 0;
    stream.responded = true;
    const auto length = std::to_string(stream.outgoing.size());
    const std::array<std::pair<std::string_view, std::string_view>, 2> fields{{{":status", "200"}, {"content-length", length}}};
    const auto native = nativeFields(fields);
    const nghttp2_data_provider2 provider{.source = {.ptr = &stream}, .read_callback = &read};
    check(nghttp2_submit_response2(session_, id, native.data(), native.size(), stream.field(":method") == "HEAD" ? nullptr : &provider) == 0);
  }
  void echo() {
    for (auto &[id, stream] : streams) {
      if (stream.complete && !stream.responded && !stream.reset) { respond(id, std::string{"origin\0", 7} + stream.body); }
    }
  }
  void ping() { constexpr std::array<std::uint8_t, 8> bytes{1, 2, 3, 4, 5, 6, 7, 8}; check(nghttp2_submit_ping(session_, 0, bytes.data()) == 0); }
  void reset(std::int32_t id) { check(nghttp2_submit_rst_stream(session_, 0, id, NGHTTP2_CANCEL) == 0); }
  void goaway(std::int32_t last) { check(nghttp2_submit_goaway(session_, 0, last, NGHTTP2_NO_ERROR, nullptr, 0) == 0); }
  void send(TestByteStream &transport) {
    for (unsigned count = 0; count < 128; ++count) {
      const std::uint8_t *bytes = nullptr;
      const auto size = nghttp2_session_mem_send2(session_, &bytes);
      check(size >= 0);
      if (!size) { return; }
      transport.input.append(reinterpret_cast<const char *>(bytes), static_cast<std::size_t>(size));
    }
  }
  void receive(TestByteStream &transport) {
    const auto bytes = std::string_view{transport.output}.substr(received_);
    if (bytes.empty()) { return; }
    const auto count = nghttp2_session_mem_recv2(session_, reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size());
    check(count >= 0 && static_cast<std::size_t>(count) == bytes.size());
    received_ += bytes.size();
  }

  std::map<std::int32_t, Stream> streams;
  bool pong = false;

private:
  template <std::size_t Size>
  static auto nativeFields(const std::array<std::pair<std::string_view, std::string_view>, Size> &fields) -> std::array<nghttp2_nv, Size> {
    std::array<nghttp2_nv, Size> native;
    for (std::size_t index = 0; index < Size; ++index) {
      const auto &[name, value] = fields[index];
      native[index] = {reinterpret_cast<std::uint8_t *>(const_cast<char *>(name.data())), reinterpret_cast<std::uint8_t *>(const_cast<char *>(value.data())), name.size(), value.size(), NGHTTP2_NV_FLAG_NONE};
    }
    return native;
  }
  static nghttp2_ssize read(nghttp2_session *, std::int32_t, std::uint8_t *output, std::size_t capacity, std::uint32_t *flags, nghttp2_data_source *source, void *) noexcept {
    auto &stream = *static_cast<Stream *>(source->ptr);
    const auto bytes = std::string_view{stream.outgoing}.substr(stream.sent, capacity);
    std::ranges::copy(bytes, output);
    stream.sent += bytes.size();
    if (stream.sent == stream.outgoing.size()) { *flags |= NGHTTP2_DATA_FLAG_EOF; }
    return static_cast<nghttp2_ssize>(bytes.size());
  }
  static int header(nghttp2_session *, const nghttp2_frame *frame, const std::uint8_t *name, std::size_t name_size, const std::uint8_t *value, std::size_t value_size, std::uint8_t, void *context) noexcept {
    auto &peer = *static_cast<Peer *>(context);
    peer.streams[frame->hd.stream_id].headers.emplace_back(std::string{reinterpret_cast<const char *>(name), name_size}, std::string{reinterpret_cast<const char *>(value), value_size});
    return 0;
  }
  static int data(nghttp2_session *, std::uint8_t, std::int32_t id, const std::uint8_t *bytes, std::size_t size, void *context) noexcept {
    static_cast<Peer *>(context)->streams[id].body.append(reinterpret_cast<const char *>(bytes), size);
    return 0;
  }
  static int frame(nghttp2_session *, const nghttp2_frame *frame, void *context) noexcept {
    auto &peer = *static_cast<Peer *>(context);
    if (frame->hd.type == NGHTTP2_PING && (frame->hd.flags & NGHTTP2_FLAG_ACK)) { peer.pong = true; }
    if ((frame->hd.type == NGHTTP2_HEADERS || frame->hd.type == NGHTTP2_DATA) && (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) { peer.streams[frame->hd.stream_id].complete = true; }
    return 0;
  }
  static int closed(nghttp2_session *, std::int32_t id, std::uint32_t code, void *context) noexcept { static_cast<Peer *>(context)->streams[id].reset = code; return 0; }

  nghttp2_session *session_ = nullptr;
  std::size_t received_ = 0;
};

struct Fixture {
  SystemAllocator memory;
  Owner owner;
  Peer client{false}, server{true};
  Http2EndpointConnection<SystemAllocator> connection;
  TestByteStream child, origin;
  explicit Fixture(bool fail_closed = true, std::string_view host = "fixture.test", std::uint32_t timeout_ms = 5000) : owner(memory, fail_closed, host, timeout_ms), connection(memory, IgnoreHttp2Capture{}, &owner, {.id = 17, .host = "fixture.test"}) {
    child.read_limit = origin.read_limit = 17;
    child.write_limit = origin.write_limit = 31;
    child.alternating_writes = origin.alternating_writes = true;
  }
  void step() {
    client.send(child); server.send(origin);
    connection.advance(child, origin, TunnelReadiness::available());
    client.receive(child); server.receive(origin);
    server.echo(); owner.collect();
  }
  void automatic(std::uint32_t held = 0, bool edit = true) {
    for (auto cursor = owner.requests.begin(); cursor != owner.requests.end();) {
      if (HttpMessageCodec::decode(cursor->bytes).stream == held) { ++cursor; continue; }
      owner.answer(*cursor, edit);
      cursor = owner.requests.erase(cursor);
    }
  }
  template <typename Predicate>
  void until(Predicate &&done, std::source_location location = std::source_location::current()) {
    for (unsigned count = 0; count < 200000 && !done(); ++count) { step(); }
    if (!done()) {
      std::fprintf(stderr, "H2: active=%u failed=%d owner=%zu client=%zu origin=%zu errors=%zu\n", connection.inflight(), connection.finished(), owner.requests.size(), client.streams.size(), server.streams.size(), owner.errors.size());
      for (const auto &error : owner.errors) { std::fprintf(stderr, "H2 error: %s\n", error.c_str()); }
    }
    check(done(), location);
  }
};

void multiplexed() {
  Fixture fixture;
  const auto held = fixture.client.request("/held", std::string(65536, 'h'));
  const auto fast = fixture.client.request("/fast", std::string(128 * 1024, '\0'));
  fixture.client.ping();
  fixture.until([&] {
    fixture.automatic(held);
    return fixture.client.streams[fast].complete && fixture.client.pong;
  });
  check(!fixture.client.streams[held].complete && fixture.owner.requests.size() == 1);
  check(fixture.server.streams.size() == 1 && fixture.server.streams.begin()->second.field(":path") == "/edited/fast");
  check(fixture.client.streams[fast].field(":status") == "202");
  check(fixture.client.streams[fast].body == std::string{"response\0origin\0request\0", 24} + std::string(128 * 1024, '\0'));
  fixture.until([&] { fixture.automatic(); return fixture.client.streams[held].complete; });
  check(fixture.server.streams.size() == 2 && fixture.owner.errors.empty() && !fixture.connection.finished());
}

void rejectedStream() {
  Fixture fixture;
  const auto rejected = fixture.client.request("/reject", "secret");
  fixture.until([&] { return !fixture.owner.requests.empty(); });
  const auto ticket = fixture.owner.requests.front().ticket;
  fixture.owner.broker.decide(ticket, Verdict::reject, {});
  fixture.owner.requests.clear();
  fixture.until([&] { return fixture.client.streams[rejected].reset == NGHTTP2_CANCEL; });
  const auto next = fixture.client.request("/survives", "next");
  fixture.until([&] { fixture.automatic(); return fixture.client.streams[next].complete; });
  check(!fixture.connection.finished() && fixture.server.streams.size() == 1);
}

void cancellation() {
  Fixture fixture;
  const auto canceled = fixture.client.request("/cancel", "secret");
  fixture.until([&] { return !fixture.owner.requests.empty(); });
  const auto ticket = fixture.owner.requests.front().ticket;
  fixture.client.reset(canceled);
  fixture.until([&] { return !fixture.owner.broker.pending(ticket); });
  fixture.owner.broker.decide(ticket, Verdict::replace, {});
  check(fixture.server.streams.empty() && !fixture.connection.finished());
}

void streaming() {
  Fixture fixture{false, "unselected.test"};
  std::string body(2 * 1024 * 1024, 'x');
  const auto stream = fixture.client.request("/large", body);
  fixture.until([&] { return fixture.client.streams[stream].complete; });
  check(fixture.owner.requests.empty() && fixture.owner.errors.empty());
  check(fixture.client.streams[stream].body == std::string{"origin\0", 7} + body);
}

void originEof() {
  Fixture fixture;
  const auto stream = fixture.client.request("/last", "last");
  fixture.until([&] {
    for (auto cursor = fixture.owner.requests.begin(); cursor != fixture.owner.requests.end();) {
      if (HttpMessageCodec::decode(cursor->bytes).response) { return true; }
      fixture.owner.answer(*cursor);
      cursor = fixture.owner.requests.erase(cursor);
    }
    return false;
  });
  fixture.origin.ended = true;
  fixture.step();
  check(!fixture.connection.finished());
  fixture.until([&] { fixture.automatic(); return fixture.client.streams[stream].complete; });
  check(fixture.client.streams[stream].field(":status") == "202");
}

void goaway() {
  Fixture fixture;
  const auto held = fixture.client.request("/held", "held");
  fixture.until([&] { return !fixture.owner.requests.empty(); });
  fixture.server.goaway(0);
  fixture.until([&] { return fixture.client.streams[held].reset != 0; });
  check(!fixture.owner.broker.pending(fixture.owner.requests.front().ticket));
}

void timeout() {
  for (const bool closed : {false, true}) {
    Fixture fixture{closed, "fixture.test", 50};
    const auto stream = fixture.client.request("/timeout", "original");
    fixture.until([&] { return !fixture.owner.requests.empty(); });
    const auto pending = fixture.owner.requests.front().ticket;
    check(fixture.connection.deadline().has_value());
    std::this_thread::sleep_for(std::chrono::milliseconds{60});
    fixture.until([&] {
      fixture.automatic(0, false);
      return closed ? fixture.client.streams[stream].reset != 0 : fixture.client.streams[stream].complete;
    });
    check(!fixture.owner.broker.pending(pending));
    if (!closed) { check(fixture.client.streams[stream].body == std::string{"origin\0original", 15}); }
    check(!fixture.connection.finished());
  }
}

void headMethods() {
  for (const bool original_head : {false, true}) {
    Fixture fixture;
    const auto stream = fixture.client.request(original_head ? "/be-get" : "/be-head", {}, original_head ? "HEAD" : "POST");
    fixture.until([&] { fixture.automatic(); return fixture.client.streams[stream].complete || fixture.client.streams[stream].reset != 0; });
    check(fixture.client.streams[stream].complete && fixture.client.streams[stream].reset == 0);
    check(original_head ? fixture.client.streams[stream].body.empty() : fixture.client.streams[stream].body == std::string{"response\0", 9});
  }
}
}

int main() {
  multiplexed();
  rejectedStream();
  cancellation();
  streaming();
  originEof();
  goaway();
  timeout();
  headMethods();
  std::puts("HTTP/2 endpoints: independent hooks, stream mapping, flow control, PING, reset isolation, cancellation and streaming passed");
}
