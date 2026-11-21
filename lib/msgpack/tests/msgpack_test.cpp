import std;
import telar.msgpack;
import telar.testing;
import telar.base.ds;

namespace {

  namespace {

    using namespace telar;
    using telar::testing::check;

    using Bytes = std::vector<std::uint8_t>;

    std::span<const std::uint8_t> view(const Bytes& bytes) {
      return bytes;
    }

    // Every value a writer can produce, read back as the same value in the smallest encoding.
    void roundTrip() {
      ds::Array<std::uint8_t, 512> storage{};
      msgpack::Writer writer{storage.viewMut()};
      const std::string long_text(300, 'x');

      writer.array(12);
      writer.nil();
      writer.boolean(true);
      writer.unsignedInteger(127);
      writer.unsignedInteger(65'536);
      writer.unsignedInteger(std::numeric_limits<std::uint64_t>::max());
      writer.integer(-1);
      writer.integer(-33);
      writer.integer(std::numeric_limits<std::int64_t>::min());
      writer.floating(1.5);
      writer.string("nvim_input");
      writer.string(long_text);
      writer.map(1);
      writer.string("rgb");
      writer.boolean(false);
      check(!writer.overflowed(), "the values fit");

      msgpack::Reader reader{writer.written()};
      std::uint32_t count = 0;
      std::uint64_t whole = 0;
      std::int64_t integer = 0;
      double number = 0;
      bool flag = false;
      check(reader.array(count) && count == 12, "array head");
      check(reader.next().token.kind == msgpack::Kind::nil, "nil");
      check(reader.boolean(flag) && flag, "true");
      check(reader.unsignedInteger(whole) && whole == 127, "fixint");
      check(reader.unsignedInteger(whole) && whole == 65'536, "uint32");
      check(reader.unsignedInteger(whole) && whole == std::numeric_limits<std::uint64_t>::max(), "uint64");
      check(reader.integer(integer) && integer == -1, "negative fixint");
      check(reader.integer(integer) && integer == -33, "int8");
      check(reader.integer(integer) && integer == std::numeric_limits<std::int64_t>::min(), "int64");
      check(reader.number(number) && number == 1.5, "float64");
      check(reader.string() == std::string_view{"nvim_input"}, "fixstr");
      check(reader.string() == std::string_view{long_text}, "str16");
      check(reader.map(count) && count == 1, "map head");
      check(reader.string() == std::string_view{"rgb"}, "key");
      check(reader.boolean(flag) && !flag, "value");
      check(reader.atEnd() && !reader.failed(), "nothing is left");
    }

    // The smallest encoding each writer call chooses, byte for byte.
    void encodings() {
      ds::Array<std::uint8_t, 64> storage{};
      msgpack::Writer writer{storage.viewMut()};

      writer.unsignedInteger(0);
      writer.unsignedInteger(128);
      writer.unsignedInteger(256);
      writer.integer(-32);
      writer.integer(-128);
      writer.string("a");
      writer.array(16);

      const Bytes expected{0x00, 0xcc, 0x80, 0xcd, 0x01, 0x00, 0xe0, 0xd0, 0x80, 0xa1, 'a', 0xdc, 0x00, 0x10};

      check(std::ranges::equal(writer.written(), expected), "smallest encodings");
    }

    void writerOverflow() {
      ds::Array<std::uint8_t, 4> storage{};
      msgpack::Writer writer{storage.viewMut()};

      writer.string("abc");
      check(!writer.overflowed() && writer.written().size() == 4, "what fits is written");
      writer.unsignedInteger(1);
      check(writer.overflowed() && writer.written().size() == 4, "what does not fit writes nothing");
      writer.nil();
      check(writer.overflowed(), "overflow stays");
    }

    // An integer from a signed family that is not negative reads as an unsigned one, a float32
    // as the double it equals, and an integer as the number it equals.
    void normalization() {
      const Bytes bytes{0xd0, 0x05, 0xd3, 0, 0, 0, 0, 0, 0, 0, 0x07, 0xca, 0x3f, 0xc0, 0x00, 0x00, 0xff};
      msgpack::Reader reader{view(bytes)};
      std::uint64_t whole = 0;
      double number = 0;

      check(reader.unsignedInteger(whole) && whole == 5, "positive int8");
      check(reader.unsignedInteger(whole) && whole == 7, "positive int64");
      check(reader.number(number) && number == 1.5, "float32");
      check(reader.number(number) && number == -1, "integer as number");
      check(!reader.failed() && reader.atEnd());
    }

    void extensions() {
      // Neovim's handles: a fixed extension holding one integer, and a sized one.
      const Bytes bytes{0xd4, 0x01, 0x2a, 0xc7, 0x03, 0x02, 0xcd, 0x03, 0xe8};
      msgpack::Reader reader{view(bytes)};
      auto token = reader.next().token;

      check(token.kind == msgpack::Kind::extension, "fixext1");
      check(token.extension == 1 && token.bytes.size() == 1 && token.bytes[0] == 0x2a, "fixext1 payload");
      token = reader.next().token;
      check(token.kind == msgpack::Kind::extension, "ext8");
      check(token.extension == 2 && token.bytes.size() == 3, "ext8 payload");

      msgpack::Reader inner{token.bytes};
      std::uint64_t handle = 0;

      check(inner.unsignedInteger(handle) && handle == 1000, "the handle inside");
    }

    // A typed read of another kind fails the reader for good and reads nothing more.
    void stickyFailure() {
      const Bytes bytes{0x01, 0xa1, 'x', 0x02};
      msgpack::Reader reader{view(bytes)};
      std::uint64_t whole = 0;

      check(!reader.string(), "an integer is not a string");
      check(reader.failed(), "the reader failed");
      check(!reader.unsignedInteger(whole), "a failed reader reads nothing");
    }

    // A length past the end of the input is incomplete, never a view past it.
    void truncation() {
      const Bytes whole{0x92, 0xa3, 'a', 'b', 'c', 0xcd, 0x01, 0x02};

      for (std::size_t size = 0; size < whole.size(); ++size) {
        const Bytes prefix(whole.begin(), whole.begin() + static_cast<std::ptrdiff_t>(size));
        msgpack::Reader reader{view(prefix)};

        check(!reader.skip(), "a truncated value does not skip");
      }

      msgpack::Reader reader{view(whole)};

      check(reader.skip() && reader.atEnd(), "the whole value skips");

      const Bytes huge{0xdb, 0xff, 0xff, 0xff, 0xff, 'x'};
      msgpack::Reader overlong{view(huge)};

      check(overlong.next().status == msgpack::Status::incomplete, "a length past the input");

      const Bytes reserved{0xc1};
      msgpack::Reader never{view(reserved)};

      check(never.next().status == msgpack::Status::malformed, "the reserved byte");
    }

    Bytes nested(unsigned depth) {
      Bytes bytes(depth, 0x91);

      bytes.push_back(0x00);
      return bytes;
    }

    void depthLimit() {
      const auto allowed = nested(msgpack::max_depth);
      const auto refused = nested(msgpack::max_depth + 1);
      msgpack::Reader shallow{view(allowed)};
      msgpack::Reader deep{view(refused)};

      check(shallow.skip() && shallow.atEnd(), "the deepest value allowed");
      check(!deep.skip() && deep.failed(), "one container deeper");

      msgpack::Scanner scanner;

      check(scanner.feed(allowed).status == msgpack::Status::ok, "the scanner allows it");
      scanner.reset();
      check(scanner.feed(refused).status == msgpack::Status::malformed, "the scanner refuses it");
    }

    // A stream of messages ends each one at the same byte however it is cut into pieces.
    void scannerBoundaries() {
      ds::Array<std::uint8_t, 1024> storage{};
      msgpack::Writer writer{storage.viewMut()};
      const std::string text(70'000 % 600, 'y');
      Bytes ends;

      const auto finish = [&] {
        ends.push_back(0);
        return writer.written().size();
      };
      std::vector<std::size_t> boundaries;

      writer.array(3);
      writer.unsignedInteger(2);
      writer.string("redraw");
      writer.array(2);
      writer.array(2);
      writer.string("flush");
      writer.array(0);
      writer.map(2);
      writer.string("k");
      writer.integer(-70'000);
      writer.string(text);
      writer.floating(2.5);
      boundaries.push_back(finish());
      writer.nil();
      boundaries.push_back(finish());
      writer.array(1);
      writer.binary(storage.view().first(40));
      boundaries.push_back(finish());
      check(!writer.overflowed());

      const auto stream = writer.written();

      for (std::size_t piece = 1; piece <= 64; ++piece) {
        msgpack::Scanner scanner;
        std::vector<std::size_t> found;
        std::size_t offset = 0;

        while (offset < stream.size()) {
          const auto chunk = stream.subspan(offset, std::min(piece, stream.size() - offset));
          std::size_t inside = 0;

          while (inside < chunk.size()) {
            const auto progress = scanner.feed(chunk.subspan(inside));

            check(progress.status != msgpack::Status::malformed, "a valid stream");
            inside += progress.consumed;
            if (progress.status == msgpack::Status::ok) {
              found.push_back(offset + inside);
            } else {
              check(inside == chunk.size(), "an unfinished value takes the whole piece");
            }
          }

          offset += chunk.size();
        }

        check(found == boundaries, "the same boundaries for every piece size");
      }
    }

    // Any bytes at all: the reader and the scanner stay inside the input and agree on where a
    // well-formed value ends.
    void arbitraryBytes() {
      std::mt19937 random{0x7e1a4};
      Bytes bytes;

      for (unsigned round = 0; round < 20'000; ++round) {
        bytes.resize(1 + (random() % 48));

        for (auto& byte : bytes) {
          byte = static_cast<std::uint8_t>(random());
        }

        msgpack::Reader reader{view(bytes)};
        msgpack::Scanner scanner;
        const bool skipped = reader.skip();
        const auto progress = scanner.feed(bytes);

        check(reader.offset() <= bytes.size() && progress.consumed <= bytes.size(), "inside the input");
        if (skipped) {
          check(progress.status == msgpack::Status::ok && progress.consumed == reader.offset(), "the scanner ends where the reader does");
        } else {
          check(progress.status != msgpack::Status::ok || progress.consumed > reader.offset() || reader.failed(), "a value the reader refuses");
        }
      }
    }

  }

  const telar::testing::Case case_round_trip{"msgpack.round_trip", roundTrip};
  const telar::testing::Case case_encodings{"msgpack.encodings", encodings};
  const telar::testing::Case case_writer_overflow{"msgpack.writer_overflow", writerOverflow};
  const telar::testing::Case case_normalization{"msgpack.normalization", normalization};
  const telar::testing::Case case_extensions{"msgpack.extensions", extensions};
  const telar::testing::Case case_sticky_failure{"msgpack.sticky_failure", stickyFailure};
  const telar::testing::Case case_truncation{"msgpack.truncation", truncation};
  const telar::testing::Case case_depth_limit{"msgpack.depth_limit", depthLimit};
  const telar::testing::Case case_scanner_boundaries{"msgpack.scanner_boundaries", scannerBoundaries};
  const telar::testing::Case case_arbitrary_bytes{"msgpack.arbitrary_bytes", arbitraryBytes};

}
