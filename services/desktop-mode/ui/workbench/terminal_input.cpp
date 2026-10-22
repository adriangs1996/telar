#include "terminal_input.hpp"
#include "../../trace.hpp"
#include <array>

namespace workbench {
  namespace {
    constexpr char escape = '\x1b';
    constexpr char delete_character = '\x7f';
    constexpr int control_mask = 0x1f;

    enum KeyboardFlag {
      disambiguate = 1,
      report_events = 2,
      alternate_keys = 4,
      all_keys = 8,
      associated_text = 16
    };

    enum KeyEventType {
      press = 1,
      repeat = 2,
      release = 3
    };

    enum Modifier {
      shift = 1,
      alt = 2,
      control = 4,
      super = 8
    };

    bool commandModifier(Qt::KeyboardModifiers modifiers) {
#ifdef Q_OS_MACOS
      return modifiers.testFlag(Qt::ControlModifier);
#else
      return modifiers.testFlag(Qt::MetaModifier);
#endif
    }

    int modifierCode(Qt::KeyboardModifiers modifiers) {
      return 1 + (modifiers.testFlag(Qt::ShiftModifier) ? shift : 0) +
             (modifiers.testFlag(Qt::AltModifier) ? alt : 0) +
             (controlModifier(modifiers) ? control : 0) + (commandModifier(modifiers) ? super : 0);
    }

    QByteArray csi(int code, int modifiers, char suffix) {
      return "\x1b[" + QByteArray::number(code) +
             (modifiers > 1 ? ";" + QByteArray::number(modifiers) : QByteArray{}) + suffix;
    }
  } // namespace

  bool controlModifier(Qt::KeyboardModifiers modifiers) {
#ifdef Q_OS_MACOS
    return modifiers.testFlag(Qt::MetaModifier);
#else
    return modifiers.testFlag(Qt::ControlModifier);
#endif
  }

