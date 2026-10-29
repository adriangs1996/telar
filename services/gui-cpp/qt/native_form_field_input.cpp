#include "native_form_field.hpp"
#include "text/grapheme_cursor.hpp"
#include <QFont>
#include <QGuiApplication>
#include <QInputMethod>
#include <QString>
#include <QStringLiteral>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qevent.h>
#include <QtQuick/qquickitem.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui::qt {

bool NativeFormField::editKey(const QKeyEvent &event) {
  if (event.modifiers().testFlag(Qt::ControlModifier) || event.modifiers().testFlag(Qt::MetaModifier)) {
    switch (event.key()) {
    case Qt::Key_A:
      if (!event.isAutoRepeat()) {
        selectAll();
      }
      return true;
    case Qt::Key_C:
      if (!event.isAutoRepeat()) {
        copy();
      }
      return true;
    case Qt::Key_X:
      if (!event.isAutoRepeat()) {
        cut();
      }
      return true;
    case Qt::Key_V:
      if (!event.isAutoRepeat()) {
        paste();
      }
      return true;
    default:
      break;
    }
  }

  const auto extend = event.modifiers().testFlag(Qt::ShiftModifier);
  switch (event.key()) {
  case Qt::Key_Left:
    cancelComposition();
    editor_.moveLeft(extend);
    break;
  case Qt::Key_Right:
    cancelComposition();
    editor_.moveRight(extend);
    break;
  case Qt::Key_Home:
    cancelComposition();
    editor_.home(extend);
    break;
  case Qt::Key_End:
    cancelComposition();
    editor_.end(extend);
    break;
  case Qt::Key_Backspace:
    cancelComposition();
    editor_.backspace();
    break;
  case Qt::Key_Delete:
    cancelComposition();
    editor_.deleteForward();
    break;
  default:
    return false;
  }

  publish(true);

  return true;
}

void NativeFormField::keyPressEvent(QKeyEvent *event) {
  if (editKey(*event)) {
    event->accept();

    return;
  }

  if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
    emit accepted();
    event->accept();

    return;
  }

  const auto shortcut = event->modifiers().testFlag(Qt::MetaModifier) || (event->modifiers().testFlag(Qt::ControlModifier) && !event->modifiers().testFlag(Qt::AltModifier));
  if (shortcut || event->text().isEmpty()) {
    event->ignore();

    return;
  }

  insertText(event->text());
  publish(true);
  event->accept();
}

void NativeFormField::commitInput(const QInputMethodEvent &event) {
  if (event.commitString().isEmpty() && event.replacementLength() == 0) {
    return;
  }

  if (!composition_.isEmpty()) {
    editor_.selectRange(composition_first_, composition_last_);
  }

  if (event.replacementStart() != 0 || event.replacementLength() != 0) {
    editor_.insert({});
    const auto committed = QString::fromUtf8(editor_.text().data(), static_cast<qsizetype>(editor_.text().size()));
    const auto first = cursorPosition() + event.replacementStart();
    editor_.selectRange(bytePosition(committed, first), bytePosition(committed, first + event.replacementLength()));
  }

  insertText(event.commitString());
  clearComposition();
}

void NativeFormField::updateComposition(const QInputMethodEvent &event) {
  const auto committed = QString::fromUtf8(editor_.text().data(), static_cast<qsizetype>(editor_.text().size()));
  for (const auto &attribute : event.attributes()) {
    if (attribute.type == QInputMethodEvent::Selection) {
      editor_.selectRange(bytePosition(committed, attribute.start), bytePosition(committed, attribute.start + attribute.length));
    }
  }

  if (event.preeditString().isEmpty()) {
    clearComposition();

    return;
  }

  const auto bytes = event.preeditString().toUtf8();
  if (bytes.size() > static_cast<qsizetype>(composition_capacity)) {
    return;
  }

  if (composition_.isEmpty()) {
    composition_first_ = std::min(editor_.anchor(), editor_.head());
    composition_last_ = std::max(editor_.anchor(), editor_.head());
  }
  composition_ = bytes;
  composition_anchor_ = static_cast<std::size_t>(bytes.size());
  composition_head_ = composition_anchor_;
  for (const auto &attribute : event.attributes()) {
    if (attribute.type == QInputMethodEvent::Cursor) {
      composition_head_ = bytePosition(event.preeditString(), attribute.start);
      composition_anchor_ = composition_head_;
    }
  }
}

