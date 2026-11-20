module telar.git;

import std;
import telar.base.text;
import telar.base.ds;

namespace telar::git {

  using telar::runtime::asciiEqualIgnoreCase;
  using telar::runtime::asciiLower;

  namespace {

    bool configKeyCharacter(char character) noexcept {
      return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '-';
    }

    bool configSpace(char character) noexcept {
      return character == ' ' || character == '\t' || character == '\v' || character == '\f' || character == '\r';
    }

    bool configComment(char character) noexcept {
      return character == '#' || character == ';';
    }

  }

  namespace {

    // How reading one variable ended: on to the next line, the file read to its end or the visitor
    // done with it, or a malformed line.
    enum class Step : unsigned char {
      next,
      stop,
      malformed,
    };

    // The character a backslash escapes in a value; none for an escape git refuses.
    ds::Option<char> unescaped(char character) noexcept {
      switch (character) {
      case 't':
        return '\t';
      case 'b':
        return '\b';
      case 'n':
        return '\n';
      case '\\':
      case '"':
        return character;
      default:
        return ds::none;
      }
    }

    // A config file read as git's get_next_char reads it: CRLF reads as LF and the end of input as a
    // final LF. The unescaped subsection and value are written to `scratch`, region `b`.
    class ConfigParser {
    public:
      ConfigParser(tbc::val_a<std::string_view> text, tbc::val_b<std::span<char>> scratch) noexcept
          : text_(text),
            subsection_buffer_(scratch.first(text.size() + 1)),
            value_buffer_(scratch.subspan(text.size() + 1)) {}

      bool parse(void* target, bool (*visit)(void*, const ConfigEntry&)) {
        constexpr std::string_view byte_order_mark = "\xef\xbb\xbf";

        if (text_.starts_with(byte_order_mark)) {
          text_.remove_prefix(byte_order_mark.size());
        }

        for (;;) {
          const auto character = next();

          if (end_) {
            return true;
          }

          if (character == '\n' || configSpace(character)) {
            continue;
          }

          if (configComment(character)) {
            skipLine();
            continue;
          }

          if (character == '[') {
            if (!readSection()) {
              return false;
            }

            continue;
          }

          const auto step = readVariable(character, target, visit);
          if (step != Step::next) {
            return step == Step::stop;
          }
        }
      }

    private:
      char next() noexcept {
        if (position_ >= text_.size()) {
          end_ = true;
          return '\n';
        }

        auto character = text_[position_++];
        if (character == '\r' && position_ < text_.size() && text_[position_] == '\n') {
          character = text_[position_++];
        }

        return character;
      }

      void skipLine() noexcept {
        while (next() != '\n') {
        }
      }

      // The section header after its '['; false when it is malformed.
      bool readSection() noexcept {
        const auto start = position_;
        std::size_t length = 0;
        std::size_t dot = std::string_view::npos;
        bool extended = false;

        for (;;) {
          const auto character = next();
          if (end_ || character == '\n') {
            return false;
          }

          if (character == ']') {
            break;
          }

          if (configSpace(character)) {
            extended = true;
            break;
          }

          if (!configKeyCharacter(character) && character != '.') {
            return false;
          }

          if (character == '.' && dot == std::string_view::npos) {
            dot = length;
          }

          ++length;
        }

        auto name = text_;

        name.remove_prefix(start);
        name.remove_suffix(name.size() - length);
        subsection_length_ = 0;
        if (extended) {
          if (!readQuotedSubsection()) {
            return false;
          }

          section_ = name;
        } else if (dot != std::string_view::npos) {
          readLegacySubsection(name, dot);
          name.remove_suffix(name.size() - dot);
          section_ = name;
        } else {
          section_ = name;
        }

        have_section_ = !section_.empty();
        return have_section_;
      }

      // The [section "subsection"] form, from the space after the section's name.
      bool readQuotedSubsection() noexcept {
        auto character = next();

        while (configSpace(character)) {
          character = next();
        }

        if (character != '"') {
          return false;
        }

        for (;;) {
          character = next();
          if (character == '\n') {
            return false;
          }

          if (character == '"') {
            break;
          }

          if (character == '\\') {
            character = next();
            if (character == '\n') {
              return false;
            }
          }

          subsection_buffer_[subsection_length_++] = character;
        }

        return next() == ']';
      }