  QByteArray terminalKey(const QKeyEvent &event, const telar::InputModes &modes) {
    TELAR_TRACE("terminal.input.key");
    const auto flags = modes.kitty_keyboard_flags;
    const bool released = event.type() == QEvent::KeyRelease;
    if (released && (!(flags & report_events) || event.isAutoRepeat())) {
      return {};
    }

    const int modifiers = modifierCode(event.modifiers());
    int code = 0;
    char suffix = 'u';
    char application = 0;
    switch (event.key()) {
    case Qt::Key_Escape:
      code = escape;
      break;
    case Qt::Key_Return:
    case Qt::Key_Enter:
      code = '\r';
      break;
    case Qt::Key_Tab:
    case Qt::Key_Backtab:
      code = '\t';
      break;
    case Qt::Key_Backspace:
      code = delete_character;
      break;
    case Qt::Key_Up:
      code = 1;
      suffix = application = 'A';
      break;
    case Qt::Key_Down:
      code = 1;
      suffix = application = 'B';
      break;
    case Qt::Key_Right:
      code = 1;
      suffix = application = 'C';
      break;
    case Qt::Key_Left:
      code = 1;
      suffix = application = 'D';
      break;
    case Qt::Key_Home:
      code = 1;
      suffix = application = 'H';
      break;
    case Qt::Key_End:
      code = 1;
      suffix = application = 'F';
      break;
    case Qt::Key_Insert:
      code = 2;
      suffix = '~';
      break;
    case Qt::Key_Delete:
      code = 3;
      suffix = '~';
      break;
    case Qt::Key_PageUp:
      code = 5;
      suffix = '~';
      break;
    case Qt::Key_PageDown:
      code = 6;
      suffix = '~';
      break;
    default: {
      constexpr std::array function_codes{11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24};
      if (event.key() >= Qt::Key_F1 && event.key() <= Qt::Key_F12) {
        const auto index = event.key() - Qt::Key_F1;
        code = function_codes[index];
        suffix = '~';
        if (index < 4 && !(flags && event.key() == Qt::Key_F3)) {
          code = 1;
          suffix = application = static_cast<char>('P' + index);
        }
      } else if (event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde) {
        code = event.key() >= Qt::Key_A && event.key() <= Qt::Key_Z ? event.key() + ('a' - 'A')
                                                                    : event.key();
      } else {
        const auto points = event.text().toUcs4();
        if (points.size() == 1) {
          code = static_cast<int>(points.front());
        }
      }

      break;
    }
    }

    const bool recovery_key = code == '\r' || code == '\t' || code == delete_character;
    if (released && recovery_key && !(flags & all_keys)) {
      return {};
    }

    const bool non_text_modifier = controlModifier(event.modifiers()) ||
                                   event.modifiers().testFlag(Qt::AltModifier) ||
                                   commandModifier(event.modifiers());
    const bool extended =
        flags && ((flags & all_keys) || suffix != 'u' ||
                  ((flags & disambiguate) && (non_text_modifier || code == escape)));
    if (extended && code) {
      QByteArray result = "\x1b[" + QByteArray::number(code);
      if ((flags & alternate_keys) && suffix == 'u' &&
          event.modifiers().testFlag(Qt::ShiftModifier)) {
        const auto points = event.text().toUcs4();
        if (points.size() == 1 && points.front() != static_cast<char32_t>(code)) {
          result += ':' + QByteArray::number(static_cast<uint>(points.front()));
        }
      }

      result += ';' + QByteArray::number(modifiers);
      if (flags & report_events) {
        result += ':' + QByteArray::number(released               ? release
                                           : event.isAutoRepeat() ? repeat
                                                                  : press);
      }

      if (!released && (flags & associated_text) && !controlModifier(event.modifiers()) &&
          !commandModifier(event.modifiers()) && !event.text().isEmpty()) {
        bool first = true;
        for (auto point : event.text().toUcs4()) {
          result += first ? ';' : ':';
          result += QByteArray::number(static_cast<uint>(point));
          first = false;
        }
      }

      return result + suffix;
    }

    if (released) {
      return {};
    }

    if (suffix != 'u') {
      if (application && modifiers == 1) {
        return QByteArray(modes.cursor_keys || application >= 'P' ? "\x1bO" : "\x1b[") +
               application;
      }

      return csi(code, modifiers, suffix);
    }

    if (event.key() == Qt::Key_Backtab ||
        (event.key() == Qt::Key_Tab && event.modifiers().testFlag(Qt::ShiftModifier))) {
      return "\x1b[Z";
    }

    if (commandModifier(event.modifiers())) {
      return {};
    }

    if (modes.modify_other_keys_2 && modifiers > 1 && code) {
      return "\x1b[27;" + QByteArray::number(modifiers) + ';' + QByteArray::number(code) + '~';
    }

    QByteArray result;
    if (code == escape || code == '\r' || code == '\t' || code == delete_character) {
      result += static_cast<char>(code);
    } else if (controlModifier(event.modifiers()) &&
               ((code >= 'a' && code <= 'z') || (code >= '@' && code <= '_'))) {
      result += static_cast<char>(code & control_mask);
    } else if (controlModifier(event.modifiers()) && (code == ' ' || code == '2')) {
      result += '\0';
    } else if (controlModifier(event.modifiers()) && code >= '3' && code <= '7') {
      result += static_cast<char>(escape + code - '3');
    } else if (controlModifier(event.modifiers()) && (code == '8' || code == '?')) {
      result += delete_character;
    } else if (controlModifier(event.modifiers()) && code == '/') {
      result += static_cast<char>(control_mask);
    } else if (controlModifier(event.modifiers()) && code == '~') {
      result += static_cast<char>('^' & control_mask);
    } else {
      result = event.text().toUtf8();
    }

    if (event.modifiers().testFlag(Qt::AltModifier) && !result.isEmpty()) {
      result.prepend(escape);
    }

    return result;
  }

  QByteArray terminalPaste(const QString &text, const telar::InputModes &modes) {
    TELAR_TRACE("terminal.input.paste");
    auto bytes = text.toUtf8();
    bytes.replace("\r\n", "\n");
    bytes.replace('\n', '\r');
    bytes.replace(QByteArray(1, '\0'), QByteArray{});
    // A pasted escape must never terminate the application's bracketed paste early.
    bytes.replace(QByteArray(1, escape), QByteArray{});
    return modes.bracketed_paste ? QByteArray("\x1b[200~") + bytes + "\x1b[201~" : bytes;
  }
} // namespace workbench
