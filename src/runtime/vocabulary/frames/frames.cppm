module;
#include "tbc/hot_path.hpp"

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
      explicit FrameReader(tbc::view<std::span<const Byte>, tbc::lt::a> input) noexcept;

      // Generic over the caller's integer and enumeration types, so these stay here.
      template <std::unsigned_integral Integer>
      TBC_HOT_PATH inline Integer integer() {
        return LittleEndian<Integer>::decode(remaining_);
      }

      std::int64_t timestamp();

      bool boolean();

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_HOT_PATH Enum tag(Enum maximum) {
        const auto value = integer<Byte>();
        if (value > static_cast<Byte>(maximum)) {
          throw EncodingError{"Unknown tap enumeration value"};
        }

        return static_cast<Enum>(value);
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_HOT_PATH void require(Enum expected) {
        if (integer<Byte>() != static_cast<Byte>(expected)) {
          throw EncodingError{"Unexpected tap frame tag"};
        }
      }

      tbc::view<std::span<const Byte>, tbc::lt::a> bytes();

      tbc::view<std::string_view, tbc::lt::a> text();

      void finish() const;

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
      // Generic over the caller's integer and enumeration types, so these stay here.
      template <std::unsigned_integral Integer>
      TBC_HOT_PATH inline void integer(Integer) {
        add(sizeof(Integer));
      }

      void timestamp(std::int64_t);

      void boolean(bool);

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_HOT_PATH void tag(Enum) {
        integer(Byte{});
      }

      void bytes(std::span<const Byte> value);

      void text(std::string_view value);

      std::size_t finish() const noexcept;

    private:
      void add(std::size_t count);

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
      explicit FrameWriter(tbc::view<std::span<Byte>, tbc::lt::a> output) noexcept;

      // Generic over the caller's integer and enumeration types, so these stay here.
      template <std::unsigned_integral Integer>
      TBC_HOT_PATH inline void integer(Integer value) {
        LittleEndian<Integer>::encode(value, remaining_);
      }

      void timestamp(std::int64_t value);

      void boolean(bool value);

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_HOT_PATH void tag(Enum value) {
        integer(static_cast<Byte>(value));
      }

      void bytes(std::span<const Byte> value);

      void text(std::string_view value);

      void append(std::span<const Byte> value);

      tbc::view<std::span<const Byte>, tbc::lt::a> finish() const noexcept;

    private:
      tbc::view<std::span<Byte>, tbc::lt::a> output_;
      tbc::view<std::span<Byte>, tbc::lt::a> remaining_;
    };

  }
}
