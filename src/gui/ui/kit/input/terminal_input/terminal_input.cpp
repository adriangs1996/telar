module telar.gui.ui.kit.input.terminal_input;

import std;
import telar.base.ds;

namespace telar::gui::qt {
  namespace {
    constexpr char escape = '\x1b';
    constexpr char delete_character = '\x7f';
    constexpr unsigned control_mask = 0x1fU;

    // The numbers of the keys sent as `CSI number ~`.
    constexpr int insert_code = 2;
    constexpr int delete_code = 3;
    constexpr int page_up_code = 5;
    constexpr int page_down_code = 6;

    enum class KeyboardFlag : std::uint8_t {
      disambiguate = 1,
      report_events = 2,
      alternate_keys = 4,
      all_keys = 8,
      associated_text = 16,
    };

    enum class KeyEventType : std::uint8_t {
      press = 1,
      repeat = 2,
      release = 3,
    };

    enum class Modifier : std::uint8_t {
      shift = 1,
      alt = 2,
      control = 4,
      super = 8,
    };

    // A key's number and final byte in the CSI forms, and its SS3 final byte when it has one.
    struct KeyCode {
      int code = 0;
      char suffix = 'u';
      char application = 0;
    };

    bool enabled(std::uint8_t flags, KeyboardFlag flag) {
      return (static_cast<unsigned>(flags) & static_cast<unsigned>(flag)) != 0U;
    }

    char controlCharacter(int code) {
      return static_cast<char>(static_cast<unsigned>(code) & control_mask);
    }

    bool commandModifier(Qt::KeyboardModifiers modifiers) {
#ifdef Q_OS_MACOS
      return modifiers.testFlag(Qt::ControlModifier);
#else
      return modifiers.testFlag(Qt::MetaModifier);
#endif
    }

    int modifierCode(Qt::KeyboardModifiers modifiers) {
      return 1 + (modifiers.testFlag(Qt::ShiftModifier) ? std::to_underlying(Modifier::shift) : 0) +
             (modifiers.testFlag(Qt::AltModifier) ? std::to_underlying(Modifier::alt) : 0) +
             (controlModifier(modifiers) ? std::to_underlying(Modifier::control) : 0) +
             (commandModifier(modifiers) ? std::to_underlying(Modifier::super) : 0);
    }

    int eventType(const QKeyEvent& event, bool released) {
      if (released) {
        return std::to_underlying(KeyEventType::release);
      }

      return std::to_underlying(event.isAutoRepeat() ? KeyEventType::repeat : KeyEventType::press);
    }

    QByteArray csi(int code, int modifiers, char suffix) {
      return "\x1b[" + QByteArray::number(code) +
             (modifiers > 1 ? ";" + QByteArray::number(modifiers) : QByteArray{}) + suffix;
    }

    constexpr KeyCode cursorKey(char final) {
      return {.code = 1, .suffix = final, .application = final};
    }

    constexpr KeyCode tildeKey(int code) {
      return {.code = code, .suffix = '~'};
    }

    // Function keys, printable keys and the text of any other key.
    KeyCode characterKey(const QKeyEvent& event, std::uint8_t flags) {
      constexpr ds::Array function_codes{11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24};

      if (event.key() >= Qt::Key_F1 && event.key() <= Qt::Key_F12) {
        const auto index = event.key() - Qt::Key_F1;
        if (index < 4 && (flags == 0 || event.key() != Qt::Key_F3)) {
          return cursorKey(static_cast<char>('P' + index));
        }

        return tildeKey(function_codes[static_cast<std::size_t>(index)]);
      }

      if (event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde) {
        const bool letter = event.key() >= Qt::Key_A && event.key() <= Qt::Key_Z;

        return {.code = letter ? event.key() + ('a' - 'A') : event.key()};
      }

      const auto points = event.text().toUcs4();
      if (points.size() == 1) {
        return {.code = static_cast<int>(points.front())};
      }

      return {};
    }

    KeyCode keyCode(const QKeyEvent& event, std::uint8_t flags) {
      switch (event.key()) {
      case Qt::Key_Escape:
        return {.code = escape};
      case Qt::Key_Return:
      case Qt::Key_Enter:
        return {.code = '\r'};
      case Qt::Key_Tab:
      case Qt::Key_Backtab:
        return {.code = '\t'};
      case Qt::Key_Backspace:
        return {.code = delete_character};
      case Qt::Key_Up:
        return cursorKey('A');
      case Qt::Key_Down:
        return cursorKey('B');
      case Qt::Key_Right:
        return cursorKey('C');
      case Qt::Key_Left:
        return cursorKey('D');
      case Qt::Key_Home:
        return cursorKey('H');
      case Qt::Key_End:
        return cursorKey('F');
      case Qt::Key_Insert:
        return tildeKey(insert_code);
      case Qt::Key_Delete:
        return tildeKey(delete_code);
      case Qt::Key_PageUp:
        return tildeKey(page_up_code);
      case Qt::Key_PageDown:
        return tildeKey(page_down_code);
      default:
        return characterKey(event, flags);
      }
    }

