import std;
import telar.testing;
import telar.runtime.vocabulary.frames;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace tap = telar::runtime::plugins;

  // A writer never copies past the buffer it was given: bytes that do not fit are refused whole, and
  // the frame keeps none of them.
  void testAppendBeyondBuffer() {
    ds::Array<Byte, 32> storage{};
    const auto buffer = storage.viewMut().first(8);
    tap::FrameWriter writer{buffer};
    constexpr ds::Array<Byte, 10> bytes{1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    bool rejected = false;

    try {
      writer.append(bytes);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && writer.finish().empty());
    check(std::ranges::all_of(std::span{storage}.subspan(8), [](Byte byte) {
      return byte == 0;
    }));
  }

  const telar::testing::Case case_append_beyond_buffer{"frame_codec.append_beyond_buffer", testAppendBeyondBuffer};

}
