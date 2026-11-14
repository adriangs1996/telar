export module telar.runtime.vocabulary.frames;

import std;
import telar.tbc;

import telar.wire.vocabulary;

// Interface: plugins/frame_output.cppm
export {
  namespace telar::runtime::plugins {

    template <typename Output>
    concept FrameOutput = requires(Output& output, std::span<const Byte> bytes, std::string_view text) {
      { output.integer(std::uint64_t{}) } -> std::same_as<void>;
      { output.integer(std::uint32_t{}) } -> std::same_as<void>;
      { output.integer(std::uint16_t{}) } -> std::same_as<void>;
      { output.integer(Byte{}) } -> std::same_as<void>;
      { output.tag(std::byte{}) } -> std::same_as<void>;
      { output.timestamp(std::int64_t{}) } -> std::same_as<void>;
      { output.boolean(false) } -> std::same_as<void>;
      { output.bytes(bytes) } -> std::same_as<void>;
      { output.text(text) } -> std::same_as<void>;
    };

  }
}

// Interface: plugins/frame_reader.cppm
export {
  namespace telar::runtime::plugins {

    // Reads fields from a frame, region `a`; the bytes and text it hands out view that frame.
    class FrameReader {
    public:
      inline explicit FrameReader(tbc::view<std::span<const Byte>, tbc::lt::a> input) noexcept
          : remaining_(input) {}

      template <std::unsigned_integral Integer>
      inline Integer integer() {
        return LittleEndian<Integer>::decode(remaining_);
      }

      inline std::int64_t timestamp() {
        return std::bit_cast<std::int64_t>(integer<std::uint64_t>());
      }

      inline bool boolean() {
        return BoolByte::decode(remaining_);
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      Enum tag(Enum maximum) {
        const auto value = integer<Byte>();
        if (value > static_cast<Byte>(maximum)) {
          throw EncodingError{"Unknown tap enumeration value"};
        }

        return static_cast<Enum>(value);
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      void require(Enum expected) {
        if (integer<Byte>() != static_cast<Byte>(expected)) {
          throw EncodingError{"Unexpected tap frame tag"};
        }
      }

      inline tbc::view<std::span<const Byte>, tbc::lt::a> bytes() {
        const auto length = integer<std::uint32_t>();
        if (length > remaining_.size()) {
          throw EncodingError{"Truncated tap field"};
        }

        const auto value = remaining_.first(length);

        remaining_ = remaining_.subspan(length);
        return value;
      }

      inline tbc::view<std::string_view, tbc::lt::a> text() {
        const auto value = bytes();

        return {reinterpret_cast<const char*>(value.data()), value.size()};
      }

      inline void finish() const {
        if (!remaining_.empty()) {
          throw EncodingError{"Trailing tap frame bytes"};
        }
      }

    private:
      tbc::view<std::span<const Byte>, tbc::lt::a> remaining_;
    };

  }
}

// Interface: plugins/frame_size.cppm
export {
  namespace telar::runtime::plugins {

    class FrameSize {
    public:
      template <std::unsigned_integral Integer>
      inline void integer(Integer) {
        add(sizeof(Integer));
      }

      inline void timestamp(std::int64_t) {
        integer(std::uint64_t{});
      }

      inline void boolean(bool) {
        integer(Byte{});
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      void tag(Enum) {
        integer(Byte{});
      }

      inline void bytes(std::span<const Byte> value) {
        if (value.size() > std::numeric_limits<std::uint32_t>::max()) {
          throw EncodingError{"Tap field exceeds its frame buffer"};
        }

        integer(std::uint32_t{});
        add(value.size());
      }

      inline void text(std::string_view value) {
        bytes({reinterpret_cast<const Byte*>(value.data()), value.size()});
      }

      inline std::size_t finish() const noexcept {
        return size_;
      }

    private:
      inline void add(std::size_t count) {
        size_ = checkedWireSize(size_, count);
      }

      std::size_t size_ = 0;
    };

    static_assert(FrameOutput<FrameSize>);

  }
}

// Interface: plugins/frame_writer.cppm
export {
  namespace telar::runtime::plugins {

    // Writes fields into a caller's buffer, region `a`, and hands back the part written.
    class FrameWriter {
    public:
      inline explicit FrameWriter(tbc::view<std::span<Byte>, tbc::lt::a> output) noexcept
          : output_(output),
            remaining_(output) {}

      template <std::unsigned_integral Integer>
      inline void integer(Integer value) {
        LittleEndian<Integer>::encode(value, remaining_);
      }

      inline void timestamp(std::int64_t value) {
        integer(std::bit_cast<std::uint64_t>(value));
      }

      inline void boolean(bool value) {
        BoolByte::encode(value, remaining_);
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      void tag(Enum value) {
        integer(static_cast<Byte>(value));
      }

      inline void bytes(std::span<const Byte> value) {
        if (value.size() > std::numeric_limits<std::uint32_t>::max() || remaining_.size() < sizeof(std::uint32_t) || value.size() > remaining_.size() - sizeof(std::uint32_t)) {
          throw EncodingError{"Tap field exceeds its frame buffer"};
        }

        integer(static_cast<std::uint32_t>(value.size()));
        if (!value.empty()) {
          std::memcpy(remaining_.data(), value.data(), value.size());
        }

        remaining_ = remaining_.subspan(value.size());
      }

      inline void text(std::string_view value) {
        bytes({reinterpret_cast<const Byte*>(value.data()), value.size()});
      }

      inline void append(std::span<const Byte> value) {
        if (value.size() > remaining_.size()) {
          throw EncodingError{"Tap data exceeds its frame buffer"};
        }

        if (!value.empty()) {
          std::memcpy(remaining_.data(), value.data(), value.size());
        }

        remaining_ = remaining_.subspan(value.size());
      }

      inline tbc::view<std::span<const Byte>, tbc::lt::a> finish() const noexcept {
        return output_.first(output_.size() - remaining_.size());
      }

    private:
      tbc::view<std::span<Byte>, tbc::lt::a> output_;
      tbc::view<std::span<Byte>, tbc::lt::a> remaining_;
    };

  }
}
