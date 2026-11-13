#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

#include <optional>
#include <QByteArray>
#include <QKeyEvent>
#include "key_adapter.hpp"

import telar.gui.prompt.editor;

namespace telar::gui::qt {

// A key for telar's command editor, from the same normalized key the terminal would encode.
// `text` keeps the typed characters alive while the editor reads them. Keys the editor has no
// use for, and every combination with Command (super), stay with the terminal and bindings.
inline std::optional<prompt::KeyPress> promptKey(const QKeyEvent &event, QByteArray &text) {
  const auto key = NativeKeyAdapter::terminalKey(event);
  if (!key || key->has(KeyChord::Modifier::super)) {
    return std::nullopt;
  }

  prompt::KeyPress result{.modifiers = {.control = key->has(KeyChord::Modifier::control), .alt = key->has(KeyChord::Modifier::alt), .shift = key->has(KeyChord::Modifier::shift)}};
  switch (key->code) {
  case KeyChord::Key::character:
    result.key = prompt::Key::character;
    result.character = key->codepoint;
    // Option changes the text on macOS; the editor binds the key under it.
    if (result.modifiers.alt && event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde) {
      result.character = static_cast<char32_t>(event.key() >= Qt::Key_A && event.key() <= Qt::Key_Z ? event.key() - Qt::Key_A + 'a' : event.key());
    } else if (!result.modifiers.control) {
      text = event.text().toUtf8();
      result.text = {text.constData(), static_cast<std::size_t>(text.size())};
    }
    return result;
  case KeyChord::Key::up:
    result.key = prompt::Key::up;
    return result;
  case KeyChord::Key::down:
    result.key = prompt::Key::down;
    return result;
  case KeyChord::Key::left:
    result.key = prompt::Key::left;
    return result;
  case KeyChord::Key::right:
    result.key = prompt::Key::right;
    return result;
  case KeyChord::Key::home:
    result.key = prompt::Key::home;
    return result;
  case KeyChord::Key::end:
    result.key = prompt::Key::end;
    return result;
  case KeyChord::Key::erase:
    result.key = prompt::Key::delete_forward;
    return result;
  case KeyChord::Key::enter:
    result.key = prompt::Key::enter;
    return result;
  case KeyChord::Key::escape:
    result.key = prompt::Key::escape;
    return result;
  case KeyChord::Key::backspace:
    result.key = prompt::Key::backspace;
    return result;
  case KeyChord::Key::tab:
    result.key = prompt::Key::tab;
    return result;
  case KeyChord::Key::back_tab:
    result.key = prompt::Key::backtab;
    return result;
  default:
    return std::nullopt;
  }
}

}