      // The legacy [section.subsection] form lowercases its subsection.
      void readLegacySubsection(std::string_view name, std::size_t dot) noexcept {
        name.remove_prefix(dot + 1);

        for (const auto byte : name) {
          subsection_buffer_[subsection_length_++] = asciiLower(byte);
        }
      }

      // A variable from the first character of its key, handed to `visit`.
      Step readVariable(char character, void* target, bool (*visit)(void*, const ConfigEntry&)) {
        if (!configKeyCharacter(character) || character == '-' || (character >= '0' && character <= '9') || !have_section_) {
          return Step::malformed;
        }

        const auto key = readKey(character);

        while (character == ' ' || character == '\t') {
          character = next();
        }

        ds::Option<std::string_view> value;

        if (character != '\n') {
          const auto length = character == '=' ? readValue() : ds::none;
          if (!length) {
            return Step::malformed;
          }

          value = std::string_view{value_buffer_.data(), *length};
        }

        const auto subsection = std::string_view{subsection_buffer_.data(), subsection_length_};
        if (!visit(target, ConfigEntry{.section = section_, .subsection = subsection, .key = key, .value = value})) {
          return Step::stop;
        }

        return end_ ? Step::stop : Step::next;
      }

      // The key that starts one character back; `character` is left on the one after it.
      tbc::val_a<std::string_view> readKey(char& character) noexcept {
        const auto key_start = position_ - 1;
        std::size_t key_length = 1;

        for (;;) {
          character = next();
          if (end_ || !configKeyCharacter(character)) {
            break;
          }

          ++key_length;
        }

        auto key = text_;

        key.remove_prefix(key_start);
        key.remove_suffix(key.size() - key_length);
        return key;
      }

      // The value after its '=', unescaped into the value buffer; its length, or none when the line
      // is malformed.
      ds::Option<std::size_t> readValue() noexcept {
        std::size_t length = 0;
        std::size_t spaces = 0;
        bool quoted = false;
        bool comment = false;

        for (;;) {
          const auto character = next();
          if (character == '\n') {
            return quoted ? ds::none : ds::Option{length};
          }

          if (comment) {
            continue;
          }

          if (configSpace(character) && !quoted) {
            if (length != 0) {
              ++spaces;
            }

            continue;
          }

          if (!quoted && configComment(character)) {
            comment = true;
            continue;
          }

          std::ranges::fill(value_buffer_.subspan(length, spaces), ' ');
          length += spaces;
          spaces = 0;

          if (character == '\\') {
            if (!readEscape(length)) {
              return ds::none;
            }

            continue;
          }

          if (character == '"') {
            quoted = !quoted;
            continue;
          }

          value_buffer_[length++] = character;
        }
      }

      // The character after a backslash in a value, written at `length`; false when git refuses the
      // escape. A backslash at the end of a line continues the value on the next.
      bool readEscape(std::size_t& length) noexcept {
        const auto character = next();
        if (character == '\n') {
          return true;
        }

        const auto escaped = unescaped(character);
        if (!escaped) {
          return false;
        }

        value_buffer_[length++] = *escaped;
        return true;
      }

      tbc::val_a<std::string_view> text_;
      tbc::val_b<std::span<char>> subsection_buffer_;
      tbc::val_b<std::span<char>> value_buffer_;
      tbc::val_a<std::string_view> section_;
      std::size_t subsection_length_ = 0;
      std::size_t position_ = 0;
      bool end_ = false;
      bool have_section_ = false;
    };

  }

  bool parseConfigEntries(std::string_view text, ds::String<Memory>& scratch, void* target, bool (*visit)(void*, const ConfigEntry&)) {
    scratch.resize((2 * text.size()) + 2);

    ConfigParser parser{text, scratch.viewMut()};

    return parser.parse(target, visit);
  }

  ds::Option<bool> configBoolean(ds::Option<std::string_view> value) noexcept {
    if (!value) {
      return true;
    }

    for (const auto* const truthy : {"true", "yes", "on", "1"}) {
      if (asciiEqualIgnoreCase(*value, truthy)) {
        return true;
      }
    }

    for (const auto* const falsy : {"false", "no", "off", "0", ""}) {
      if (asciiEqualIgnoreCase(*value, falsy)) {
        return false;
      }
    }

    return ds::none;
  }

}
