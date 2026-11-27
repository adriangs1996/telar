#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

#include "ui/kit/input/key_adapter.hpp"
#include <QByteArray>
#include <QKeyEvent>
#include <optional>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // A key for telar's command editor, from the same normalized key the terminal would encode.
  // `text` keeps the typed characters alive while the editor reads them. Keys the editor has no
  // use for, and every combination with Command (super), stay with the terminal and bindings.
  // `option_as_alt` makes macOS's Option Meta, as for the terminal.
  inline tbc::val_a<ds::Option<application::prompt::KeyPress>> promptKey(const QKeyEvent& event, tbc::mut_a<QByteArray> text, bool option_as_alt) {
    const auto key = NativeKeyAdapter::terminalKey(event, option_as_alt);
    if (!key) {
      return ds::none;
    }

    // macOS's Command keys for text, as the keys the editor knows: Left and Right go to the
    // line's ends, Shift selecting, Backspace erases to its start and Z undoes.
    if (key->has(KeyChord::Modifier::super)) {
      const bool shift = key->has(KeyChord::Modifier::shift);

      if (key->has(KeyChord::Modifier::control) || key->has(KeyChord::Modifier::alt)) {
        return ds::none;
      }

      if (key->code == KeyChord::Key::left || key->code == KeyChord::Key::right) {
        return application::prompt::KeyPress{.key = key->code == KeyChord::Key::left ? application::prompt::Key::home : application::prompt::Key::end, .modifiers = {.shift = shift}};
      }

      if (key->code == KeyChord::Key::backspace) {
        return application::prompt::KeyPress{.key = application::prompt::Key::character, .character = U'u', .modifiers = {.control = true}};
      }

      if (key->code == KeyChord::Key::character && key->codepoint == 'z' && !shift) {
        return application::prompt::KeyPress{.key = application::prompt::Key::character, .character = U'_', .modifiers = {.control = true}};
      }

      return ds::none;
    }

    application::prompt::KeyPress result{.modifiers = {.control = key->has(KeyChord::Modifier::control), .alt = key->has(KeyChord::Modifier::alt), .shift = key->has(KeyChord::Modifier::shift)}};

    switch (key->code) {
    case KeyChord::Key::character:
      result.key = application::prompt::Key::character;
      result.character = key->codepoint;
      // Alt that stays is Meta: the editor binds the key under it.
      if (result.modifiers.alt && event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde) {
        result.character = static_cast<char32_t>(event.key() >= Qt::Key_A && event.key() <= Qt::Key_Z ? event.key() - Qt::Key_A + 'a' : event.key());
      } else if (!result.modifiers.control) {
        text = event.text().toUtf8();
        result.text = {text.constData(), static_cast<std::size_t>(text.size())};
      }

      return result;
    case KeyChord::Key::up:
      result.key = application::prompt::Key::up;
      return result;
    case KeyChord::Key::down:
      result.key = application::prompt::Key::down;
      return result;
    case KeyChord::Key::left:
      result.key = application::prompt::Key::left;
      return result;
    case KeyChord::Key::right:
      result.key = application::prompt::Key::right;
      return result;
    case KeyChord::Key::home:
      result.key = application::prompt::Key::home;
      return result;
    case KeyChord::Key::end:
      result.key = application::prompt::Key::end;
      return result;
    case KeyChord::Key::erase:
      result.key = application::prompt::Key::delete_forward;
      return result;
    case KeyChord::Key::enter:
      result.key = application::prompt::Key::enter;
      return result;
    case KeyChord::Key::escape:
      result.key = application::prompt::Key::escape;
      return result;
    case KeyChord::Key::backspace:
      result.key = application::prompt::Key::backspace;
      return result;
    case KeyChord::Key::tab:
      result.key = application::prompt::Key::tab;
      return result;
    case KeyChord::Key::back_tab:
      result.key = application::prompt::Key::backtab;
      return result;
    case KeyChord::Key::page_up:
    case KeyChord::Key::page_down:
      return ds::none;
    }

    // A key outside the enum stays with the terminal and bindings.
    return ds::none;
  }

}
