#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/input/key_adapter.hpp"
#include <QKeyEvent>
#include <array>
#include <cstdint>
#include <string_view>
#include <utility>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // A key press as Neovim names it, or none for one that types nothing: a modifier alone.
  // Command and Option are told apart from Control on every platform, as the window's own
  // bindings tell them.
  [[nodiscard]] inline ds::Option<application::nvim::Key> nvimKey(const QKeyEvent& event) {
    using Named = std::pair<int, std::string_view>;
    static constexpr std::array named{
        Named{Qt::Key_Escape, "Esc"},
        Named{Qt::Key_Return, "CR"},
        Named{Qt::Key_Enter, "CR"},
        Named{Qt::Key_Tab, "Tab"},
        Named{Qt::Key_Backtab, "Tab"},
        Named{Qt::Key_Backspace, "BS"},
        Named{Qt::Key_Delete, "Del"},
        Named{Qt::Key_Insert, "Insert"},
        Named{Qt::Key_Home, "Home"},
        Named{Qt::Key_End, "End"},
        Named{Qt::Key_PageUp, "PageUp"},
        Named{Qt::Key_PageDown, "PageDown"},
        Named{Qt::Key_Left, "Left"},
        Named{Qt::Key_Right, "Right"},
        Named{Qt::Key_Up, "Up"},
        Named{Qt::Key_Down, "Down"},
        Named{Qt::Key_F1, "F1"},
        Named{Qt::Key_F2, "F2"},
        Named{Qt::Key_F3, "F3"},
        Named{Qt::Key_F4, "F4"},
        Named{Qt::Key_F5, "F5"},
        Named{Qt::Key_F6, "F6"},
        Named{Qt::Key_F7, "F7"},
        Named{Qt::Key_F8, "F8"},
        Named{Qt::Key_F9, "F9"},
        Named{Qt::Key_F10, "F10"},
        Named{Qt::Key_F11, "F11"},
        Named{Qt::Key_F12, "F12"},
    };

    const auto flags = NativeKeyAdapter::modifiers(event.modifiers());
    const auto held = [flags](KeyChord::Modifier modifier) {
      return (flags & static_cast<unsigned>(modifier)) != 0;
    };

    application::nvim::Key key{.control = held(KeyChord::Modifier::control), .alt = held(KeyChord::Modifier::alt), .shift = held(KeyChord::Modifier::shift), .super = held(KeyChord::Modifier::super)};

    if (const auto* const found = std::ranges::find(named, event.key(), &Named::first); found != named.end()) {
      key.name = found->second;
      key.shift = key.shift || event.key() == Qt::Key_Backtab;
      return key;
    }

    const bool ascii = event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde;

    // Option changes the text a key types; Neovim is told the key it was held with.
    if (key.alt && ascii) {
      auto character = static_cast<std::uint32_t>(event.key());
      if (character >= 'A' && character <= 'Z') {
        character += 'a' - 'A';
      }

      key.codepoint = character;
      return key;
    }

    const auto typed = NativeKeyAdapter::terminalKey(event);
    if (!typed || typed->code != KeyChord::Key::character || typed->codepoint == 0) {
      return ds::none;
    }

    key.codepoint = typed->codepoint;
    // A character typed with shift alone already is the shifted one.
    key.shift = key.shift && (key.control || key.super);
    return key;
  }

}
