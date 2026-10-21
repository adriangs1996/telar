#include "terminal_item.hpp"
#include "terminal_input.hpp"
#include <QClipboard>
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QQuickWindow>
#include <QSGSimpleRectNode>
#include <QSGTextNode>
#include <QTextLayout>
#include <algorithm>
#include <cmath>

namespace workbench {
  namespace {
    constexpr int cursor_interval_ms = 600;
    constexpr int maximum_cells = 130359;
    constexpr int maximum_dimension = 4096;
    constexpr int wheel_unit = 120;
    constexpr int wheel_rows = 3;
    constexpr int minimum_font_size = 6, maximum_font_size = 72, default_font_size = 14;
    constexpr int mouse_release = 3, mouse_motion = 32, mouse_wheel_up = 64, mouse_wheel_down = 65;
    constexpr int mouse_shift = 4, mouse_alt = 8, mouse_control = 16;
    constexpr int legacy_mouse_offset = 32, legacy_mouse_limit = 223;
    constexpr int underline_shift = 8, underline_mask = 7;
    constexpr std::array<const char *, 16> palette{"#45475a",
                                                   "#f38ba8",
                                                   "#a6e3a1",
                                                   "#f9e2af",
                                                   "#89b4fa",
                                                   "#f5c2e7",
                                                   "#94e2d5",
                                                   "#bac2de",
                                                   "#585b70",
                                                   "#f38ba8",
                                                   "#a6e3a1",
                                                   "#f9e2af",
                                                   "#89b4fa",
                                                   "#f5c2e7",
                                                   "#94e2d5",
                                                   "#a6adc8"};

    bool has(const telar::CellStyle &style, telar::CellAttribute flag) {
      return style.flags & static_cast<std::uint16_t>(flag);
    }

    QColor color(const telar::CellColor &value, QColor fallback) {
      if (value.kind == telar::CellColor::Kind::default_color) {
        return fallback;
      }

      if (value.kind == telar::CellColor::Kind::rgb) {
        return {value.channels[0], value.channels[1], value.channels[2]};
      }

      const int index = value.channels[0];
      if (index < static_cast<int>(palette.size())) {
        return QColor(palette[index]);
      }

      constexpr int gray_start = 232, gray_base = 8, gray_step = 10, cube_start = 16, cube_side = 6,
                    cube_base = 55, cube_step = 40;
      if (index >= gray_start) {
        const int gray = gray_base + (index - gray_start) * gray_step;
        return {gray, gray, gray};
      }

      const auto component = [](int value) {
        return value == 0 ? 0 : cube_base + value * cube_step;
      };

      const int cube = index - cube_start;
      return {component(cube / (cube_side * cube_side)),
              component(cube / cube_side % cube_side),
              component(cube % cube_side)};
    }

    struct RowNode final : QSGNode {
      std::uint64_t revision = 0, appearance = 0;
    };

    struct ScreenNode final : QSGNode {
      QSGSimpleRectNode *background = new QSGSimpleRectNode;
      QSGNode *rows = new QSGNode;
      QSGNode *overlay = new QSGNode;
      int columns = 0;

      ScreenNode() {
        appendChildNode(background);
        appendChildNode(rows);
        appendChildNode(overlay);
      }
    };

    void clear(QSGNode *node) {
      while (auto *child = node->firstChild()) {
        node->removeChildNode(child);
        delete child;
      }
    }
  } // namespace

  TerminalItem::TerminalItem(std::shared_ptr<TerminalScreen> screen, QQuickItem *parent)
      : QQuickItem(parent),
        screen_(std::move(screen)),
        font_(QFontDatabase::systemFont(QFontDatabase::FixedFont)) {
    setFlag(ItemHasContents);
    setFlag(ItemAcceptsInputMethod);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton | Qt::RightButton);
    setClip(true);
    setActiveFocusOnTab(true);
    configure({});
    blink_.setInterval(cursor_interval_ms);
    QObject::connect(&blink_, &QTimer::timeout, this, [this] {
      if (isVisible() && hasActiveFocus() && screen_->cursor.blink) {
        cursor_on_ = !cursor_on_;
        update();
      }
    });

