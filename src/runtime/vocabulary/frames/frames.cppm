module;
#include "tbc/annotations.hpp"

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
      explicit FrameReader(tbc::val_a<std::span<const Byte>> input) noexcept;

      // Generic over the caller's integer and enumeration types, so these stay here.
      template <std::unsigned_integral Integer>
      TBC_GENERIC inline Integer integer() {
        return LittleEndian<Integer>::decode(remaining_);
      }

      std::int64_t timestamp();

      bool boolean();

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_GENERIC Enum tag(Enum maximum) {
        const auto value = integer<Byte>();
        if (value > static_cast<Byte>(maximum)) {
          throw EncodingError{"Unknown tap enumeration value"};
        }

        return static_cast<Enum>(value);
      }

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_GENERIC void require(Enum expected) {
        if (integer<Byte>() != static_cast<Byte>(expected)) {
          throw EncodingError{"Unexpected tap frame tag"};
        }
      }

      tbc::val_a<std::span<const Byte>> bytes();

      tbc::val_a<std::string_view> text();

      void finish() const;

    private:
      tbc::val_a<std::span<const Byte>> remaining_;
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
      TBC_GENERIC inline void integer([[maybe_unused]] Integer value) {
        add(sizeof(Integer));
      }

      void timestamp(std::int64_t);

      void boolean(bool);

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_GENERIC void tag([[maybe_unused]] Enum value) {
        integer(Byte{});
      }

      void bytes(std::span<const Byte> value);

      void text(std::string_view value);

      [[nodiscard]] std::size_t finish() const noexcept;

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
      explicit FrameWriter(tbc::val_a<std::span<Byte>> output) noexcept;

      // Generic over the caller's integer and enumeration types, so these stay here.
      template <std::unsigned_integral Integer>
      TBC_GENERIC inline void integer(Integer value) {
        LittleEndian<Integer>::encode(value, remaining_);
      }

      void timestamp(std::int64_t value);

      void boolean(bool value);

      template <typename Enum>
        requires std::is_enum_v<Enum>
      TBC_GENERIC void tag(Enum value) {
        integer(static_cast<Byte>(value));
      }

      void bytes(std::span<const Byte> value);

      void text(std::string_view value);

      void append(std::span<const Byte> value);

      [[nodiscard]] tbc::val_a<std::span<const Byte>> finish() const noexcept;

    private:
      tbc::val_a<std::span<Byte>> output_;
      tbc::val_a<std::span<Byte>> remaining_;
    };

  }
}