void NativeFormField::inputMethodEvent(QInputMethodEvent *event) {
  if (discarding_composition_) {
    event->accept();

    return;
  }

  commitInput(*event);
  updateComposition(*event);
  publish(true);
  event->accept();
}

QVariant NativeFormField::inputMethodQuery(Qt::InputMethodQuery query) const {
  switch (query) {
  case Qt::ImEnabled:
    return isEnabled() && isVisible();
  case Qt::ImCursorRectangle:
  case Qt::ImAnchorRectangle:
    return layout_.value(QStringLiteral("caret"));
  case Qt::ImCursorPosition:
  case Qt::ImAbsolutePosition:
    return input_context_.cursor;
  case Qt::ImAnchorPosition:
    return input_context_.anchor;
  case Qt::ImSurroundingText:
    return input_context_.text;
  case Qt::ImCurrentSelection:
    return input_context_.selectedText();
  case Qt::ImTextBeforeCursor:
    return input_context_.beforeCursor();
  case Qt::ImTextAfterCursor:
    return input_context_.afterCursor();
  case Qt::ImMaximumTextLength:
    return maximum_bytes_;
  case Qt::ImFont: {
    QFont font{typography_.value(QStringLiteral("primaryFamily")).toString()};
    font.setStyleName(typography_.value(QStringLiteral("primaryStyle")).toString());
    font.setPixelSize(static_cast<int>(std::max(qreal{1}, std::round(typography_.value(QStringLiteral("body"), 1).toDouble()))));

    return font;
  }
  case Qt::ImHints:
    return static_cast<int>(Qt::ImhNoPredictiveText | Qt::ImhNoAutoUppercase);
  default:
    return QQuickItem::inputMethodQuery(query);
  }
}

std::size_t NativeFormField::pointerPosition(qreal x) const {
  const auto target = std::max(qreal{0}, ((x * density_) - geometry_.content.x) / geometry_.cell_width);
  auto display = editor_;
  const auto visible = display.view(geometry_.columns);
  const auto first = display.scroll();
  GraphemeCursor cursor{visible.text};
  std::uint32_t columns = 0;
  std::size_t previous = first;
  while (cursor.next()) {
    const auto next = columns + cursor.columns();
    if (target < static_cast<qreal>(columns) + (static_cast<qreal>(cursor.columns()) / 2)) {
      return previous;
    }

    columns = next;
    previous = first + cursor.position();
  }

  return previous;
}

void NativeFormField::mousePressEvent(QMouseEvent *event) {
  if (event->button() != Qt::LeftButton) {
    event->ignore();

    return;
  }

  cancelComposition();
  forceActiveFocus(Qt::MouseFocusReason);
  const auto position = pointerPosition(event->position().x());
  pressed_anchor_ = event->modifiers().testFlag(Qt::ShiftModifier) ? editor_.anchor() : position;
  editor_.selectRange(pressed_anchor_, position);
  dragging_ = true;
  setKeepMouseGrab(true);
  publish(false);
  event->accept();
}

void NativeFormField::mouseMoveEvent(QMouseEvent *event) {
  if (dragging_) {
    editor_.selectRange(pressed_anchor_, pointerPosition(event->position().x()));
    publish(false);
    event->accept();
  }
}

void NativeFormField::mouseReleaseEvent(QMouseEvent *event) {
  if (dragging_ && event->button() == Qt::LeftButton) {
    editor_.selectRange(pressed_anchor_, pointerPosition(event->position().x()));
    dragging_ = false;
    setKeepMouseGrab(false);
    publish(false);
    event->accept();
  }
}

void NativeFormField::mouseDoubleClickEvent(QMouseEvent *event) {
  mousePressEvent(event);
}

void NativeFormField::mouseUngrabEvent() {
  dragging_ = false;
  QQuickItem::mouseUngrabEvent();
}

void NativeFormField::focusOutEvent(QFocusEvent *event) {
  dragging_ = false;
  cancelComposition();
  invalidateLayout();
  QQuickItem::focusOutEvent(event);
}

}
