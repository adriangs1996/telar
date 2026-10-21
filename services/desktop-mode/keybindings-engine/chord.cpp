#include "chord.hpp"
#include <array>
#include <utility>

namespace keybindings {
  namespace {
    namespace utf8 {
      constexpr std::size_t invalidLength = 0;
      constexpr std::size_t asciiLength = 1;
      constexpr std::size_t twoByteLength = 2;
      constexpr std::size_t threeByteLength = 3;
      constexpr std::size_t fourByteLength = 4;
      constexpr std::size_t firstContinuationIndex = 1;

      constexpr unsigned char asciiMax = 0x7f;
      constexpr unsigned char twoByteLeadMin = 0xc2;
      constexpr unsigned char twoByteLeadMax = 0xdf;
      constexpr unsigned char threeByteLeadMin = 0xe0;
      constexpr unsigned char threeByteLeadMax = 0xef;
      constexpr unsigned char fourByteLeadMin = 0xf0;
      constexpr unsigned char fourByteLeadMax = 0xf4;

      constexpr unsigned char asciiPayloadMask = 0x7f;
      constexpr unsigned char continuationTagMask = 0xc0;
      constexpr unsigned char continuationTag = 0x80;
      constexpr unsigned char continuationPayloadMask = 0x3f;
      constexpr unsigned int continuationPayloadBits = 6;

      constexpr char32_t asciiMinimum = 0;
      constexpr char32_t twoByteMinimum = 0x80;
      constexpr char32_t threeByteMinimum = 0x800;
      constexpr char32_t fourByteMinimum = 0x10000;
      constexpr char32_t maximumCodepoint = 0x10ffff;
      constexpr char32_t surrogateMin = 0xd800;
      constexpr char32_t surrogateMax = 0xdfff;

      constexpr std::array minimumCodepoints{
          asciiMinimum,
          twoByteMinimum,
          threeByteMinimum,
          fourByteMinimum,
      };
    } // namespace utf8

    constexpr char lower(char value) noexcept {
      return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
    }

    bool equalName(std::string_view left, std::string_view right) noexcept {
      if (left.size() != right.size()) {
        return false;
      }

      for (std::size_t index = 0; index < left.size(); ++index) {
        if (lower(left[index]) != lower(right[index])) {
          return false;
        }
      }

      return true;
    }

    std::expected<char32_t, const char *> codepoint(std::string_view text) noexcept {
      const auto first = static_cast<unsigned char>(text.front());
      std::size_t length = utf8::invalidLength;

      if (first <= utf8::asciiMax) {
        length = utf8::asciiLength;
      } else if (first >= utf8::twoByteLeadMin && first <= utf8::twoByteLeadMax) {
        length = utf8::twoByteLength;
      } else if (first >= utf8::threeByteLeadMin && first <= utf8::threeByteLeadMax) {
        length = utf8::threeByteLength;
      } else if (first >= utf8::fourByteLeadMin && first <= utf8::fourByteLeadMax) {
        length = utf8::fourByteLength;
      }

      if (length == utf8::invalidLength) {
        return std::unexpected("Invalid UTF-8 key");
      }

      if (length != text.size()) {
        return std::unexpected("A key must contain one Unicode codepoint");
      }

      const auto leadPayloadMask =
          length == utf8::asciiLength ? utf8::asciiPayloadMask : utf8::asciiPayloadMask >> length;
      char32_t value = first & leadPayloadMask;

      for (std::size_t index = utf8::firstContinuationIndex; index < length; ++index) {
        const auto byte = static_cast<unsigned char>(text[index]);

        if ((byte & utf8::continuationTagMask) != utf8::continuationTag) {
          return std::unexpected("Invalid UTF-8 key");
        }

        value = (value << utf8::continuationPayloadBits) | (byte & utf8::continuationPayloadMask);
      }

      const auto minimum = utf8::minimumCodepoints[length - utf8::asciiLength];
      const bool surrogate = value >= utf8::surrogateMin && value <= utf8::surrogateMax;

      if (value < minimum || value > utf8::maximumCodepoint || surrogate) {
        return std::unexpected("Invalid UTF-8 key");
      }

      return value;
    }

