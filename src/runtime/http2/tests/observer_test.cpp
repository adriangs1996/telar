import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.http2.direction_observer;
import telar.runtime.http2.frame_reader;
import telar.runtime.http2.tests.http2_fixture;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Fields {
    void emit(const Http2Event& event) noexcept {
      if (event.kind == Http2Event::Kind::request_header) {
        fields.emplace_back(std::string{event.name} + "=" + std::string{event.value});
      }

      started += event.kind == Http2Event::Kind::request_started;
    }

    std::vector<std::string> fields;
    unsigned started = 0;
  };

  // Browsers send HEADERS with the PRIORITY flag: its five bytes precede the header block, and
  // decoding them as HPACK would lose every request of the connection.
  void testPriorityFlag() {
    constexpr std::array<std::pair<std::string_view, std::string_view>, 4> request{{
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
    const std::array frames{
        http2Frame(Http2FrameKind::headers, end_headers | end_stream | prioritized, 1, priority + block),
        http2Frame(Http2FrameKind::headers, end_headers | end_stream | prioritized | padded, 1, std::string{"\x03", 1} + priority + block + std::string(3, '\0')),
    };
    const std::vector<std::string> expected{":method=GET", ":scheme=https", ":authority=fixture.test", ":path=/priority"};

    for (const auto& frame : frames) {
      for (const std::size_t fragment : {1, 3, 16384}) {
        SystemAllocator system;
        MemoryAdapter adapter{system};
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

  const telar::testing::Case case_priority_flag{"http2_observer.priority_flag", testPriorityFlag};

}
