import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.traffic.http.message;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A zstd frame holding one raw block of "x", whose header declares a window of 2^window_log bytes.
  auto zstdFrame(unsigned window_log) -> ds::Array<std::uint8_t, 10> {
    const auto exponent = static_cast<std::uint8_t>(window_log - 10);

    return {0x28, 0xb5, 0x2f, 0xfd, 0x00, static_cast<std::uint8_t>(exponent << 3), 0x09, 0x00, 0x00, 'x'};
  }

  // An origin declares the window the decoder reserves, so a window past 8 MiB is refused whatever
  // the output limit allows.
  void testZstdWindowLimit() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    HttpContentCodec codec{memory};
    constexpr std::size_t limit = 1024;
    const auto accepted = zstdFrame(23);
    const auto decoded = codec.decode(accepted, "zstd", limit);

    check(decoded.decoded && std::ranges::equal(decoded.bytes(), std::string_view{"x"}));

    bool refused = false;
    const auto oversized = zstdFrame(24);

    try {
      static_cast<void>(codec.decode(oversized, "zstd", limit));
    } catch (const std::exception&) {
      refused = true;
    }

    check(refused);
  }

  // A Content-Length: 0 body under a Content-Encoding holds no coded stream, and decodes to itself
  // instead of failing the decoder.
  void testEmptyEntity() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    HttpContentCodec codec{memory};

    for (const std::string_view encoding : {"gzip", "deflate", "br", "zstd", "gzip, br"}) {
      const auto decoded = codec.decode({}, encoding, 1024);

      check(decoded.decoded && decoded.bytes().empty());
    }
  }

  const telar::testing::Case case_zstd_window_limit{"http_content.zstd_window_limit", testZstdWindowLimit};
  const telar::testing::Case case_empty_entity{"http_content.empty_entity", testEmptyEntity};

}
