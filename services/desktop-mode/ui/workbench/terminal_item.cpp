#include "terminal_item.hpp"
#include "terminal_input.hpp"
#include "../../log_categories.hpp"
#include "../../trace.hpp"
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
    // Reattaching after a tab or workspace switch takes a few frames; only a longer wait is news.
    constexpr int connecting_grace_ms = 750;
    constexpr int maximum_cells = 130359;
    constexpr int maximum_dimension = 4096;
    constexpr int wheel_unit = 120;
    constexpr int wheel_rows = 3;
    constexpr int minimum_font_size = 6, maximum_font_size = 72, default_font_size = 14;
    constexpr int mouse_release = 3, mouse_motion = 32, mouse_wheel_up = 64, mouse_wheel_down = 65;
    constexpr int mouse_shift = 4, mouse_alt = 8, mouse_control = 16;
    constexpr int legacy_mouse_offset = 32, legacy_mouse_limit = 223;
    constexpr int underline_shift = 8, underline_mask = 7;
    // The theme's `terminal.ansi` names, in the order of the first 16 indexed colors.
    constexpr std::array<const char *, 16> ansi_names{"black",
                                                      "red",
                                                      "green",
                                                      "yellow",
                                                      "blue",
                                                      "magenta",
                                                      "cyan",
                                                      "white",
                                                      "bright_black",
                                                      "bright_red",
                                                      "bright_green",
                                                      "bright_yellow",
                                                      "bright_blue",
                                                      "bright_magenta",
                                                      "bright_cyan",
                                                      "bright_white"};

    bool has(const telar::CellStyle &style, telar::CellAttribute flag) {
      return style.flags & static_cast<std::uint16_t>(flag);
    }

    QColor color(const telar::CellColor &value, QColor fallback, const TerminalPalette &palette) {
      if (value.kind == telar::CellColor::Kind::default_color) {
        return fallback;
      }

      if (value.kind == telar::CellColor::Kind::rgb) {
        return {value.channels[0], value.channels[1], value.channels[2]};
      }

      const int index = value.channels[0];
      if (index < static_cast<int>(palette.size())) {
        return palette[index];
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
    TELAR_TRACE("terminal.create");
    setFlag(ItemHasContents);
    setFlag(ItemAcceptsInputMethod);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton | Qt::RightButton);
    setClip(true);
    setActiveFocusOnTab(true);
    configure({});
    blink_.setInterval(cursor_interval_ms);
    QObject::connect(&blink_, &QTimer::timeout, this, [this] {
      if (isVisible() && keyboard_ && screen_->cursor.blink) {
        cursor_on_ = !cursor_on_;
        update();
      }
    });

    blink_.start();
    if (auto *pane = window()) {
      QObject::connect(pane, &QWindow::activeChanged, this, [this] {
        syncKeyboard();
      });
    }

    waiting_timer_.setSingleShot(true);
    waiting_timer_.setInterval(connecting_grace_ms);
    QObject::connect(&waiting_timer_, &QTimer::timeout, this, [this] {
      if (!screen_->connected && presented_) {
        qCInfo(telar_log::terminal) << window()->title() << "still has no frame after"
                                    << waiting_timer_.interval() << "ms; showing the placeholder";
        waiting_ = true;
        update();
      }
    });
    // The base constructor already placed the item in its parent's window, before any
    // connection here existed, so that window is followed explicitly as well.
    const auto follow = [this](QQuickWindow *window) {
      if (window) {
        QObject::connect(window, &QWindow::screenChanged, this, [this] {
          resizeTerminal();
        });

        resizeTerminal();
      }
    };

    QObject::connect(this, &QQuickItem::windowChanged, this, follow);
    follow(window());
  }

  void TerminalItem::configure(const QVariantMap &options) {
    TELAR_TRACE("terminal.configure");
    const auto theme = options.value("theme").toMap();
    const auto family = theme.value("fonts").toMap().value("mono").toString();
    font_ = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    if (!family.isEmpty()) {
      font_.setFamily(family);
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
    const auto colors = theme.value("terminal").toMap();
    const auto ansi = colors.value("ansi").toMap();
    const QColor fg(colors.value("foreground").toString());
    const QColor bg(colors.value("background").toString());
    const QColor selection(colors.value("selection").toString());

    for (std::size_t index = 0; index < ansi_names.size(); ++index) {
      const QColor value(ansi.value(QLatin1StringView(ansi_names[index])).toString());

      if (value.isValid()) {
        palette_[index] = value;
      }
    }

    if (selection.isValid()) {
      selection_ = selection;
    }

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
    TELAR_TRACE("terminal.refresh");
    if (end_ >= static_cast<int>(screen_->cells.size())) {
      anchor_ = end_ = -1;
      ++appearance_;
    }

    cursor_on_ = true;
    if (keyboard_) {
      QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
    }

    watchConnection();
    update();
  }

  // The controller says when the pane is part of what the user is looking at. Window state
  // cannot: a hidden workspace keeps its windows shown on its own Space.
  void TerminalItem::setPresented(bool presented) {
    presented_ = presented;
    watchConnection();
  }

  // The grace period only runs while the pane is presented, so a pane presented again after a
  // switch starts a fresh one instead of inheriting the time it spent out of sight.
  void TerminalItem::watchConnection() {
    if (screen_->connected || !presented_) {
      waiting_timer_.stop();
      waiting_ = false;
      return;
    }

    if (!waiting_ && !waiting_timer_.isActive()) {
      waiting_timer_.start();
    }
  }

  QSizeF TerminalItem::cellSize() const {
    return cell_;
  }

  void TerminalItem::resizeTerminal() {
    TELAR_TRACE("terminal.resize");
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
    TELAR_TRACE("terminal.geometry_change");
    QQuickItem::geometryChange(current, previous);
    resizeTerminal();
  }

  QSGNode *TerminalItem::updatePaintNode(QSGNode *previous, UpdatePaintNodeData *) {
    TELAR_TRACE("terminal.update_paint_node");
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
        auto fg = color(cell.style.foreground, foreground_, palette_);
        auto bg = color(cell.style.background, background_, palette_);
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
    if (cursor.visible && cursor_on_ && screen_->connected && keyboard_) {
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

    if (!preedit_.isEmpty() || (!screen_->connected && waiting_)) {
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
    TELAR_TRACE("terminal.key_press");
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
    TELAR_TRACE("terminal.key_release");
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
    TELAR_TRACE("terminal.input_method");
    if (send && !event->commitString().isEmpty()) {
      send(event->commitString().toUtf8());
    }

    preedit_ = event->preeditString();
    update();
    event->accept();
  }

  QVariant TerminalItem::inputMethodQuery(Qt::InputMethodQuery query) const {
    TELAR_TRACE("terminal.input_method_query");
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
    TELAR_TRACE("terminal.focus_in");
    QQuickItem::focusInEvent(event);
    syncKeyboard();
  }

  void TerminalItem::focusOutEvent(QFocusEvent *event) {
    TELAR_TRACE("terminal.focus_out");
    syncKeyboard();
    QQuickItem::focusOutEvent(event);
  }

  // Keys arrive while the terminal has active focus in the active window. Active focus alone is
  // not enough: the keyboard router leaves a pane its focus item when the keyboard moves to
  // another pane, and only deactivates its window.
  void TerminalItem::syncKeyboard() {
    TELAR_TRACE("terminal.sync_keyboard");
    const bool keyboard = hasActiveFocus() && window() && window()->isActive();
    if (keyboard == keyboard_) {
      return;
    }

    keyboard_ = keyboard;
    if (send && screen_->modes.focus_events) {
      send(keyboard ? "\x1b[I" : "\x1b[O");
    }

    if (keyboard) {
      cursor_on_ = true;
    } else {
      preedit_.clear();
      pressed_keys_.clear();
      mouseUngrabEvent();
    }

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
    TELAR_TRACE("terminal.report_mouse");
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
    TELAR_TRACE("terminal.mouse_press");
    // Focus within the window only: the keyboard router decides when the window holds the keyboard.
    setFocus(true, Qt::MouseFocusReason);
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
    TELAR_TRACE("terminal.mouse_move");
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
    TELAR_TRACE("terminal.mouse_release");
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
    TELAR_TRACE("terminal.wheel");
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
    TELAR_TRACE("terminal.selection_text");
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