    std::expected<Chord, const char *> parseCode(std::string_view text) noexcept {
      constexpr std::pair<std::string_view, KeyCode> names[]{
          {"up", KeyCode::Up},
          {"down", KeyCode::Down},
          {"left", KeyCode::Left},
          {"right", KeyCode::Right},
          {"home", KeyCode::Home},
          {"end", KeyCode::End},
          {"delete", KeyCode::Delete},
          {"del", KeyCode::Delete},
          {"pageup", KeyCode::PageUp},
          {"page-up", KeyCode::PageUp},
          {"pagedown", KeyCode::PageDown},
          {"page-down", KeyCode::PageDown},
          {"enter", KeyCode::Enter},
          {"return", KeyCode::Enter},
          {"escape", KeyCode::Escape},
          {"esc", KeyCode::Escape},
          {"backspace", KeyCode::Backspace},
          {"tab", KeyCode::Tab},
          {"backtab", KeyCode::BackTab},
      };

      for (const auto &[name, code] : names) {
        if (equalName(text, name)) {
          return Chord{.code = code};
        }
      }

      if (equalName(text, "space")) {
        return Chord{.code = KeyCode::Character, .character = U' '};
      }

      if (equalName(text, "plus")) {
        return Chord{.code = KeyCode::Character, .character = U'+'};
      }

      const auto value = codepoint(text);

      if (!value) {
        return std::unexpected(value.error());
      }

      return Chord{.code = KeyCode::Character, .character = *value};
    }

    std::expected<Chord, const char *> normalize(Chord key) noexcept {
      if (key.code == KeyCode::Tab && key.has(Modifier::Shift) && !key.hasCommandModifier()) {
        key.code = KeyCode::BackTab;
        key.modifiers = 0;
      }

      if (key.code != KeyCode::Character) {
        return key;
      }

      if ((key.has(Modifier::Control) || key.has(Modifier::Super)) && key.character >= U'A' &&
          key.character <= U'Z') {
        key.character += U'a' - U'A';
      }

      // Keep the existing Lua chord spelling compatible with Telar's native decoder.
      if (key.has(Modifier::Shift) && !key.has(Modifier::Super)) {
        if (key.has(Modifier::Control)) {
          return std::unexpected("Unrepresentable key combination");
        }

        if (key.character >= U'a' && key.character <= U'z') {
          key.character -= U'a' - U'A';
        } else if (key.character != U' ' && !(key.character >= U'A' && key.character <= U'Z')) {
          return std::unexpected("Unrepresentable key combination");
        }

        key.modifiers &= ~static_cast<std::uint8_t>(Modifier::Shift);
      }

      return key;
    }
  } // namespace

  bool Chord::has(Modifier modifier) const noexcept {
    return (modifiers & static_cast<std::uint8_t>(modifier)) != 0;
  }

  bool Chord::hasCommandModifier() const noexcept {
    return has(Modifier::Control) || has(Modifier::Alt) || has(Modifier::Super);
  }

  std::expected<Chord, const char *> parseChord(std::string_view text) noexcept {
    if (text.empty() || text.find('\0') != std::string_view::npos) {
      return std::unexpected("A chord cannot be empty or contain NUL");
    }

    std::uint8_t modifiers = 0;
    std::string_view name;

    while (true) {
      const auto separator = text.find('+');
      const auto part = text.substr(0, separator);

      if (part.empty()) {
        return std::unexpected("Empty chord component; use 'plus' for the '+' key");
      }

      if (!name.empty()) {
        return std::unexpected("Modifiers must precede the key");
      }

      std::uint8_t modifier = 0;

      if (equalName(part, "ctrl") || equalName(part, "control")) {
        modifier = static_cast<std::uint8_t>(Modifier::Control);
      } else if (equalName(part, "alt")) {
        modifier = static_cast<std::uint8_t>(Modifier::Alt);
      } else if (equalName(part, "shift")) {
        modifier = static_cast<std::uint8_t>(Modifier::Shift);
      } else if (equalName(part, "super") || equalName(part, "cmd") || equalName(part, "command")) {
        modifier = static_cast<std::uint8_t>(Modifier::Super);
      } else {
        name = part;
      }

      if (modifiers & modifier) {
        return std::unexpected("Duplicate modifier");
      }

      modifiers |= modifier;

      if (separator == std::string_view::npos) {
        break;
      }

      text.remove_prefix(separator + 1);
    }

    if (name.empty()) {
      return std::unexpected("Missing key after modifiers");
    }

    auto key = parseCode(name);

    if (!key) {
      return key;
    }

    key->modifiers = modifiers;
    return normalize(*key);
  }
} // namespace keybindings
