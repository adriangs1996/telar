module telar.gui.features.status_bar;

import std;
import telar.tbc;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;

namespace telar::gui::features::status_bar {

  void ModeHints::append(tbc::val_a<ModeHint> hint) noexcept {
    if (count_ < hints_.size()) {
      hints_.atMut(count_++) = hint;
    }
  }

  tbc::val_a<std::span<const ModeHint>> ModeHints::items() const noexcept {
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
      for (const auto& hint : copy_hints) {
        result.append(hint);
      }

      return result;
    case StatusMode::prefix:
      result.title_ = "PREFIX";
      result.append({.key = cancel_key, .word = cancel_word});
      for (const auto& item : hints.items()) {
        result.append({.key = ModeKeyLabel::format(item.key).view(), .word = item.label});
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

  void ModeBarLabels::append(KeyHint hint) {
    auto& stored = hints_.atMut(count_++);

    stored.key.append(hint.key);
    stored.word.append(hint.word);
  }

}
