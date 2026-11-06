#include "check.hpp"
#include "http1/intercepted_relay.hpp"
#include "proxy/http1_connection.hpp"
#include "test_byte_stream.hpp"
#include <thread>

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::traffic;
using telar::Byte;

namespace {
struct HttpOwner final : HttpControl {
  SystemAllocator &memory;
  bool fail_closed = true;
  bool observe_response = true;
  std::vector<Byte> input, replacement;
  std::vector<std::string> errors;
  std::uint64_t next = 0, ticket = 0;
  Verdict answer = Verdict::pending;
  Direction direction = Direction::outbound;
  explicit HttpOwner(SystemAllocator &memory) : memory(memory) {}
  HttpPolicy policy(const FlowEvent &event) noexcept override { return {observe_response || event.direction == Direction::outbound, fail_closed}; }
  std::uint64_t interceptHttp(const FlowEvent &event) noexcept override {
    check(ticket == 0);
    input.assign(event.bytes.begin(), event.bytes.end());
    direction = event.direction;
    answer = Verdict::pending;
    return ticket = ++next;
  }
  FlowControl::Decision pollHttp(std::uint64_t id, std::span<Byte> bytes) noexcept override {
    check(ticket == id);
    if (answer == Verdict::pending) { return {answer}; }
    check(replacement.size() <= bytes.size());
    std::ranges::copy(replacement, bytes.begin());
    ticket = 0;
    return {answer, replacement.size()};
  }
  void cancelHttp(std::uint64_t id) noexcept override { check(ticket == id); ticket = 0; }
  auto httpDeadline(std::uint64_t) noexcept -> std::optional<FlowControl::Time> override { return std::chrono::steady_clock::now() + std::chrono::seconds{1}; }
  void httpUnavailable(const FlowEvent &event) noexcept override { errors.emplace_back(event.reason); }
  void replace(std::span<const Byte> bytes, std::string_view target = {}, std::string_view method = {}) {
    auto view = HttpMessageCodec::decode(input);
    view.body = bytes;
    if (!target.empty()) { view.target = target; }
    if (!method.empty()) { view.method = method; }
    SensitiveAllocation output{memory, HttpMessageLimits::message_bytes};
    const auto encoded = HttpMessageCodec::encode(output.bytes(), view);
    replacement.assign(encoded.begin(), encoded.end());
    answer = Verdict::replace;
  }
};

using Connection = Http1Connection<IgnoreHttp1Capture, Http1InterceptedRelay<SystemAllocator>>;

template <typename Predicate>
void pump(Connection &connection, TestByteStream &child, TestByteStream &origin, Predicate &&done, std::source_location location = std::source_location::current()) {
  for (unsigned attempt = 0; attempt < 100000 && !done(); ++attempt) { connection.advance(child, origin, TunnelReadiness::available()); }
  check(done(), location);
}

struct Parsed {
  std::vector<Byte> bytes;
  std::vector<std::string> trailers;
  void headStarted() noexcept {}
  void head(std::string_view) noexcept {}
  void payload(std::span<const Byte> body) noexcept { bytes.insert(bytes.end(), body.begin(), body.end()); }
  void trailer(std::string_view line) noexcept { trailers.emplace_back(line); }
  void lineTooLong(Http1Line) noexcept { check(false); }
};

void editing(SystemAllocator &memory) {
  HttpOwner owner{memory};
  ProxyCounters counters;
  Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 7, .host = "fixture.test"}}};
  TestByteStream child, origin;
  child.input = "POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 3\r\n\r\n" + std::string{"a\0b", 3};
  child.read_limit = 1;
  origin.visible = 0;
  origin.write_limit = 3;
  origin.alternating_writes = true;
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  check(origin.output.empty() && owner.direction == Direction::outbound);
  check(HttpMessageCodec::decode(owner.input).body.size() == 3);
  const std::array<Byte, 7> changed{'c', 'h', 0, 'a', 'n', 'g', 'e'};
  owner.replace(changed, "/edited");
  pump(connection, child, origin, [&] { return origin.output.ends_with(std::string{"ch\0ange", 7}); });
  check(origin.output.starts_with("POST /edited HTTP/1.1\r\n") && origin.output.contains("Content-Length: 7\r\n"));
  origin.input = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nold";
  origin.visible = origin.input.size();
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  check(child.output.empty() && owner.direction == Direction::inbound);
  owner.replace(changed);
  pump(connection, child, origin, [&] { return child.output.ends_with(std::string{"ch\0ange", 7}); });
  check(child.output.contains("Content-Length: 7\r\n") && owner.errors.empty());
}