    // The key in the kitty keyboard protocol's `CSI code ; modifiers suffix` form.
    QByteArray kittyKey(const QKeyEvent& event, std::uint8_t flags, const KeyCode& key, int modifiers, bool released) {
      QByteArray result = "\x1b[" + QByteArray::number(key.code);

      if (enabled(flags, KeyboardFlag::alternate_keys) && key.suffix == 'u' &&
          event.modifiers().testFlag(Qt::ShiftModifier)) {
        const auto points = event.text().toUcs4();
        if (points.size() == 1 && points.front() != static_cast<char32_t>(key.code)) {
          result += ':' + QByteArray::number(static_cast<uint>(points.front()));
        }
      }

      result += ';' + QByteArray::number(modifiers);
      if (enabled(flags, KeyboardFlag::report_events)) {
        result += ':' + QByteArray::number(eventType(event, released));
      }

      if (!released && enabled(flags, KeyboardFlag::associated_text) && !controlModifier(event.modifiers()) &&
          !commandModifier(event.modifiers()) && !event.text().isEmpty()) {
        bool first = true;

        for (const auto point : event.text().toUcs4()) {
          result += first ? ';' : ':';
          result += QByteArray::number(static_cast<uint>(point));
          first = false;
        }
      }

      return result + key.suffix;
    }

    // A key's own byte, the C0 byte control folds it into, or else its text.
    QByteArray legacyText(const QKeyEvent& event, int code) {
      const bool control = controlModifier(event.modifiers());
      QByteArray result;

      if (code == escape || code == '\r' || code == '\t' || code == delete_character) {
        result += static_cast<char>(code);
      } else if (control && ((code >= 'a' && code <= 'z') || (code >= '@' && code <= '_'))) {
        result += controlCharacter(code);
      } else if (control && (code == ' ' || code == '2')) {
        result += '\0';
      } else if (control && code >= '3' && code <= '7') {
        result += static_cast<char>(escape + code - '3');
      } else if (control && (code == '8' || code == '?')) {
        result += delete_character;
      } else if (control && code == '/') {
        result += static_cast<char>(control_mask);
      } else if (control && code == '~') {
        result += controlCharacter('^');
      } else {
        result = event.text().toUtf8();
      }

      return result;
    }

    QByteArray legacyKey(const QKeyEvent& event, const telar::InputModes& modes, const KeyCode& key, int modifiers) {
      if (key.suffix != 'u') {
        if ((key.application != 0) && modifiers == 1) {
          return QByteArray(modes.cursor_keys || key.application >= 'P' ? "\x1bO" : "\x1b[") +
                 key.application;
        }

        return csi(key.code, modifiers, key.suffix);
      }

      if (event.key() == Qt::Key_Backtab ||
          (event.key() == Qt::Key_Tab && event.modifiers().testFlag(Qt::ShiftModifier))) {
        return "\x1b[Z";
      }

      if (commandModifier(event.modifiers())) {
        return {};
      }

      if (modes.modify_other_keys_2 && modifiers > 1 && (key.code != 0)) {
        return "\x1b[27;" + QByteArray::number(modifiers) + ';' + QByteArray::number(key.code) + '~';
      }

      auto result = legacyText(event, key.code);

      if (event.modifiers().testFlag(Qt::AltModifier) && !result.isEmpty()) {
        result.prepend(escape);
      }

      return result;
    }
  }

  bool controlModifier(Qt::KeyboardModifiers modifiers) {
#ifdef Q_OS_MACOS
    return modifiers.testFlag(Qt::MetaModifier);
#else
    return modifiers.testFlag(Qt::ControlModifier);
#endif
  }

  QByteArray terminalKey(const QKeyEvent& event, const telar::InputModes& modes) {
    const auto flags = modes.kitty_keyboard_flags;
    const bool released = event.type() == QEvent::KeyRelease;
    if (released && (!enabled(flags, KeyboardFlag::report_events) || event.isAutoRepeat())) {
      return {};
    }

    const int modifiers = modifierCode(event.modifiers());
    const auto key = keyCode(event, flags);

    const bool recovery_key = key.code == '\r' || key.code == '\t' || key.code == delete_character;
    if (released && recovery_key && !enabled(flags, KeyboardFlag::all_keys)) {
      return {};
    }

    const bool non_text_modifier = controlModifier(event.modifiers()) ||
                                   event.modifiers().testFlag(Qt::AltModifier) ||
                                   commandModifier(event.modifiers());
    const bool extended =
        flags != 0 && (enabled(flags, KeyboardFlag::all_keys) || key.suffix != 'u' ||
                          (enabled(flags, KeyboardFlag::disambiguate) && (non_text_modifier || key.code == escape)));
    if (extended && key.code != 0) {
      return kittyKey(event, flags, key, modifiers, released);
    }

    if (released) {
      return {};
    }

    return legacyKey(event, modes, key, modifiers);
  }

}
