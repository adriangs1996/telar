module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.keys:key_encoder;

import std;

import telar.config.client;
import telar.base.text;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;

// Interface: input/key_character.cppm
export {
  namespace telar::gui::inline foundation::inline keys {

    struct KeyCharacter {
      [[nodiscard]] static std::uint32_t pack(std::uint32_t codepoint);

      [[nodiscard]] static Utf8Scalar text(std::uint32_t storage) noexcept;

      [[nodiscard]] static std::uint32_t codepoint(std::uint32_t storage);
    };

  }
}

// Interface: input/key_event.cppm
export {
  namespace telar::gui::inline foundation::inline keys {

    enum class KeyPhase : std::uint8_t {
      press,
      repeat,
      release,
    };

    struct BindingEvent {
      KeyChord chord;
      KeyPhase phase = KeyPhase::press;
      std::uint64_t physical = 0;
    };

    struct BindingRepeat {
      std::uint64_t interval_ns = 0;
      std::uint64_t owner = 0;

      bool operator==(const BindingRepeat&) const = default;
    };

  }
}

// Interface: input/terminal_key.cppm
export {
  namespace telar::gui::inline foundation::inline keys {

    enum class KittyKeyboardFlag : std::uint8_t {
      disambiguate = 1,
      report_events = 2,
      alternate_keys = 4,
      all_keys = 8,
      associated_text = 16,
    };

    struct KittyCodepoints {
      std::uint32_t primary = 0;
      ds::Option<std::uint32_t> shifted = ds::none;
      ds::Option<std::uint32_t> base = ds::none;
    };

    struct TerminalKey {
      KeyChord::Key code = KeyChord::Key::character;
      std::uint32_t codepoint = 0;
      unsigned modifiers = 0;
      KeyPhase phase = KeyPhase::press;
      ds::Option<KittyCodepoints> kitty = ds::none;

      [[nodiscard]] bool has(KeyChord::Modifier modifier) const noexcept;
    };

  }
}

// Interface: input/key_encoder.cppm
export {
  namespace telar::gui::inline foundation::inline keys {

    class KeyEncoder {
    public:
      static constexpr std::size_t maximum_codepoint_fields = 3;
      static constexpr std::size_t codepoint_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
      static constexpr std::size_t modifier_digits = std::numeric_limits<std::uint8_t>::digits10 + 1;
      static constexpr std::size_t event_digits = 1;
      static constexpr std::size_t scalar_digits = 7;
      static constexpr std::size_t capacity = std::string_view{"\x1b[::;:;u"}.size() + (maximum_codepoint_fields * codepoint_digits) + modifier_digits + event_digits + scalar_digits;

      // The key one alternate-scroll step sends: Up or Down as the cursor key mode encodes them, as
      // Ghostty sends it (Surface.zig), whatever keyboard protocol the application asked for.
      [[nodiscard]] std::string_view alternateScroll(bool up, const InputModes& modes);

      [[nodiscard]] std::string_view encode(const TerminalKey& key, const InputModes& modes);

    private:
      using Code = KeyChord::Key;
      using Modifier = KeyChord::Modifier;

      enum class SequenceCode : std::uint8_t {
        cursor = 1,
        erase = 3,
        page_up = 5,
        page_down = 6,
      };

      static constexpr char escape = '\x1b';
      static constexpr char erase = '\x7f';

      static bool reportsLegacyRelease(Code code) noexcept;

      struct Encoding {
        explicit Encoding(const TerminalKey& key, const InputModes& modes);

        [[nodiscard]] bool has(KittyKeyboardFlag flag) const noexcept;

        [[nodiscard]] bool usesKitty(const TerminalKey& key) const noexcept;

        unsigned modifier;
        unsigned flags;
        bool cursor_keys;
        ds::Option<unsigned> event;
      };

      [[nodiscard]] std::string_view view() const noexcept;

      void append(std::string_view text);

      void byte(char value);

      void number(std::uint32_t value);

      static std::uint32_t textCodepoint(const TerminalKey& key);

      bool encodeText(const TerminalKey& key, const Encoding& encoding);

      static ds::Option<std::uint32_t> associatedText(const TerminalKey& key, const Encoding& encoding);

      void kittyCodepoints(const TerminalKey& key, const Encoding& encoding);

      void encodeKitty(const TerminalKey& key, const Encoding& encoding);

      void altText(const TerminalKey& key, std::string_view text);

      static ds::Option<char> controlByte(std::uint32_t codepoint) noexcept;

      void legacyCharacter(const TerminalKey& key);

      void sequence(SequenceCode code, char final, const Encoding& encoding);

      void encodeLegacy(const TerminalKey& key, const Encoding& encoding, const InputModes& modes);

      std::array<char, capacity> bytes_{};
      std::size_t used_ = 0;
    };

  }
}

// Interface: input/paste_encoding.cppm
export {
  namespace telar::gui::inline foundation::inline keys {

    // A paste as one bounded value, encoded by the paste encoder the runtime uses too.
    struct PasteEncoding {
      template <std::size_t Capacity>
      [[nodiscard]] TBC_GENERIC inline static BoundedText<Capacity + BracketedPaste::framing_bytes> encode(std::string_view text, bool bracketed) {
        if (text.size() > Capacity) {
          throw std::length_error{"Paste text exceeds its capacity"};
        }

        BoundedText<Capacity + BracketedPaste::framing_bytes> encoded;

        BracketedPaste::encode(text, bracketed, [&](std::string_view piece) {
          encoded.append(piece);
        });

        return encoded;
      }
    };

  }
}
