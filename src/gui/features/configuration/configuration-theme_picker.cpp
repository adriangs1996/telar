module telar.gui.features.configuration;

import std;

import telar.base.memory.containers;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::configuration {

  namespace {

    constexpr char asciiLower(char character) noexcept {
      return character >= 'A' && character <= 'Z' ? static_cast<char>(character + 'a' - 'A') : character;
    }

    bool startsWithIgnoringCase(std::string_view text, std::string_view prefix) noexcept {
      if (prefix.size() > text.size()) {
        return false;
      }

      for (std::size_t index = 0; index < prefix.size(); ++index) {
        if (asciiLower(prefix[index]) != asciiLower(text[index])) {
          return false;
        }
      }

      return true;
    }

    constexpr char asciiUpper(char character) noexcept {
      return character >= 'a' && character <= 'z' ? static_cast<char>(character - 'a' + 'A') : character;
    }

    // The value of a lowercase or uppercase hexadecimal digit, or none.
    constexpr ds::Option<std::uint64_t> hexDigit(char character) noexcept {
      constexpr std::uint64_t first_letter = 10;

      if (character >= '0' && character <= '9') {
        return static_cast<std::uint64_t>(character - '0');
      }

      const auto lower = asciiLower(character);
      if (lower >= 'a' && lower <= 'f') {
        return static_cast<std::uint64_t>(lower - 'a') + first_letter;
      }

      return ds::none;
    }

    constexpr std::size_t fingerprint_digits = 16;
    constexpr unsigned digit_bits = 4;

    // The preset a name stands for, by its canonical name, or none when it names no preset.
    ds::Option<std::string_view> presetOf(std::string_view name) noexcept {
      if (name.size() > ThemeEntry::name_bytes) {
        return ds::none;
      }

      ds::Array<char, ThemeEntry::name_bytes> lowercase{};

      std::ranges::transform(name, lowercase.viewMut().begin(), asciiLower);
      const auto canonical = canonicalThemeName({lowercase.data(), name.size()});
      const auto* const found = std::ranges::find(theme_presets, canonical, &ThemePreset::name);

      return found == theme_presets.end() ? ds::none : ds::Option{found->name};
    }

    // The presets whose names read better than their capitalized keys.
    constexpr ds::Array<std::pair<std::string_view, std::string_view>, 2> preset_labels{
        {
            {"catppuccin", "Catppuccin Mocha"},
            {"kanagawa", "Kanagawa Wave"},
        },
    };

    class Fingerprint {
    public:
      void bytes(std::span<const std::uint8_t> data) noexcept {
        for (const auto byte : data) {
          value_ = (value_ ^ byte) * prime;
        }
      }

      void byte(std::uint8_t data) noexcept {
        bytes(std::span{&data, 1});
      }

      void color(const CellColor& color) noexcept {
        byte(static_cast<std::uint8_t>(color.kind));
        bytes(color.channels.view());
      }

      void rgb(const ds::Option<ThemeRgb>& rgb) noexcept {
        byte(rgb ? 1 : 0);
        if (rgb) {
          bytes(rgb->view());
        }
      }

      void theme(const ThemeValues& values) noexcept {
        byte(static_cast<std::uint8_t>(values.base));
        for (const auto& color : values.palette) {
          this->color(color);
        }

        const auto& terminal = values.terminal;

        bytes(terminal.foreground.view());
        bytes(terminal.background.view());
        rgb(terminal.cursor_color);
        rgb(terminal.cursor_text_color);
        for (const auto& entry : terminal.palette) {
          bytes(entry.view());
        }

        for (const auto& style : values.syntax_styles) {
          byte(style ? 1 : 0);
          if (style) {
            color(style->color);
            byte(static_cast<std::uint8_t>((style->italic ? 1U : 0U) | (style->bold ? 2U : 0U)));
          }
        }
      }

      void variant(const ds::Option<ThemeValues>& values) noexcept {
        byte(values ? 1 : 0);
        if (values) {
          theme(*values);
        }
      }

      [[nodiscard]] std::uint64_t value() const noexcept {
        return value_;
      }

    private:
      // FNV-1a, 64 bits.
      static constexpr std::uint64_t offset = 14695981039346656037ULL;
      static constexpr std::uint64_t prime = 1099511628211ULL;

      std::uint64_t value_ = offset;
    };

  }

  ThemeCatalog::ThemeCatalog() {
    for (const auto& preset : theme_presets) {
      insert(preset.name, preset.name, preset.values);
    }
  }

  void ThemeCatalog::add(std::string_view name, const ThemeValues& values) {
    const auto preset = presetOf(name);
    const auto canonical = preset.valueOr(name);
    const auto entries = this->entries();
    const auto found = static_cast<std::size_t>(std::ranges::find_if(entries, [&](const ThemeEntry& entry) {
      return entry.canonical.view() == canonical;
    }) - entries.begin());

    // The theme it replaces leaves first, so the new one takes its place in the order of labels.
    if (found != count_) {
      auto all = entries_.viewMut();

      std::shift_left(all.begin() + static_cast<std::ptrdiff_t>(found), all.begin() + static_cast<std::ptrdiff_t>(count_), 1);
      --count_;
    }

    insert(name, canonical, values);
  }

  void ThemeCatalog::insert(std::string_view name, std::string_view canonical, const ThemeValues& values) {
    if (count_ == capacity) {
      throw std::length_error{"The theme catalog is full"};
    }

    ThemeEntry entry;

    entry.name.assign(name);
    entry.canonical.assign(canonical);
    entry.values = values;
    entry.light = lightTheme(values);
    // A preset under its own name shows its own label; a configured name shows itself.
    themeLabel(name == canonical && presetOf(name) ? canonical : name, entry.label);
    const auto entries = this->entries();
    const auto position = std::ranges::upper_bound(entries, entry.label.view(), {}, [](const ThemeEntry& existing) {
      return existing.label.view();
    }) - entries.begin();

    auto all = entries_.viewMut();

    std::shift_right(all.begin() + position, all.begin() + static_cast<std::ptrdiff_t>(count_) + 1, 1);
    all[static_cast<std::size_t>(position)] = std::move(entry);
    ++count_;
  }

  std::span<const ThemeEntry> ThemeCatalog::entries() const noexcept {
    return std::span{entries_.view()}.first(count_);
  }

  const ThemeEntry* ThemeCatalog::find(std::string_view name) const noexcept {
    const auto entries = this->entries();
    auto found = std::ranges::find(entries, name, [](const ThemeEntry& entry) {
      return entry.name.view();
    });
    if (found != entries.end()) {
      return std::to_address(found);
    }

    const auto preset = presetOf(name);
    if (!preset) {
      return nullptr;
    }

    found = std::ranges::find(entries, *preset, [](const ThemeEntry& entry) {
      return entry.canonical.view();
    });

    return found == entries.end() ? nullptr : std::to_address(found);
  }

  ds::Option<std::size_t> ThemeCatalog::startingWith(std::string_view prefix) const noexcept {
    const auto entries = this->entries();
    const auto found = std::ranges::find_if(entries, [&](const ThemeEntry& entry) {
      return startsWithIgnoringCase(entry.label.view(), prefix);
    });

    return found == entries.end() ? ds::none : ds::Option{static_cast<std::size_t>(found - entries.begin())};
  }

  void themeLabel(std::string_view name, runtime::FixedText<ThemeEntry::name_bytes>& label) {
    const auto* const known = std::ranges::find(preset_labels, name, &std::pair<std::string_view, std::string_view>::first);
    if (known != preset_labels.end()) {
      label.assign(known->second);
      return;
    }

    ds::Array<char, ThemeEntry::name_bytes> text{};
    bool word_start = true;

    for (std::size_t index = 0; index < name.size(); ++index) {
      const auto character = name[index];
      const bool separator = character == '-' || character == '_';

      if (separator) {
        text.atMut(index) = ' ';
      } else {
        text.atMut(index) = word_start ? asciiUpper(character) : character;
      }

      word_start = separator;
    }

    label.assign({text.data(), name.size()});
  }

  bool lightTheme(const ThemeValues& values) noexcept {
    constexpr std::uint32_t red_weight = 2126;
    constexpr std::uint32_t green_weight = 7152;
    constexpr std::uint32_t blue_weight = 722;
    constexpr std::uint32_t half = 255 * 10000 / 2;
    const auto& background = values.terminal.background;

    return (red_weight * background[0]) + (green_weight * background[1]) + (blue_weight * background[2]) > half;
  }

  void ThemeCommand::append(std::string_view argument) {
    if (count_ == maximum_arguments || argument.contains('\0')) {
      throw std::length_error{"The theme picker's command exceeds its capacity"};
    }

    ds::Array<char, argument_bytes> joined{};
    const auto existing = text_.view();
    if (existing.size() + argument.size() + 1 > argument_bytes) {
      throw std::length_error{"The theme picker's command exceeds its capacity"};
    }

    std::ranges::copy(existing, joined.viewMut().begin());
    std::ranges::copy(argument, joined.viewMut().begin() + static_cast<std::ptrdiff_t>(existing.size()));
    text_.assign({joined.data(), existing.size() + argument.size() + 1});
    ++count_;
  }

  void ThemeCommand::clear() {
    text_.assign({});
    count_ = 0;
  }

  bool ThemeCommand::empty() const noexcept {
    return count_ == 0;
  }

  std::uint32_t ThemeCommand::timeoutMs() const noexcept {
    return timeout_ms_;
  }

  void ThemeCommand::setTimeoutMs(std::uint32_t timeout_ms) noexcept {
    timeout_ms_ = timeout_ms;
  }

  ds::Option<ThemeChoice> ThemeChoice::parse(std::string_view text) {
    const auto end = text.find('\n');
    if (end == std::string_view::npos || end == 0 || end > ThemeEntry::name_bytes || text.size() != end + fingerprint_digits + 2 || text.back() != '\n') {
      return ds::none;
    }

    const auto name = text.substr(0, end);
    const bool valid_name = std::ranges::all_of(name, [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
    });
    if (!valid_name) {
      return ds::none;
    }

    ThemeChoice choice;

    for (const auto character : text.substr(end + 1, fingerprint_digits)) {
      const auto digit = hexDigit(character);
      if (!digit) {
        return ds::none;
      }

      choice.fingerprint = (choice.fingerprint << digit_bits) | *digit;
    }

    choice.name.assign(name);

    return choice;
  }

  tbc::val_a<std::string_view> ThemeChoice::format(tbc::mut_a<ds::Array<char, file_bytes>> output) const noexcept {
    constexpr std::string_view hex = "0123456789abcdef";
    constexpr std::uint64_t digit_mask = (1U << digit_bits) - 1;
    const auto chosen = name.view();
    auto cursor = std::ranges::copy(chosen, output.viewMut().begin()).out;

    *cursor++ = '\n';
    for (std::size_t index = 0; index < fingerprint_digits; ++index) {
      const auto shift = (fingerprint_digits - 1 - index) * digit_bits;

      *cursor++ = hex[(fingerprint >> shift) & digit_mask];
    }

    *cursor = '\n';

    return std::string_view{output.data(), chosen.size() + fingerprint_digits + 2};
  }

  std::uint64_t themeFingerprint(const ThemeSelection& selection) noexcept {
    Fingerprint fingerprint;

    fingerprint.theme(selection.base);
    fingerprint.variant(selection.light);
    fingerprint.variant(selection.dark);

    return fingerprint.value();
  }

}
