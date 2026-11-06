#include "check.hpp"
#include "http1/head.hpp"
#include "http1/message_relay.hpp"
#include "proxy/http1_connection.hpp"
#include "test_byte_stream.hpp"
#include <array>

using namespace telar;
using namespace telar::runtime;

class MessageObserver {
public:
  void headStarted() noexcept { ++starts; }
  void head(std::string_view bytes) noexcept { captured_head.assign(bytes); }
  void payload(std::span<const std::uint8_t> bytes) noexcept { captured_body.append(reinterpret_cast<const char *>(bytes.data()), bytes.size()); }
  void lineTooLong(Http1Line kind) noexcept { ++(kind == Http1Line::chunk_size ? chunk_limits : trailer_limits); }

  std::string captured_head;
  std::string captured_body;
  std::size_t starts = 0;
  std::size_t chunk_limits = 0;
  std::size_t trailer_limits = 0;
};

static void checkHeadAnalysis() {
  using Kind = Http1Framing::Kind;
  const std::array invalid_lengths = {"", "1,", ",1", "1,2", "-1", "_1", "1_", "0x10", "18446744073709551616", "1 0"};
  for (const auto length : invalid_lengths) {
    check(!Http1Head::analyze("POST / HTTP/1.1\r\nContent-Length: " + std::string{length} + "\r\n\r\n", false));
  }
  for (const auto length : {"0", "-0", "-0_0", "+0", "00"}) {
    const auto head = Http1Head::analyze("POST / HTTP/1.1\r\nContent-Length: " + std::string{length} + "\r\n\r\n", false);
    check(head && head->framing.kind == Kind::content_length && head->framing.length == 0);
  }
  const auto repeated = Http1Head::analyze("POST / HTTP/1.1\r\nContent-Length: 1__0, +10\r\ncontent-LENGTH: 010\r\nConnection: keep-alive, CLOSE\r\n\r\n", false);
  check(repeated && repeated->framing.length == 10 && repeated->closes);
  check(!Http1Head::analyze("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", false));
  check(!Http1Head::analyze("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n", false));
  for (const auto encoding : {"chunked, gzip", "gzip", "gzip,,chunked", "chunked,"}) {
    check(!Http1Head::analyze("POST / HTTP/1.1\r\nTransfer-Encoding: " + std::string{encoding} + "\r\n\r\n", false));
    const auto response = Http1Head::analyze("HTTP/1.1 200 OK\r\nTransfer-Encoding: " + std::string{encoding} + "\r\n\r\n", true);
    check(response && response->framing.kind == Kind::until_close && response->closes);
  }
  const auto chunked = Http1Head::analyze("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, CHUNKED\r\n\r\n", false);
  check(chunked && chunked->framing.kind == Kind::chunked);
  for (const auto status : {100, 101, 199, 204, 205, 304}) {
    const auto response = Http1Head::analyze("anything " + std::to_string(status) + " OK\r\nContent-Length: invalid\r\nTransfer-Encoding:\r\n\r\n", true);
    check(response && response->framing.kind == Kind::none && response->status == status);
    check(response->informational == (status < 200 && status != 101));
    check(response->upgrade == (status == 101));
  }
  for (const auto status : {"099", "600", "+200", " 200", "2_0", "two", "20"}) {
    check(!Http1Head::analyze("HTTP/1.1 " + std::string{status} + " OK\r\n\r\n", true));
  }
  check(Http1Head::analyze("HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n", true, true)->framing.kind == Kind::none);
  check(Http1Head::analyze("HEAD / HTTP/1.1\r\n\r\n", false)->head_request);
  check(!Http1Head::analyze("head / HTTP/1.1\r\n\r\n", false)->head_request);
}

static void driveMessage(Http1MessageRelay &relay, TestByteStream &source, TestByteStream &destination, MessageObserver &observer) {
  for (std::size_t iteration = 0; iteration < 100000; ++iteration) {
    relay.advance(source, destination, observer);
    if (relay.state() >= Http1MessageRelay::State::complete) {
      return;
    }
  }
  check(false);
}

static void checkMessageFragments() {
  const std::string head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
  const std::string body = "3;ignored=true\r\none\r\n+2\r\ntw!!0\r\nX-Value: trailer\r\n\r\n";
  for (const auto fragment : {1, 2, 3, 7, 64, 16384}) {
    TestByteStream source;
    source.input = head + body + "next-message";
    source.read_limit = fragment;
    TestByteStream destination;
    destination.write_limit = 7;
    destination.alternating_writes = true;
    Http1MessageRelay relay;
    MessageObserver observer;
    driveMessage(relay, source, destination, observer);
    check(relay.state() == Http1MessageRelay::State::complete);
    check(destination.output == head + body && source.offset == head.size() + body.size());
    check(observer.captured_head == head && observer.captured_body == "onetw" && observer.starts == 1);
  }

  for (const bool response : {false, true}) {
    TestByteStream source;
    source.input = std::string{response ? "HTTP/1.1 200 OK" : "POST / HTTP/1.1"} + "\r\nContent-Length: 3\r\n\r\nabcnext";
    TestByteStream destination;
    Http1MessageRelay relay;
    relay.reset(response);
    MessageObserver observer;
    driveMessage(relay, source, destination, observer);
    check(destination.output == source.input.substr(0, source.input.size() - 4) && observer.captured_body == "abc");
  }
}

