import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.http2.direction_observer;
import telar.runtime.http2.frame_reader;
import telar.runtime.http2.tests.http2_fixture;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Fields {
    void emit(const Http2Event& event) noexcept {
      if (event.kind == Http2Event::Kind::request_header || event.kind == Http2Event::Kind::response_header) {
        fields.emplace_back(std::to_string(event.stream) + ":" + std::string{event.name} + "=" + std::string{event.value});
      }

      started += event.kind == Http2Event::Kind::request_started;
    }

    std::vector<std::string> fields;
    unsigned started = 0;
  };

  // Browsers send HEADERS with the PRIORITY flag: its five bytes precede the header block, and
  // decoding them as HPACK would lose every request of the connection.
  void testPriorityFlag() {
    constexpr ds::Array<std::pair<std::string_view, std::string_view>, 4> request{{
        {":method", "GET"},
        {":scheme", "https"},
        {":authority", "fixture.test"},
        {":path", "/priority"},
    }};

    const auto block = hpackFields(request);
    // An exclusive dependency on stream 0x80000003 with weight 255: as HPACK, 0x80 is an invalid index.
    const std::string priority{"\x80\x00\x00\x03\xff", 5};
    constexpr auto end_headers = static_cast<std::uint8_t>(Http2Flag::end_headers);
    constexpr auto end_stream = static_cast<std::uint8_t>(Http2Flag::end_stream);
    constexpr auto padded = static_cast<std::uint8_t>(Http2Flag::padded);
    constexpr auto prioritized = static_cast<std::uint8_t>(Http2Flag::priority);
    const ds::Array frames{
        http2Frame(Http2FrameKind::headers, end_headers | end_stream | prioritized, 1, priority + block),
        http2Frame(Http2FrameKind::headers, end_headers | end_stream | prioritized | padded, 1, std::string{"\x03", 1} + priority + block + std::string(3, '\0')),
    };

    const std::vector<std::string> expected{"1::method=GET", "1::scheme=https", "1::authority=fixture.test", "1::path=/priority"};

    for (const auto& frame : frames) {
      for (const std::size_t fragment : {1, 3, 16384}) {
        telar::testing::TestMemory adapter;
        Memory& memory = adapter;
        Http2Observer observer{memory, Http2Direction::request};
        Fields events;

        for (std::string_view input = frame; !input.empty();) {
          const auto count = std::min(fragment, input.size());

          observer.observe({reinterpret_cast<const std::uint8_t*>(input.data()), count}, events);
          input.remove_prefix(count);
        }

        check(!observer.finish().decode_failed);
        check(events.fields == expected && events.started == 1);
      }
    }
  }

  // Feeds `input` to an observer of `direction` and returns what it emitted and whether decoding
  // failed.
  auto observe(Http2Direction direction, std::string_view input) -> std::pair<Fields, bool> {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    Http2Observer observer{memory, direction};
    Fields events;

    observer.observe({reinterpret_cast<const std::uint8_t*>(input.data()), input.size()}, events);
    return {events, observer.finish().decode_failed};
  }

  // A header block continued on another stream is not that stream's headers: the observer reports a
  // decode failure and attributes no header to either stream.
  void testContinuationOnOtherStream() {
    constexpr ds::Array<std::pair<std::string_view, std::string_view>, 4> request{{
        {":method", "GET"},
        {":scheme", "https"},
        {":authority", "fixture.test"},
        {":path", "/continued"},
    }};

    const auto block = hpackFields(request);
    const auto split = block.size() / 2;
    const auto input = http2Frame(Http2FrameKind::headers, static_cast<std::uint8_t>(Http2Flag::end_stream), 1, block.substr(0, split)) + http2Frame(Http2FrameKind::continuation, static_cast<std::uint8_t>(Http2Flag::end_headers), 3, block.substr(split));
    const auto [events, failed] = observe(Http2Direction::request, input);

    check(failed && events.fields.empty() && events.started == 0);
  }

  // A pushed request's header block changes the connection's HPACK table like any other: a response
  // that refers to an entry it added decodes, and the pushed fields are not taken for the response's.
  void testPushPromiseKeepsHpackState() {
    // :method GET, :scheme https, :path /, then `x-push: one` added to the dynamic table as entry 62.
    const std::string promised{"\x00\x00\x00\x02\x82\x87\x84\x40\x06x-push\x03one", 19};
    // :status 200, then dynamic entry 62.
    const std::string response{"\x88\xbe", 2};
    constexpr auto end_headers = static_cast<std::uint8_t>(Http2Flag::end_headers);
    constexpr auto end_stream = static_cast<std::uint8_t>(Http2Flag::end_stream);
    const auto input = http2Frame(Http2FrameKind::push_promise, end_headers, 1, promised) + http2Frame(Http2FrameKind::headers, end_headers | end_stream, 1, response);
    const auto [events, failed] = observe(Http2Direction::response, input);

    check(!failed && events.fields == std::vector<std::string>{"1::status=200", "1:x-push=one"});
  }

  const telar::testing::Case case_priority_flag{"http2_observer.priority_flag", testPriorityFlag};
  const telar::testing::Case case_continuation_on_other_stream{"http2_observer.continuation_on_other_stream", testContinuationOnOtherStream};
  const telar::testing::Case case_push_promise_keeps_hpack_state{"http2_observer.push_promise_keeps_hpack_state", testPushPromiseKeepsHpackState};

}