void compressedTrailers(SystemAllocator &memory) {
  HttpOwner owner{memory};
  ProxyCounters counters;
  Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 8, .host = "fixture.test"}}};
  HttpMessage message{memory};
  message.method = "POST";
  message.target = "/gzip";
  message.headers.append("Host", "fixture.test");
  message.headers.append("Content-Encoding", "gzip");
  message.trailers.append("X-Checksum", "fixture");
  const std::array<Byte, 3> before{'a', 0, 'b'};
  message.body.assign(before.begin(), before.end());
  const auto wire = message.serializeHttp1();
  TestByteStream child, origin;
  child.input.assign(reinterpret_cast<const char *>(wire.data()), wire.size());
  child.read_limit = 1;
  origin.visible = 0;
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  const auto view = HttpMessageCodec::decode(owner.input);
  check(view.trailer_count == 1 && view.trailers[0].name == "X-Checksum" && std::ranges::equal(view.body, before));
  const std::array<Byte, 9> after{'e', 'x', 'p', 0, 'a', 'n', 'd', 'e', 'd'};
  owner.replace(after);
  pump(connection, child, origin, [&] { return connection.inflight() == 1 && owner.ticket == 0 && origin.output.ends_with("0\r\nX-Checksum: fixture\r\n\r\n"); });
  TestByteStream source, sink;
  source.input = origin.output;
  Parsed parsed;
  Http1MessageRelay relay;
  for (unsigned attempt = 0; attempt < 4096 && relay.state() != Http1MessageRelay::State::complete; ++attempt) { relay.advance(source, sink, parsed); }
  check(relay.state() == Http1MessageRelay::State::complete && parsed.trailers.size() == 1);
  check(std::ranges::equal(HttpContentCodec{memory}.decode(parsed.bytes, "gzip", 1024).bytes(), after));
}

void expectContinue(SystemAllocator &memory) {
  HttpOwner owner{memory};
  ProxyCounters counters;
  Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 9, .host = "fixture.test"}}};
  TestByteStream child, origin;
  child.input = "POST /expect HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n";
  child.write_limit = 1;
  child.alternating_writes = true;
  origin.visible = 0;
  pump(connection, child, origin, [&] { return child.output == "HTTP/1.1 100 Continue\r\n\r\n"; });
  check(origin.output.empty() && owner.ticket == 0);
  child.input += "abc";
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  owner.answer = Verdict::allow;
  pump(connection, child, origin, [&] { return origin.output.ends_with("\r\n\r\nabc"); });
  check(!origin.output.contains("Expect:") && owner.errors.empty());
}

void headResponse(SystemAllocator &memory) {
  HttpOwner owner{memory};
  ProxyCounters counters;
  Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 11, .host = "fixture.test"}}};
  TestByteStream child, origin;
  child.input = "HEAD /metadata HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
  origin.visible = 0;
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  owner.answer = Verdict::allow;
  pump(connection, child, origin, [&] { return origin.output == child.input; });
  origin.input = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 256\r\n\r\n";
  origin.visible = origin.input.size();
  pump(connection, child, origin, [&] { return owner.ticket != 0; });
  const auto view = HttpMessageCodec::decode(owner.input);
  check(view.response_to_head && view.body.empty());
  owner.answer = Verdict::allow;
  pump(connection, child, origin, [&] { return child.output == origin.input; });
  check(owner.errors.empty());
}

void invalidFraming(SystemAllocator &memory) {
  for (const std::string_view body : {"+0\r\n\r\n", "1_0\r\n0123456789abcdef\r\n0\r\n\r\n", "1\r\nx!!0\r\n\r\n", "0\r\r\n\r\n"}) {
    HttpOwner owner{memory};
    ProxyCounters counters;
    Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 12, .host = "fixture.test"}}};
    TestByteStream child, origin;
    child.input = "POST /invalid HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n" + std::string{body};
    origin.visible = 0;
    pump(connection, child, origin, [&] { return connection.finished(); });
    check(origin.output.empty() && owner.ticket == 0 && !owner.errors.empty());
  }
}