static void checkMessageFailures() {
  using State = Http1MessageRelay::State;
  const std::string head = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
  struct Fixture {
    std::string bytes;
    std::size_t forwarded;
    std::size_t chunks = 0;
    std::size_t trailers = 0;
  };
  for (const auto &fixture : {
           Fixture{head + "wrong\r\n", head.size() + 7},
           Fixture{head + "3 ;extra\r\nabc\r\n", head.size() + 10},
           Fixture{head + "123", head.size() + 3},
           Fixture{head + std::string(1025, 'a'), head.size() + 1024, 1},
           Fixture{head + "0\r\n" + std::string(8193, 'a'), head.size() + 3 + 8192, 0, 1},
       }) {
    TestByteStream source;
    source.input = fixture.bytes;
    source.ended = true;
    TestByteStream destination;
    destination.write_limit = 31;
    destination.alternating_writes = true;
    Http1MessageRelay relay;
    MessageObserver observer;
    driveMessage(relay, source, destination, observer);
    check(relay.state() == State::failed && destination.output == fixture.bytes.substr(0, fixture.forwarded));
    check(observer.chunk_limits == fixture.chunks && observer.trailer_limits == fixture.trailers);
  }

  for (const bool complete : {false, true}) {
    TestByteStream source;
    source.input = "GET / HTTP/1.1\r\nX: " + std::string(Http1Head::capacity, 'a');
    source.input.resize(Http1Head::capacity);
    if (complete) {
      source.input.replace(source.input.size() - 4, 4, "\r\n\r\n");
    }
    TestByteStream destination;
    Http1MessageRelay relay;
    MessageObserver observer;
    driveMessage(relay, source, destination, observer);
    check(relay.state() == (complete ? State::complete : State::head_too_large));
    check(destination.output == (complete ? source.input : ""));
  }
}

static void checkConnectionOrdering() {
  ProxyCounters counters;
  Http1Connection connection{counters};
  TestByteStream child;
  TestByteStream origin;
  const std::string request = "POST /upload HTTP/1.1\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n";
  const std::string interim = "HTTP/1.1 100 Continue\r\n\r\n";
  const std::string response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
  child.input = request + "oneGET /second HTTP/1.1\r\n\r\n";
  child.visible = 1;
  origin.input = interim + response + response;
  origin.visible = interim.size();
  check(connection.idle());
  connection.advance(child, origin, TunnelReadiness::available());
  check(!connection.idle() && connection.inflight() == 1 && origin.output.empty());
  child.visible = request.size();
  connection.advance(child, origin, TunnelReadiness::available());
  check(origin.output == request && child.output == interim && connection.inflight() == 1 && !connection.finished());

  child.visible = child.input.size();
  origin.visible = origin.input.size();
  for (std::size_t round = 0; round < 4; ++round) {
    connection.advance(child, origin, TunnelReadiness::available());
  }
  check(origin.output == child.input && child.output == origin.input && connection.idle() && connection.inflight() == 0);
}

static void checkConnectionEndings() {
  for (const auto response : {
           "HTTP/1.1 413 Rejected\r\nContent-Length: 0\r\n\r\n",
           "HTTP/1.1 101 Switching Protocols\r\n\r\n",
           "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
       }) {
    ProxyCounters counters;
    Http1Connection connection{counters};
    TestByteStream child;
    TestByteStream origin;
    const bool early = std::string_view{response}.find("413") != std::string_view::npos;
    const bool upgrade = std::string_view{response}.find("101") != std::string_view::npos;
    child.input = early ? "POST / HTTP/1.1\r\nContent-Length: 100000\r\n\r\npartial" : "GET / HTTP/1.1\r\n\r\n";
    origin.input = response;
    connection.advance(child, origin, TunnelReadiness::available());
    check(child.output == response && connection.upgraded() == upgrade && connection.finished() == !upgrade);
    check(connection.inflight() == 0);
  }

  for (const bool response : {false, true}) {
    ProxyCounters counters;
    Http1Connection connection{counters};
    TestByteStream child;
    TestByteStream origin;
    const std::string large(Http1Head::capacity, 'a');
    child.input = response ? "GET / HTTP/1.1\r\n\r\n" : large;
    origin.input = large;
    for (std::size_t round = 0; round < 8 && !connection.finished(); ++round) {
      connection.advance(child, origin, TunnelReadiness::available());
    }
    check(connection.finished() && counters.read(ProxyCounter::http1_head_too_large) == 1);
    check(child.output.starts_with(response ? "HTTP/1.1 502" : "HTTP/1.1 431"));
    check(origin.output == (response ? child.input : ""));
  }
}

void testHttp1() {
  checkHeadAnalysis();
  checkMessageFragments();
  checkMessageFailures();
  checkConnectionOrdering();
  checkConnectionEndings();
}
