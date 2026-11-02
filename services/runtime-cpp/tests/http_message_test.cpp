#include "check.hpp"
#include "http/content_codec.hpp"
#include "http/message.hpp"
#include "http1/message_relay.hpp"
#include "test_byte_stream.hpp"
#include <array>
#include <string>
#include <vector>

using namespace telar::runtime;
void testHttpInterception();

template <typename Function>
static void fails(Function &&function) {
  bool failed = false;
  try { function(); } catch (const std::exception &) { failed = true; }
  check(failed);
}

static void content(SystemAllocator &memory) {
  HttpContentCodec codec{memory};
  const std::array<std::uint8_t, 11> payload{'b', 'i', 0, 'n', 'a', 'r', 'y', '\r', '\n', 255, 1};
  constexpr std::size_t limit = 1024;
  for (const std::string_view coding : {"", "identity", "gzip", "deflate", "br", "zstd", "gzip, br", "zstd, gzip", "identity, gzip"}) {
    const auto encoded = codec.encode(payload, coding, limit);
    const auto decoded = codec.decode(encoded.bytes(), coding, limit);
    check(decoded.decoded && !decoded.failed && !decoded.truncated && std::ranges::equal(decoded.bytes(), payload));
    fails([&] { codec.decode(encoded.bytes(), coding, payload.size() - 1); });
    const auto exact = codec.decode(encoded.bytes(), coding, payload.size());
    check(std::ranges::equal(exact.bytes(), payload));
    const auto empty = codec.encode({}, coding, limit);
    check(codec.decode(empty.bytes(), coding, limit).size == 0);
    if (coding.empty() || coding == "identity") { continue; }
    fails([&] { codec.decode(encoded.bytes().first(encoded.size - 1), coding, limit); });
    std::vector<std::uint8_t> trailing(encoded.bytes().begin(), encoded.bytes().end());
    trailing.push_back(0);
    fails([&] { codec.decode(trailing, coding, limit); });
  }

  for (const std::string_view coding : {"gzip", "deflate", "zstd"}) {
    const auto encoded = codec.encode(payload, coding, limit);
    std::vector<std::uint8_t> corrupt(encoded.bytes().begin(), encoded.bytes().end());
    corrupt.back() ^= 1;
    fails([&] { codec.decode(corrupt, coding, limit); });
  }

  for (const std::string_view coding : {"gzip", "zstd"}) {
    const auto encoded = codec.encode(payload, coding, limit);
    std::vector<std::uint8_t> members(encoded.bytes().begin(), encoded.bytes().end());
    members.insert(members.end(), encoded.bytes().begin(), encoded.bytes().end());
    const auto decoded = codec.decode(members, coding, limit);
    check(decoded.size == payload.size() * 2 && std::ranges::equal(decoded.bytes().first(payload.size()), payload) && std::ranges::equal(decoded.bytes().last(payload.size()), payload));
  }

  for (const std::string_view coding : {"unknown", "gzip,", ",gzip", "gzip, br, gzip"}) {
    fails([&] { codec.decode(payload, coding, limit); });
    fails([&] { codec.encode(payload, coding, limit); });
  }
  fails([&] { codec.decode(payload, "", 0); });
  fails([&] { codec.encode(payload, "gzip", 1); });

  BudgetAllocator budget{memory, 4096};
  {
    HttpContentCodec bounded{budget};
    fails([&] { bounded.encode(payload, "gzip", limit); });
    fails([&] { bounded.decode(payload, "gzip", limit); });
  }
  check(budget.liveBytes() == 0);
}