    blink_.start();
    QObject::connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow *window) {
      if (window) {
        QObject::connect(window, &QWindow::screenChanged, this, [this] {
          resizeTerminal();
        });

        resizeTerminal();
      }
    });
  }

  void TerminalItem::configure(const QVariantMap &options) {
    font_ = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    if (options.contains("font")) {
      font_.setFamily(options.value("font").toString());
    }

    font_.setPixelSize(std::clamp(options.value("font_size", default_font_size).toInt(),
                                  minimum_font_size,
                                  maximum_font_size));
    font_.setKerning(false);
    font_.setStyleHint(QFont::Monospace);
    fixed_pitch_ = QFontInfo(font_).fixedPitch();
    const QFontMetricsF metrics(font_);
    cell_ = {std::ceil(metrics.horizontalAdvance(QLatin1Char('M'))), std::ceil(metrics.height())};
    ascent_ = metrics.ascent();
    const auto colors = options.value("colors").toMap();
    const QColor fg(colors.value("foreground", "#cdd6f4").toString());
    const QColor bg(colors.value("background", "#1b1723").toString());
    if (fg.isValid()) {
      foreground_ = fg;
    }

    if (bg.isValid()) {
      background_ = bg;
    }

    ++appearance_;
    resizeTerminal();
    update();
  }

  void TerminalItem::refresh() {
    if (end_ >= static_cast<int>(screen_->cells.size())) {
      anchor_ = end_ = -1;
      ++appearance_;
    }

    cursor_on_ = true;
    if (hasActiveFocus()) {
      QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
    }

    update();
  }

  QSizeF TerminalItem::cellSize() const {
    return cell_;
  }

  void TerminalItem::resizeTerminal() {
    if (!resized || width() < cell_.width() || height() < cell_.height()) {
      return;
    }

    const auto columns =
        std::clamp(static_cast<int>(width() / cell_.width()), 1, maximum_dimension);
    const auto rows = std::clamp(static_cast<int>(height() / cell_.height()),
                                 1,
                                 std::min(maximum_dimension, maximum_cells / columns));
    const auto scale = window() ? window()->devicePixelRatio() : 1.0;
    resized({static_cast<std::uint16_t>(columns),
             static_cast<std::uint16_t>(rows),
             static_cast<std::uint16_t>(std::ceil(cell_.width() * scale)),
             static_cast<std::uint16_t>(std::ceil(cell_.height() * scale))});
  }

  void TerminalItem::geometryChange(const QRectF &current, const QRectF &previous) {
    QQuickItem::geometryChange(current, previous);
    resizeTerminal();
  }

  QSGNode *TerminalItem::updatePaintNode(QSGNode *previous, UpdatePaintNodeData *) {
    auto *node = previous ? static_cast<ScreenNode *>(previous) : new ScreenNode;
    node->background->setRect(boundingRect());
    node->background->setColor(background_);
    if (node->rows->childCount() != screen_->rows || node->columns != screen_->columns) {
      clear(node->rows);
      for (int row = 0; row < screen_->rows; ++row) {
        node->rows->appendChildNode(new RowNode);
      }

      node->columns = screen_->columns;
    }

    int row = 0;
    for (auto *child = node->rows->firstChild(); child; child = child->nextSibling(), ++row) {
      auto *line = static_cast<RowNode *>(child);
      if (line->revision == screen_->revisions[row] && line->appearance == appearance_) {
        continue;
      }

      clear(line);
      line->revision = screen_->revisions[row];
      line->appearance = appearance_;
      auto *text = window()->createTextNode();
      text->setRenderType(QSGTextNode::QtRendering);
      // ASCII runs share a layout. Other graphemes retain their exact cell origin,
      // including wide characters and fallback fonts whose metrics differ.
      for (int column = 0; column < screen_->columns;) {
        const auto index = row * screen_->columns + column;
        const auto &cell = screen_->cells[index];
        const bool selected =
            anchor_ >= 0 && index >= std::min(anchor_, end_) && index <= std::max(anchor_, end_);
        auto fg = color(cell.style.foreground, foreground_);
        auto bg = color(cell.style.background, background_);
        if (has(cell.style, telar::CellAttribute::inverse)) {
          std::swap(fg, bg);
        }

        if (selected) {
          bg = selection_;
        }

        if (has(cell.style, telar::CellAttribute::faint)) {
          fg.setAlphaF(0.55);
        }

        if (has(cell.style, telar::CellAttribute::invisible)) {
          fg = bg;
        }

        int count = 1;
        QString string = QString::fromUtf8(cell.text.data(), cell.length);
        const bool ascii = fixed_pitch_ && cell.width == telar::CellWidth::single &&
                           cell.length == 1 && static_cast<unsigned char>(cell.text[0]) < 128;
        if (ascii) {
          while (column + count < screen_->columns) {
            const auto &next = screen_->cells[index + count];
            const bool next_selected = anchor_ >= 0 && index + count >= std::min(anchor_, end_) &&
                                       index + count <= std::max(anchor_, end_);
            if (next.width != telar::CellWidth::single || next.length != 1 ||
                static_cast<unsigned char>(next.text[0]) >= 128 || next.style != cell.style ||
                selected != next_selected) {
              break;
            }

            string += QLatin1Char(next.text[0]);
            ++count;
          }
        }

        const QRectF rect(column * cell_.width(),
                          row * cell_.height(),
                          count * cell_.width(),
                          cell_.height());
        if (bg != background_) {
          line->appendChildNode(new QSGSimpleRectNode(rect, bg));
        }

        if (cell.width != telar::CellWidth::continuation && !string.isEmpty()) {
          QFont font = font_;
          font.setBold(has(cell.style, telar::CellAttribute::bold));
          font.setItalic(has(cell.style, telar::CellAttribute::italic));
          font.setStrikeOut(has(cell.style, telar::CellAttribute::strikethrough));
          font.setOverline(has(cell.style, telar::CellAttribute::overline));
          font.setUnderline(((cell.style.flags >> underline_shift) & underline_mask) != 0);
          if (ascii) {
            font.setLetterSpacing(QFont::AbsoluteSpacing,
                                  cell_.width() -
                                      QFontMetricsF(font).horizontalAdvance(QLatin1Char('M')));
          }

          QTextLayout layout(string, font);
          QTextOption option;
          option.setTextDirection(Qt::LeftToRight);
          option.setWrapMode(QTextOption::NoWrap);
          layout.setTextOption(option);
          QTextCharFormat format;
          format.setForeground(fg);
          layout.setFormats({{0, static_cast<int>(string.size()), format}});
          layout.beginLayout();
          auto text_line = layout.createLine();
          // Shape the line before reading its ascent; createLine alone has no font metrics.
          text_line.setNumColumns(string.size());
          text_line.setPosition({0, ascent_ - text_line.ascent()});
          layout.endLayout();
          text->addTextLayout(rect.topLeft(), &layout);
        }

        column += count;
      }

      line->appendChildNode(text);
    }

    clear(node->overlay);
    const auto &cursor = screen_->cursor;
    if (cursor.visible && cursor_on_ && screen_->connected && hasActiveFocus()) {
      QRectF rect(cursor.x * cell_.width(),
                  cursor.y * cell_.height(),
                  cell_.width(),
                  cell_.height());
      QColor paint = foreground_;
      if (cursor.shape == telar::CursorShape::bar) {
        rect.setWidth(2);
      } else if (cursor.shape == telar::CursorShape::underline) {
        rect.setTop(rect.bottom() - 2);
      } else {
        paint.setAlphaF(0.45);
      }

      node->overlay->appendChildNode(new QSGSimpleRectNode(rect, paint));
    }

    if (!preedit_.isEmpty() || !screen_->connected) {
      auto *text = window()->createTextNode();
      text->setColor(foreground_);
      const QString message =
          screen_->connected ? preedit_ : QStringLiteral("Connecting to runtime…");
      QTextLayout layout(message, font_);
      layout.beginLayout();
      auto text_line = layout.createLine();
      text_line.setNumColumns(message.size());
      text_line.setPosition({0, ascent_ - text_line.ascent()});
      layout.endLayout();
      const QPointF point = screen_->connected
                                ? QPointF(cursor.x * cell_.width(), cursor.y * cell_.height())
                                : QPointF(0, 0);
      text->addTextLayout(point, &layout);
      node->overlay->appendChildNode(text);
    }

    return node;
  }

  void TerminalItem::keyPressEvent(QKeyEvent *event) {
    if (event->matches(QKeySequence::Copy) && anchor_ >= 0) {
      QGuiApplication::clipboard()->setText(selectionText());
    } else if (event->matches(QKeySequence::Paste)) {
      if (send) {
        send(terminalPaste(QGuiApplication::clipboard()->text(), screen_->modes));
      }
    } else if (preedit_.isEmpty()) {
      const auto bytes = terminalKey(*event, screen_->modes);
      if (send && !bytes.isEmpty()) {
        pressed_keys_.insert(event->key());
        send(bytes);
      }
    }

    event->accept();
  }

  void TerminalItem::keyReleaseEvent(QKeyEvent *event) {
    if (!pressed_keys_.contains(event->key())) {
      event->accept();
      return;
    }

    if (!event->isAutoRepeat()) {
      pressed_keys_.remove(event->key());
    }

    const auto bytes = terminalKey(*event, screen_->modes);
    if (send && !bytes.isEmpty()) {
      send(bytes);
    }

    event->accept();
  }

  void TerminalItem::inputMethodEvent(QInputMethodEvent *event) {
    if (send && !event->commitString().isEmpty()) {
      send(event->commitString().toUtf8());
    }

    preedit_ = event->preeditString();
    update();
    event->accept();
  }

  QVariant TerminalItem::inputMethodQuery(Qt::InputMethodQuery query) const {
    switch (query) {
    case Qt::ImEnabled:
      return screen_->connected;
    case Qt::ImCursorRectangle:
      return QRectF(screen_->cursor.x * cell_.width(),
                    screen_->cursor.y * cell_.height(),
                    cell_.width(),
                    cell_.height());
    case Qt::ImFont:
      return font_;
    case Qt::ImHints:
      return static_cast<int>(Qt::ImhNoPredictiveText | Qt::ImhNoAutoUppercase);
    default:
      return QQuickItem::inputMethodQuery(query);
    }
  }

  void TerminalItem::focusInEvent(QFocusEvent *event) {
    QQuickItem::focusInEvent(event);
    if (focused) {
      focused();
    }

    if (send && screen_->modes.focus_events) {
      send("\x1b[I");
    }

    cursor_on_ = true;
    update();
  }

  void TerminalItem::focusOutEvent(QFocusEvent *event) {
    if (send && screen_->modes.focus_events) {
      send("\x1b[O");
    }

    preedit_.clear();
    pressed_keys_.clear();
    mouseUngrabEvent();
    QQuickItem::focusOutEvent(event);
    update();
  }

  int TerminalItem::indexAt(QPointF point) const {
    if (!screen_->columns || !screen_->rows) {
      return -1;
    }

    const auto column =
        std::clamp(static_cast<int>(point.x() / cell_.width()), 0, screen_->columns - 1);
    const auto row = std::clamp(static_cast<int>(point.y() / cell_.height()), 0, screen_->rows - 1);
    return row * screen_->columns + column;
  }

  void TerminalItem::mousePacket(int button, QPointF point, bool release) {
    if (!send) {
      return;
    }

    const int x =
        std::max(1, static_cast<int>(point.x() / (screen_->mouse.pixels ? 1 : cell_.width())) + 1);
    const int y =
        std::max(1, static_cast<int>(point.y() / (screen_->mouse.pixels ? 1 : cell_.height())) + 1);
    if (screen_->mouse.sgr) {
      send("\x1b[<" + QByteArray::number(button) + ';' + QByteArray::number(x) + ';' +
           QByteArray::number(y) + (release ? 'm' : 'M'));
    } else if (x <= legacy_mouse_limit && y <= legacy_mouse_limit) {
      QByteArray bytes("\x1b[M");
      bytes += static_cast<char>((release ? mouse_release : button) + legacy_mouse_offset);
      bytes += static_cast<char>(x + legacy_mouse_offset);
      bytes += static_cast<char>(y + legacy_mouse_offset);
      send(bytes);
    }
  }

  void TerminalItem::reportMouse(QMouseEvent *event, bool release, bool motion) {
    if (release && screen_->mouse.tracking == telar::MouseTracking::x10) {
      return;
    }

    if (motion && screen_->mouse.tracking != telar::MouseTracking::button &&
        screen_->mouse.tracking != telar::MouseTracking::any) {
      return;
    }

    const auto buttons = release ? Qt::MouseButtons(event->button()) : event->buttons();
    int button = buttons.testFlag(Qt::LeftButton)     ? 0
                 : buttons.testFlag(Qt::MiddleButton) ? 1
                 : buttons.testFlag(Qt::RightButton)  ? 2
                                                      : mouse_release;
    if (motion) {
      button += mouse_motion;
    }

    if (event->modifiers().testFlag(Qt::ShiftModifier)) {
      button += mouse_shift;
    }

    if (event->modifiers().testFlag(Qt::AltModifier)) {
      button += mouse_alt;
    }

    if (controlModifier(event->modifiers())) {
      button += mouse_control;
    }

    if (!motion && !release) {
      captured_button_ = button;
    }

    captured_position_ = event->position();
    mousePacket(button, event->position(), release);
  }

  void TerminalItem::mousePressEvent(QMouseEvent *event) {
    forceActiveFocus(Qt::MouseFocusReason);
    mouse_report_ = screen_->mouse.tracking != telar::MouseTracking::none &&
                    !event->modifiers().testFlag(Qt::ShiftModifier);
    if (mouse_report_) {
      reportMouse(event, false, false);
    } else if (event->button() == Qt::LeftButton) {
      selecting_ = true;
      anchor_ = end_ = indexAt(event->position());
      ++appearance_;
      update();
    }

    event->accept();
  }

  void TerminalItem::mouseMoveEvent(QMouseEvent *event) {
    if (mouse_report_) {
      reportMouse(event, false, true);
    } else if (selecting_) {
      end_ = indexAt(event->position());
      ++appearance_;
      update();
    }

    event->accept();
  }

  void TerminalItem::mouseReleaseEvent(QMouseEvent *event) {
    if (mouse_report_) {
      reportMouse(event, true, false);
    }

    selecting_ = mouse_report_ = false;
    event->accept();
  }

  void TerminalItem::mouseUngrabEvent() {
    if (mouse_report_) {
      mousePacket(captured_button_, captured_position_, true);
    }

    selecting_ = mouse_report_ = false;
  }

  void TerminalItem::wheelEvent(QWheelEvent *event) {
    const auto delta = event->angleDelta().y();
    if (delta == 0 && event->pixelDelta().y() == 0) {
      event->accept();
      return;
    }

    if (screen_->mouse.tracking != telar::MouseTracking::none &&
        !event->modifiers().testFlag(Qt::ShiftModifier)) {
      mousePacket(delta > 0 ? mouse_wheel_up : mouse_wheel_down, event->position(), false);
    } else if (screen_->modes.alternate_screen && screen_->modes.alternate_scroll) {
      if (send) {
        send(delta > 0 ? "\x1b[A" : "\x1b[B");
      }
    } else if (scrolled) {
      wheel_remainder_ += delta;
      const auto steps =
          delta == 0 ? static_cast<int>(std::round(event->pixelDelta().y() / cell_.height()))
                     : wheel_remainder_ / wheel_unit * wheel_rows;
      if (delta != 0) {
        wheel_remainder_ %= wheel_unit;
      }

      const auto offset = std::clamp<qint64>(static_cast<qint64>(screen_->scroll.offset) + steps,
                                             0,
                                             screen_->scroll.total_rows - screen_->rows);
      scrolled(static_cast<std::uint32_t>(offset));
    }

    event->accept();
  }

  QString TerminalItem::selectionText() const {
    QString result;
    if (anchor_ < 0 || end_ < 0 || !screen_->columns) {
      return result;
    }

    const int first = std::min(anchor_, end_),
              last = std::min(static_cast<int>(screen_->cells.size()) - 1, std::max(anchor_, end_));
    for (int index = first; index <= last; ++index) {
      const auto &cell = screen_->cells[index];
      if (cell.width != telar::CellWidth::continuation) {
        result += QString::fromUtf8(cell.text.data(), cell.length);
      }

      if ((index + 1) % screen_->columns == 0 && index != last &&
          !(screen_->row_flags[index / screen_->columns] &
            static_cast<telar::Byte>(telar::RowFlag::wrap))) {
        while (result.endsWith(' ')) {
          result.chop(1);
        }

        result += '\n';
      }
    }

    return result;
  }
} // namespace workbench
