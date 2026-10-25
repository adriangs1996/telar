#include "check.hpp"
#include "http2/direction_observer.hpp"
#include "http2_fixture.hpp"
#include "memory/c_allocation_blocks.hpp"
#include "proxy/http2_connection.hpp"
#include "test_byte_stream.hpp"
#include <string>
#include <vector>

using namespace telar::runtime;

namespace {

struct Events {
  void emit(const Http2Event &event) noexcept {
    kinds.push_back(event.kind);
    streams.push_back(event.stream);
    statuses.push_back(event.status);
    if (event.kind == Http2Event::Kind::request_header || event.kind == Http2Event::Kind::response_header) {
      fields.emplace_back(std::string{event.name} + "=" + std::string{event.value});
    }
    if (!event.bytes.empty()) {
      body.append(reinterpret_cast<const char *>(event.bytes.data()), event.bytes.size());
    }
    event_stream = event_stream || event.event_stream;
  }

  std::vector<Http2Event::Kind> kinds;
  std::vector<std::uint32_t> streams;
  std::vector<std::uint16_t> statuses;
  std::vector<std::string> fields;
  std::string body;
  bool event_stream = false;
};

template <typename Observer>
void feed(Observer &observer, std::string_view input, std::size_t fragment, Events &events) {
  while (!input.empty()) {
    const auto count = std::min(fragment, input.size());
    observer.observe({reinterpret_cast<const std::uint8_t *>(input.data()), count}, events);
    input.remove_prefix(count);
  }
}

void testAllocationBlocks() {
  SystemAllocator system;
  BudgetAllocator memory{system, 128};
  CAllocationBlocks blocks{memory};
  auto *allocation = static_cast<unsigned char *>(blocks.allocateZeroed(3, 16));
  check(allocation != nullptr && reinterpret_cast<std::uintptr_t>(allocation) % alignof(std::max_align_t) == 0);
  check(std::all_of(allocation, allocation + 48, [](auto value) { return value == 0; }));
  std::fill_n(allocation, 48, 73);
  check(blocks.resize(allocation, 128) == nullptr);
  check(std::all_of(allocation, allocation + 48, [](auto value) { return value == 73; }));
  check(blocks.allocateZeroed(std::numeric_limits<std::size_t>::max(), 2) == nullptr);
  check(blocks.allocate(std::numeric_limits<std::size_t>::max()) == nullptr);
  auto *smaller = static_cast<unsigned char *>(blocks.resize(allocation, 16));
  check(smaller != nullptr && std::all_of(smaller, smaller + 16, [](auto value) { return value == 73; }));
  check(blocks.resize(smaller, 0) == nullptr);
  blocks.release(blocks.allocate(0));
  blocks.release(nullptr);
  check(memory.liveBytes() == 0);
}

void testRequestFragments() {
  const auto request = std::string{Http2DirectionObserver<SystemAllocator>::client_preface} +
                       http2Frame(Http2FrameKind::headers, 0, 1, "\x82") +
                       http2Frame(Http2FrameKind::continuation, 4, 1, "\x84") +
                       http2Frame(Http2FrameKind::data, 9, 1, std::string{"\x02hello!!", 8});

  for (const std::size_t fragment : {1, 2, 3, 7, 16, 64, 16384}) {
    SystemAllocator system;
    BudgetAllocator memory{system, 1024 * 1024};
    {
      Http2DirectionObserver observer{memory, Http2Direction::request};
      Events events;
      feed(observer, request, fragment, events);
      check(!observer.finish().decode_failed);
      check(events.fields == std::vector<std::string>{":method=GET", ":path=/"});
      check(events.body == "hello");
      check(std::ranges::count(events.kinds, Http2Event::Kind::request_started) == 1);
      check(events.kinds.back() == Http2Event::Kind::request_finished);
    }
    check(memory.liveBytes() == 0);
  }
}

void testObservationLimits() {
  SystemAllocator system;
  {
    BudgetAllocator memory{system, 0};
    Http2Observer observer{memory, Http2Direction::request};
    Events events;
    feed(observer, http2Frame(Http2FrameKind::data, 1, 3, "body"), 1, events);
    check(observer.finish().decode_failed && events.body == "body");
    check(events.kinds.back() == Http2Event::Kind::request_finished);
    check(memory.liveBytes() == 0);
  }
  {
    Http2Observer observer{system, Http2Direction::request};
    Events events;
    for (std::uint32_t stream = 1; stream <= Http2StreamTracker::capacity + 2; ++stream) {
      feed(observer, http2Frame(Http2FrameKind::headers, 4, stream, "\x82"), 16, events);
    }
    check(observer.finish().untracked_streams == 2);
    check(std::ranges::count(events.kinds, Http2Event::Kind::request_started) == Http2StreamTracker::capacity);
  }
  {
    Http2Observer observer{system, Http2Direction::response};
    Events events;
    feed(observer, http2Frame(Http2FrameKind::headers, 4, 1, std::string(Http2Observer<SystemAllocator>::maximum_header_bytes + 1, 'a')), 16384, events);
    check(observer.finish().decode_failed && observer.finish().header_block_too_large);
  }
  {
    Http2Observer observer{system, Http2Direction::response};
    Events events;
    feed(observer, http2Frame(Http2FrameKind::headers, 0, 1, "\x88"), 16, events);
    check(observer.finish().decode_failed);
  }
  {
    Http2DirectionObserver observer{system, Http2Direction::request};
    Events events;
    feed(observer, "PRI * HTTP/2.0", 16, events);
    check(observer.finish().decode_failed);
  }
}

void testResponseMetadata() {
  SystemAllocator system;
  Http2Observer observer{system, Http2Direction::response};
  Events events;
  const auto headers = std::string{"\x88\x0f\x10\x11", 4} + "text/event-stream";
  feed(observer, http2Frame(Http2FrameKind::headers, 4, 3, headers), 1, events);
  feed(observer, http2Frame(Http2FrameKind::data, 9, 3, std::string{"\x02hello!!", 8}), 2, events);
  check(!observer.finish().decode_failed);
  check(events.fields == std::vector<std::string>{":status=200", "content-type=text/event-stream"});
  check(events.body == "hello" && events.event_stream);
  check(events.kinds.back() == Http2Event::Kind::response_ended && events.statuses.back() == 200);

  Http2HeaderMetadata metadata;
  metadata.observe(":status", "+2__00");
  metadata.observe("Content-Type", " Text/Event-Stream ; charset=utf8");
  metadata.observe("content-encoding", "identity, IDENTITY");
  check(metadata.status() == 200 && metadata.eventStream());
  metadata.observe("content-type", "text/event-stream");
  check(!metadata.eventStream());
}

void testConnectionBackpressure() {
  SystemAllocator system;
  BudgetAllocator memory{system, 1024 * 1024};
  ProxyCounters counters;
  {
    Http2Connection connection{memory, counters};
    TestByteStream child;
    TestByteStream origin;
    child.input = std::string{Http2DirectionObserver<SystemAllocator>::client_preface} + http2Frame(Http2FrameKind::headers, 5, 1, "\x82\x84");
    origin.input = http2Frame(Http2FrameKind::headers, 4, 1, "\x88") + http2Frame(Http2FrameKind::data, 1, 1, "response");
    origin.visible = 0;
    child.read_limit = 3;
    child.write_limit = 2;
    child.alternating_writes = true;
    origin.write_limit = 2;
    origin.alternating_writes = true;

    for (unsigned iteration = 0; iteration < 256 && origin.output.size() != child.input.size(); ++iteration) {
      connection.advance(child, origin, TunnelReadiness::available());
    }
    check(origin.output == child.input && connection.inflight() == 1 && !connection.finished());

    child.ended = true;
    connection.advance(child, origin, TunnelReadiness::available());
    check(origin.half_closed && connection.halfClosed() && !connection.finished());
    origin.visible = origin.input.size();
    origin.ended = true;
    for (unsigned iteration = 0; iteration < 256 && !connection.finished(); ++iteration) {
      connection.advance(child, origin, TunnelReadiness::available());
    }
    check(connection.finished() && connection.inflight() == 0);
    check(child.output == origin.input && child.half_closed);
    check(counters.read(ProxyCounter::h2_decode_failure) == 0);
  }
  check(memory.liveBytes() == 0);

  {
    Http2Connection connection{memory, counters};
    TestByteStream child;
    TestByteStream origin;
    origin.ended = true;
    connection.advance(child, origin, TunnelReadiness::available());
    check(connection.finished() && child.half_closed && origin.half_closed);
    check(counters.read(ProxyCounter::h2_decode_failure) == 1);
  }
  check(counters.read(ProxyCounter::h2_decode_failure) == 1);
  check(memory.liveBytes() == 0);
}

}

void testHttp2() {
  testAllocationBlocks();
  testRequestFragments();
  testObservationLimits();
  testResponseMetadata();
  testConnectionBackpressure();
}
