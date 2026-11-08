#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cerrno>
#include <cstdint>
#include <pthread.h>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#include <nghttp2/nghttp2.h>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <poll.h>

import std;
import telar.base.memory;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.tests.http2_fixture;
import telar.runtime.tests.test_byte_stream;
import telar.runtime.exchange_capture.pipeline;
import telar.runtime.proxy.runtime;

using namespace telar;
using namespace telar::runtime;

namespace {

struct TestCaptureClock {
  static std::int64_t now() noexcept { return 1234; }
};

std::string_view text(std::span<const std::uint8_t> bytes) {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

template <typename Connection>
void drive(Connection &connection, TestByteStream &child, TestByteStream &origin) {
  for (std::size_t round = 0; round < 10000; ++round) {
    if (!connection.advance(child, origin, TunnelReadiness::available())) {
      return;
    }
  }
  check(false);
}

void testHttp1CaptureFragments() {
  const std::string request_head = "POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Encoding: identity\r\n\r\n";
  const std::string request_body = "3\r\none\r\n2\r\ntw\r\n0\r\nTrailer: ignored\r\n\r\n";
  const std::string interim = "HTTP/1.1 103 Early Hints\r\nLink: ignored\r\n\r\n";
  const std::string response_head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n";

  for (const std::size_t fragment : {1, 3, 7, 16384}) {
    SystemAllocator system;
    BudgetAllocator budget{system, 1024 * 1024};
    SynchronizedAllocator memory{budget};
    {
      CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
      ProxyCounters counters;
      {
        Http1Capture<decltype(memory), TestCaptureClock> capture{memory, &producer, {.key = {17, 0}, .host = "example.test"}};
        Http1Connection connection{counters, std::move(capture)};
        TestByteStream child;
        TestByteStream origin;
        child.input = request_head + request_body;
        child.read_limit = fragment;
        child.write_limit = fragment;
        origin.write_limit = fragment;
        origin.read_limit = fragment;
        drive(connection, child, origin);
        check(origin.output == child.input && producer.metrics().queued == 1);

        auto request = producer.tryReceive();
        check(request && (*request)->side == CaptureSide::request);
        check(text((*request)->head.bytes()) == request_head && text((*request)->body.bytes()) == "onetw");
        check((*request)->method() == "POST" && (*request)->target() == "/upload");
        check((*request)->encoding() == "identity" && (*request)->host() == "example.test");
        check((*request)->key == CaptureKey{17, 0} && (*request)->started_at_ms == 1234 && (*request)->finished_at_ms == 1234);
        check((*request)->outcome == CaptureOutcome::finished && !(*request)->body_decoded);

        origin.input = interim + response_head + "ok";
        drive(connection, child, origin);
        check(connection.finished() && child.output == origin.input);
        auto response = producer.tryReceive();
        check(response && (*response)->side == CaptureSide::response && (*response)->status_code == 200);
        check(text((*response)->head.bytes()) == response_head && text((*response)->body.bytes()) == "ok");
        check((*response)->outcome == CaptureOutcome::finished && producer.metrics().started == 1);
      }
      check(producer.reservedBytes() == 0 && producer.metrics().queued == 0);
    }
    check(budget.liveBytes() == 0);
  }
}

void testHttp1CaptureFailures() {
  struct Fixture {
    std::string request;
    std::string response;
    bool ended;
    std::size_t captures;
    CaptureOutcome request_outcome = CaptureOutcome::failed;
  };

  for (const auto &fixture : {
           Fixture{"GET / HTTP/1.1\r\nContent-Length: invalid\r\n\r\n", "", true, 0},
           Fixture{"partial", "", true, 0},
           Fixture{std::string(Http1Head::capacity, 'a'), "", true, 0},
           Fixture{"POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort", "", true, 2},
           Fixture{"GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", true, 2, CaptureOutcome::finished},
           Fixture{"GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n", true, 2, CaptureOutcome::finished},
           Fixture{"GET / HTTP/1.1\r\n\r\n", std::string(Http1Head::capacity, 'a'), true, 2, CaptureOutcome::finished},
       }) {
    SystemAllocator memory;
    CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
    ProxyCounters counters;
    {
      Http1Connection connection{counters, Http1Capture{memory, &producer, CaptureStart{}}};
      TestByteStream child;
      TestByteStream origin;
      child.input = fixture.request;
      child.ended = fixture.ended;
      origin.input = fixture.response;
      origin.ended = fixture.ended;
      drive(connection, child, origin);
      check(connection.finished() && producer.metrics().queued == fixture.captures);
      if (fixture.captures != 0) {
        auto request = producer.tryReceive();
        auto response = producer.tryReceive();
        check(request && response && (*request)->outcome == fixture.request_outcome);
        check((*response)->outcome == CaptureOutcome::failed && (*response)->status_code == 0);
      }
    }
    check(producer.reservedBytes() == 0);
  }
}

void testHttp1CaptureEarlyResponseAndReuse() {
  SystemAllocator memory;
  CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
  ProxyCounters counters;
  {
    Http1Connection connection{counters, Http1Capture{memory, &producer, CaptureStart{.key = {42, 0}}}};
    TestByteStream child;
    TestByteStream origin;
    child.input = "POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\npartial";
    origin.input = "HTTP/1.1 413 Rejected\r\nContent-Length: 0\r\n\r\n";
    drive(connection, child, origin);
    check(connection.finished() && producer.metrics().queued == 1);
    auto response = producer.tryReceive();
    check(response && (*response)->side == CaptureSide::response && (*response)->outcome == CaptureOutcome::failed);
    check((*response)->status_code == 413 && producer.metrics().started == 1);
  }
  check(producer.reservedBytes() == 0);

  {
    Http1Connection connection{counters, Http1Capture{memory, &producer, CaptureStart{.key = {43, 0}}}};
    TestByteStream child;
    TestByteStream origin;
    child.input = "GET /first HTTP/1.1\r\n\r\nGET /second HTTP/1.1\r\n\r\n";
    origin.input = "HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 101 Switching Protocols\r\n\r\n";
    drive(connection, child, origin);
    check(connection.upgraded() && producer.metrics().queued == 4 && producer.metrics().started == 3);
    for (std::size_t index = 0; index < 4; ++index) {
      auto half = producer.tryReceive();
      check(half && (*half)->key == CaptureKey{43, 0});
      check((*half)->side == (index % 2 == 0 ? CaptureSide::request : CaptureSide::response));
      check((*half)->outcome == CaptureOutcome::finished);
    }
  }
  check(producer.reservedBytes() == 0);
}

void testHttp2CaptureFragments() {
  const auto request = std::string{Http2DirectionObserver<SystemAllocator>::client_preface} +
                       http2Frame(Http2FrameKind::headers, 4, 3, "\x82\x84") +
                       http2Frame(Http2FrameKind::data, 9, 3, std::string{"\x02hello!!", 8});
  const auto response = http2Frame(Http2FrameKind::headers, 4, 3, "\x88") +
                        http2Frame(Http2FrameKind::data, 1, 3, "world");

  for (const std::size_t fragment : {1, 3, 7, 16384}) {
    SystemAllocator system;
    BudgetAllocator budget{system, 4 * 1024 * 1024};
    SynchronizedAllocator memory{budget};
    {
      CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
      ProxyCounters counters;
      {
        Http2Capture<decltype(memory), TestCaptureClock> capture{&producer, counters, {.key = {31, 0}, .protocol = CaptureProtocol::http2, .host = "example.test"}};
        Http2Connection connection{memory, counters, std::move(capture)};
        TestByteStream child;
        TestByteStream origin;
        child.input = request;
        child.read_limit = fragment;
        child.write_limit = fragment;
        origin.read_limit = fragment;
        origin.write_limit = fragment;
        drive(connection, child, origin);
        check(origin.output == request && producer.metrics().queued == 1);
        auto request_half = producer.tryReceive();
        check(request_half && (*request_half)->key == CaptureKey{31, 3});
        check(text((*request_half)->head.bytes()) == ":method: GET\r\n:path: /\r\n" && text((*request_half)->body.bytes()) == "hello");
        check((*request_half)->method() == "GET" && (*request_half)->target() == "/");
        check((*request_half)->started_at_ms == 1234 && (*request_half)->finished_at_ms == 1234);

        origin.input = response;
        drive(connection, child, origin);
        check(child.output == response && connection.inflight() == 0);
        auto response_half = producer.tryReceive();
        check(response_half && (*response_half)->status_code == 200 && (*response_half)->outcome == CaptureOutcome::finished);
        check(text((*response_half)->head.bytes()) == ":status: 200\r\n" && text((*response_half)->body.bytes()) == "world");
      }
      check(producer.reservedBytes() == 0 && producer.metrics().queued == 0);
    }
    check(budget.liveBytes() == 0);
  }
}

void testHttp2CaptureLifecycle() {
  SystemAllocator memory;
  CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
  ProxyCounters counters;
  {
    Http2Capture capture{&producer, counters, CaptureStart{.key = {7, 0}, .protocol = CaptureProtocol::http2}};
    const auto response = Http2Direction::response;
    capture.observe(response, {.kind = Http2Event::Kind::response_header, .stream = 1, .name = ":status", .value = "103"});
    capture.observe(response, {.kind = Http2Event::Kind::response_header, .stream = 1, .name = "content-encoding", .value = "gzip"});
    capture.observe(response, {.kind = Http2Event::Kind::response_header, .stream = 1, .name = ":status", .value = "+5_0_0"});
    capture.observe(response, {.kind = Http2Event::Kind::response_ended, .stream = 1, .status = 500});
    auto failed = producer.tryReceive();
    check(failed && (*failed)->status_code == 500 && (*failed)->outcome == CaptureOutcome::failed);
    check(text((*failed)->head.bytes()) == "content-encoding: gzip\r\n:status: +5_0_0\r\n" && (*failed)->encoding() == "gzip");

    for (std::uint32_t stream = 2; stream <= 130; ++stream) {
      capture.observe(response, {.kind = Http2Event::Kind::response_header, .stream = stream, .name = ":status", .value = "200"});
    }
    check(counters.read(ProxyCounter::h2_capture_stream_skipped) == 1);
    capture.observe(response, {.kind = Http2Event::Kind::stream_reset, .stream = 2});
    auto reset = producer.tryReceive();
    check(reset && (*reset)->key.stream == 2 && (*reset)->outcome == CaptureOutcome::failed);
    capture.observe(response, {.kind = Http2Event::Kind::response_body, .stream = 130});
    capture.observe(response, {.kind = Http2Event::Kind::connection_lost});
    check(producer.metrics().queued == 0);
  }
  check(producer.metrics().queued == 127);
  while (auto pending = producer.tryReceive()) {
    check((*pending)->outcome == CaptureOutcome::reset && (*pending)->key.stream >= 3 && (*pending)->key.stream <= 129);
  }
  check(producer.reservedBytes() == 0);
}

void testHttp2CaptureMalformedHeaders() {
  for (const auto &headers : {std::string{}, std::string{"\x82\xff"}}) {
    SystemAllocator memory;
    CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
    ProxyCounters counters;
    {
      Http2Connection connection{memory, counters, Http2Capture{&producer, counters, CaptureStart{.protocol = CaptureProtocol::http2}}};
      TestByteStream child;
      TestByteStream origin;
      child.input = std::string{Http2DirectionObserver<SystemAllocator>::client_preface} + http2Frame(Http2FrameKind::headers, 4, 1, headers);
      child.ended = true;
      drive(connection, child, origin);
      check(origin.output == child.input && origin.half_closed);
      check(producer.metrics().queued == (headers.empty() ? 0 : 1));
      if (!headers.empty()) {
        auto partial = producer.tryReceive();
        check(partial && text((*partial)->head.bytes()) == ":method: GET\r\n" && (*partial)->outcome == CaptureOutcome::reset);
      }
    }
    check(producer.reservedBytes() == 0);
  }
}

struct PipelineClock {
  static std::int64_t now() noexcept { return current; }
  inline static std::int64_t current = 100;
};

template <Allocator Memory>
struct RecordingTap {
  bool listening() const noexcept { return decode; }
  void submit(CapturedExchange<Memory> &exchange) noexcept { exchanges.push_back(std::move(exchange)); }

  std::vector<CapturedExchange<Memory>> exchanges;
  bool decode = false;
};

template <typename Pipeline>
bool collectReady(Pipeline &pipeline) {
  pollfd event{.fd = pipeline.descriptor(), .events = POLLIN, .revents = 0};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  bool full = false;
  do {
    check(::poll(&event, 1, 2000) == 1 && (event.revents & POLLIN) != 0);
    full = pipeline.collect() || full;
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::yield();
  } while (::poll(&event, 1, 0) == 1);
  return full;
}

template <ConcurrentAllocator Memory>
void publishHalf(CaptureProducer<Memory> &producer, CaptureStart start, std::span<const std::uint8_t> body, std::string_view encoding) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  for (;;) {
    auto half = producer.start(start);
    check(half != nullptr);
    half->append(half->bodyPart(), body);
    half->setEncoding(encoding);
    half->finish(CaptureOutcome::finished, start.started_at_ms);
    if (producer.publish(std::move(half))) {
      return;
    }
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::yield();
  }
}

void testCapturePipeline() {
  const std::array<std::uint8_t, 32> compressed{0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x4b, 0x4e, 0x2c, 0x28, 0x29, 0x2d, 0x4a, 0x55, 0x48, 0xca, 0x4f, 0xa9, 0x04, 0x00, 0x9b, 0x1d, 0x16, 0x12, 0x0c, 0x00, 0x00, 0x00};
  const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 1024 * 1024, .join_timeout = std::chrono::milliseconds{50}, .enabled = true};
  for (const bool decode : {false, true}) {
    SystemAllocator system;
    BudgetAllocator budget{system, 8 * 1024 * 1024};
    SynchronizedAllocator memory{budget};
    {
      CaptureProducer producer{memory, limits};
      RecordingTap<decltype(memory)> tap;
      tap.decode = decode;
      PipelineClock::current = 100;
      {
        CapturePipeline<decltype(memory), decltype(tap), PipelineClock> pipeline{memory, producer, limits, tap};
        publishHalf(producer, {.key = {1, 0}}, compressed, "gzip");
        check(!collectReady(pipeline) && tap.exchanges.empty());
        publishHalf(producer, {.key = {1, 0}, .side = CaptureSide::response}, {}, "");
        check(!collectReady(pipeline) && tap.exchanges.size() == 1);
        const auto &request = tap.exchanges.front().request;
        check(request && request->body_decoded == decode);
        check(text(request->body.bytes()) == (decode ? std::string_view{"capture body"} : text(compressed)));
        check(tap.exchanges.front().response->body_decoded == decode);
        tap.exchanges.clear();

        publishHalf(producer, {.key = {2, 0}}, {}, "");
        check(!collectReady(pipeline));
        publishHalf(producer, {.key = {2, 0}}, {}, "");
        check(!collectReady(pipeline) && tap.exchanges.size() == 1);
        check(tap.exchanges.front().request && !tap.exchanges.front().response);
        tap.exchanges.clear();
        PipelineClock::current = 150;
        check(!pipeline.collect() && tap.exchanges.size() == 1);
        check(tap.exchanges.front().request->key.connection == 2);
        tap.exchanges.clear();

        for (std::size_t index = 0; index <= CaptureJoiner<decltype(memory)>::capacity; ++index) {
          publishHalf(producer, {.key = {index + 3, 0}}, {}, "");
          check(collectReady(pipeline) == (index == CaptureJoiner<decltype(memory)>::capacity));
        }
        check(tap.exchanges.size() == 1 && tap.exchanges.front().request->key.connection == 259);
        tap.exchanges.clear();
        PipelineClock::current = 200;
        check(!pipeline.collect() && tap.exchanges.size() == CaptureJoiner<decltype(memory)>::capacity);
        tap.exchanges.clear();
      }
      check(producer.reservedBytes() == 0);
    }
    check(budget.liveBytes() == 0);
  }
}

}

void testTransportCapture() {
  testHttp1CaptureFragments();
  testHttp1CaptureFailures();
  testHttp1CaptureEarlyResponseAndReuse();
  testHttp2CaptureFragments();
  testHttp2CaptureLifecycle();
  testHttp2CaptureMalformedHeaders();
  testCapturePipeline();
}