static auto text(std::span<const std::uint8_t> bytes) -> std::string_view {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

struct MessageObserver {
  std::string head_bytes;
  std::vector<std::uint8_t> body;
  void headStarted() noexcept {}
  void head(std::string_view bytes) noexcept { head_bytes = bytes; }
  void payload(std::span<const std::uint8_t> bytes) noexcept { body.insert(body.end(), bytes.begin(), bytes.end()); }
  void lineTooLong(Http1Line) noexcept { check(false); }
};

static void messages(SystemAllocator &memory) {
  HttpMessage request{memory};
  const auto framing = request.readHttp1Head("POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 999\r\n\r\n");
  check(framing.framing.length == 999);
  request.target = "/edited";
  const std::array<std::uint8_t, 7> body{'a', 0, 'b', 'o', 'd', 'y', 255};
  request.body.assign(body.begin(), body.end());
  auto wire = request.serializeHttp1();
  check(text(wire).starts_with("POST /edited HTTP/1.1\r\n") && text(wire).contains("Content-Length: 7\r\n"));

  request.headers.set("Content-Encoding", "gzip");
  request.headers.append("X-Order", "first");
  request.headers.append("X-Order", "second");
  request.trailers.append("X-Checksum", "fixture");
  wire = request.serializeHttp1();
  check(text(wire).contains("Transfer-Encoding: chunked\r\n") && !text(wire).contains("Content-Length:") && text(wire).ends_with("0\r\nX-Checksum: fixture\r\n\r\n"));
  check(text(wire).contains("X-Order: first\r\nX-Order: second\r\n"));
  TestByteStream source, destination;
  source.input = std::string{text(wire)};
  source.read_limit = 1;
  destination.write_limit = 2;
  Http1MessageRelay relay;
  MessageObserver observer;
  for (unsigned step = 0; step < 4096 && relay.state() != Http1MessageRelay::State::complete; ++step) {
    relay.advance(source, destination, observer);
  }
  check(relay.state() == Http1MessageRelay::State::complete && destination.output == source.input);
  check(std::ranges::equal(HttpContentCodec{memory}.decode(observer.body, "gzip", 1024).bytes(), body));
  request.decodeBody(observer.body);
  check(std::ranges::equal(request.body, body));
  request.headers.set("X-Order", "merged");
  check(*request.headers.get("x-order") == "merged");
  request.headers.remove("X-Order");
  check(!request.headers.get("x-order"));

  for (const auto status : {100, 101, 204, 205, 304}) {
    HttpMessage response{memory, true};
    response.status = status;
    response.reason = "Fixture";
    response.headers.append("Content-Length", "123");
    response.body.assign(body.begin(), body.end());
    const auto output = response.serializeHttp1();
    check(text(output).ends_with("\r\n\r\n"));
    if (status == 304) { check(text(output).contains("Content-Length: 123\r\n")); }
    else if (status == 205) { check(text(output).contains("Content-Length: 0\r\n")); }
    else { check(!text(output).contains("Content-Length:")); }
  }
  HttpMessage head{memory, true};
  head.readHttp1Head("HTTP/1.1 200 OK\r\nContent-Length: 456\r\n\r\n", true);
  check(text(head.serializeHttp1()).contains("Content-Length: 456\r\n"));
  head.status = 204;
  check(!text(head.serializeHttp1()).contains("Content-Length:"));
  head.status = 205;
  check(text(head.serializeHttp1()).contains("Content-Length: 0\r\n"));

  HttpFields fields{memory};
  fields.append("X-Alias", "one");
  fields.append("X-Keep", "safe");
  fields.append("X-Alias", "two");
  fields.remove(fields.fields().front().name());
  check(fields.fields().size() == 1 && *fields.get("x-keep") == "safe");

  for (const std::string_view malformed : {
      "GET / HTTP/1.1\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
      "GET / HTTP/1.1\r\nHost : a\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a b\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\n folded: no\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nContent-Length: +0\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 1_0\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\n\r\nsmuggled\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"}) {
    fails([&] { HttpMessage invalid{memory}; invalid.readHttp1Head(malformed); });
  }
  fails([&] { request.headers.append("X-Bad", "value\r\nInjected: yes"); });
  fails([&] { request.trailers.append("Content-Length", "1"); request.serializeHttp1(); });
  request.trailers.clear();
  request.method = "BAD METHOD";
  fails([&] { request.serializeHttp1(); });
  request.method = "POST";
  request.version = HttpVersion::http2;
  fails([&] { request.serializeHttp1(); });
}

int main() {
  SystemAllocator memory;
  content(memory);
  messages(memory);
  testHttpInterception();
  std::puts("HTTP messages: binary entities, coding chains, integrity, framing, trailers, field validation and quotas passed");
}
