module telar.gui.presentation.history_inspection;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;

namespace telar::gui {

  void ModeHints::append(tbc::view<ModeHint, tbc::lt::a> hint) noexcept {
    if (count_ < hints_.size()) {
      hints_[count_++] = hint;
    }
  }

  tbc::view<std::span<const ModeHint>, tbc::lt::a> ModeHints::items() const noexcept {
    return std::span{hints_}.first(count_);
  }

  auto ModeKeyLabel::format(KeyChord key) -> Text {
    Text result;

    if (key.has(KeyChord::Modifier::control)) {
      result.append("Ctrl+");
    }

    if (key.has(KeyChord::Modifier::alt)) {
      result.append("Alt+");
    }

    if (key.has(KeyChord::Modifier::shift)) {
      result.append("Shift+");
    }

    if (key.key == KeyChord::Key::character) {
      const auto text = KeyCharacter::text(key.character);

      static_cast<void>(Utf8Scalar::decode(text.view()));
      result.append(text.view());
    } else {
      result.append(name(key.key));
    }

    return result;
  }

  std::string_view ModeKeyLabel::name(KeyChord::Key key) noexcept {
    switch (key) {
    case KeyChord::Key::up:
      return "Up";
    case KeyChord::Key::down:
      return "Down";
    case KeyChord::Key::left:
      return "Left";
    case KeyChord::Key::right:
      return "Right";
    case KeyChord::Key::home:
      return "Home";
    case KeyChord::Key::end:
      return "End";
    case KeyChord::Key::erase:
      return "Del";
    case KeyChord::Key::page_up:
      return "PgUp";
    case KeyChord::Key::page_down:
      return "PgDn";
    case KeyChord::Key::enter:
      return "Enter";
    case KeyChord::Key::escape:
      return "Esc";
    case KeyChord::Key::backspace:
      return "Backspace";
    case KeyChord::Key::tab:
      return "Tab";
    case KeyChord::Key::back_tab:
      return "BackTab";
    case KeyChord::Key::character:
      return {};
    }

    return {};
  }

  ModeBarLabels ModeBarLabels::resolve(StatusMode mode, const ModeHints& hints) {
    ModeBarLabels result;

    switch (mode) {
    case StatusMode::normal:
      return result;
    case StatusMode::copy:
      result.title_ = "COPY";
      for (const auto& [key, word] : copy_hints) {
        result.append(key, word);
      }

      return result;
    case StatusMode::prefix:
      result.title_ = "PREFIX";
      result.append(cancel_key, cancel_word);
      for (const auto& item : hints.items()) {
        result.append(ModeKeyLabel::format(item.key).view(), item.label);
      }

      return result;
    }

    return result;
  }

  std::string_view ModeBarLabels::title() const noexcept {
    return title_;
  }

  std::span<const ModeBarHint> ModeBarLabels::hints() const noexcept {
    return std::span{hints_}.first(count_);
  }

  void ModeBarLabels::append(std::string_view key, std::string_view word) {
    auto& hint = hints_[count_++];

    hint.key.append(key);
    hint.word.append(word);
  }

  WorkspaceMark WorkspaceMark::resolve(std::string_view name) {
    WorkspaceMark mark;

    mark.hue = hues[hash(name) % hues.size()];
    if (name.empty()) {
      return mark;
    }

    const auto leading = std::countl_one(static_cast<std::uint8_t>(name.front()));
    const auto length = leading == 0 ? std::size_t{1} : static_cast<std::size_t>(leading);
    if (leading == 1 || length > mark.initial.bytes.size() || length > name.size()) {
      return mark;
    }

    try {
      const auto scalar = Utf8Scalar::decode(name.substr(0, length));
      const auto upper = scalar >= 'a' && scalar <= 'z' ? scalar - ('a' - 'A') : scalar;

      mark.initial = Utf8Scalar::encode(upper);
    } catch (const std::invalid_argument&) {
      return mark;
    }

    return mark;
  }

  std::uint32_t WorkspaceMark::hash(std::string_view name) noexcept {
    constexpr std::uint32_t offset_basis = 2166136261U;
    constexpr std::uint32_t prime = 16777619U;
    auto value = offset_basis;

    for (const auto byte : name) {
      value = (value ^ static_cast<unsigned char>(byte)) * prime;
    }

    return value;
  }

}