void incompleteMessage(SystemAllocator &memory) {
  for (const bool closed : {false, true}) {
    HttpOwner owner{memory};
    owner.fail_closed = closed;
    ProxyCounters counters;
    Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 13, .host = "fixture.test"}}};
    TestByteStream child, origin;
    child.input = "POST /incomplete HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 8\r\n\r\nabc";
    child.ended = true;
    origin.visible = 0;
    origin.write_limit = 3;
    origin.alternating_writes = true;
    pump(connection, child, origin, [&] { return connection.finished(); });
    check(owner.ticket == 0 && owner.errors == std::vector<std::string>{"http_incomplete_message"});
    check(closed ? origin.output.empty() : origin.output == child.input);
  }
}

void headMethods(SystemAllocator &memory) {
  for (const bool original_head : {false, true}) {
    for (const bool observe_response : {false, true}) {
      HttpOwner owner{memory};
      owner.observe_response = observe_response;
      ProxyCounters counters;
      Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 14, .host = "fixture.test"}}};
      TestByteStream child, origin;
      child.input = std::string{original_head ? "HEAD" : "GET"} + " /method HTTP/1.1\r\nHost: fixture.test\r\n\r\n";
      origin.visible = 0;
      pump(connection, child, origin, [&] { return owner.ticket != 0; });
      owner.replace({}, {}, original_head ? "GET" : "HEAD");
      pump(connection, child, origin, [&] { return origin.output.ends_with("\r\n\r\n"); });
      origin.input = original_head ? "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc" : "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 256\r\n\r\n";
      origin.visible = origin.input.size();
      if (observe_response) {
        pump(connection, child, origin, [&] { return owner.ticket != 0; });
        owner.answer = Verdict::allow;
      }
      pump(connection, child, origin, [&] {
        const auto boundary = child.output.find("\r\n\r\n");
        if (boundary == std::string::npos) { return false; }
        const auto head = Http1Head::analyze(std::string_view{child.output}.substr(0, boundary + 4), true, original_head);
        return head && child.output.size() == boundary + 4 + head->framing.length;
      });
      TestByteStream source, sink;
      source.input = child.output;
      Parsed parsed;
      Http1MessageRelay relay;
      relay.reset(true, original_head);
      for (unsigned attempt = 0; attempt < 4096 && relay.state() != Http1MessageRelay::State::complete; ++attempt) { relay.advance(source, sink, parsed); }
      check(relay.state() == Http1MessageRelay::State::complete && source.offset == source.input.size());
      if (original_head) { check(parsed.bytes.empty()); }
      else { check(HttpContentCodec{memory}.decode(parsed.bytes, "gzip", 1024).size == 0); }
    }
  }
}

void limits(SystemAllocator &memory) {
  for (const bool closed : {false, true}) {
    HttpOwner owner{memory};
    owner.fail_closed = closed;
    ProxyCounters counters;
    Connection connection{memory, counters, IgnoreHttp1Capture{}, HttpRelayContext{&owner, {.id = 10, .host = "fixture.test"}}};
    TestByteStream child, origin;
    const std::string body(HttpMessageLimits::body_bytes + Http1Head::capacity + 1, 'x');
    child.input = "POST /limit HTTP/1.1\r\nHost: fixture.test\r\nTransfer-Encoding: chunked\r\n\r\n";
    std::array<char, 32> size;
    const auto formatted = std::to_chars(size.data(), size.data() + size.size(), body.size(), 16);
    child.input.append(size.data(), formatted.ptr);
    child.input += "\r\n" + body + "\r\n0\r\n\r\n";
    child.read_limit = 16384;
    origin.visible = 0;
    origin.write_limit = 4096;
    origin.alternating_writes = true;
    pump(connection, child, origin, [&] { return closed ? connection.finished() : origin.output.size() == child.input.size(); });
    check(owner.ticket == 0 && !owner.errors.empty());
    check(closed ? origin.output.empty() : origin.output == child.input);
  }
}
}

void testHttpInterception() {
  SystemAllocator memory;
  editing(memory);
  compressedTrailers(memory);
  expectContinue(memory);
  headResponse(memory);
  invalidFraming(memory);
  incompleteMessage(memory);
  headMethods(memory);
  limits(memory);
}
