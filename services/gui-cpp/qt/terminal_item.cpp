#include "terminal_item.hpp"
#include "application.hpp"
#include "application/dependencies.hpp"
#include "application/records.hpp"
#include "core/terminal_size.hpp"
#include "fonts/font_coverage.hpp"
#include "fonts/font_role.hpp"
#include "graphics_scene.hpp"
#include "input/key_event.hpp"
#include "input/wheel_accumulator.hpp"
#include "key_adapter.hpp"
#include "key_encoding.hpp"
#include "platform/window.hpp"
#include "resident_fonts.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal/copy_grid.hpp"
#include "terminal/screen.hpp"
#include "terminal/selection.hpp"
#include "terminal_font.hpp"
#include "terminal_scene.hpp"
#include "window_font_catalog.hpp"
#include "window_images.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QSGSimpleRectNode>
#include <QSGTextNode>
#include <QSGTransformNode>
#include <QTextLayout>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcoreevent.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qpoint.h>
#include <QtCore/qsize.h>
#include <QtCore/qtimer.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtCore/qvariant.h>
#include <QtGui/qtextformat.h>
#include <QtQuick/qquickitem.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

TerminalItem::TerminalItem(QQuickItem *parent)
    : QQuickItem(parent) {
  setFlag(ItemHasContents);
  setFlag(ItemAcceptsInputMethod);
  setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton | Qt::RightButton);
  setAcceptHoverEvents(true);
  setClip(true);
  setActiveFocusOnTab(false);

  connect(&blink_, &QTimer::timeout, this, [this] {
    cursor_on_ = !cursor_on_;
    update();
  });

  connect(this, &QQuickItem::activeFocusChanged, this, &TerminalItem::synchronizeFocus);
  connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow *window) {
    prepared_frame_.pane = {};
    prepared_frame_.links.reset();
    QObject::disconnect(window_activity_connection_);
    if (window != nullptr) {
      WindowImages::forWindow(*window);
      window_activity_connection_ = connect(window, &QWindow::activeChanged, this, &TerminalItem::synchronizeFocus);
    }

    measure();
  });
}

void TerminalItem::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged) {
    measure();
  }
}

QObject *TerminalItem::application() const noexcept {
  return application_;
}

TerminalItem::~TerminalItem() {
  QObject::disconnect(this, nullptr, this, nullptr);
  QObject::disconnect(window_activity_connection_);

  if (application_ != nullptr) {
    application_->unregisterTerminal(*this);
  }

  try {
    releaseKeys();
    releaseMouse();
  } catch (const std::exception &error) {
    qWarning("Unable to release terminal input: %s", error.what());
  }
}

void TerminalItem::setApplication(QObject *application) {
  auto *next = qobject_cast<Application *>(application);
  if (next == application_) {
    return;
  }

  if (application_ != nullptr) {
    releaseKeys();
    releaseMouse();
    application_->unregisterTerminal(*this);
    application_->disconnect(this);
  }

  application_ = next;
  prepared_frame_.pane = {};
  prepared_frame_.links.reset();
  presented_frame_id_ = 0;
  if (application_ != nullptr) {
    connect(application_, &QObject::destroyed, this, [this] {
      application_ = nullptr;
      update();
      emit applicationChanged();
    });
    connect(application_, &Application::terminalChanged, this, [this](qulonglong pane_id) {
      if (pane_id == pane_id_) {
        refresh();
      }
    });

    connect(application_, &Application::configurationChanged, this, &TerminalItem::measure);
    connect(application_, &Application::machineChanged, this, &TerminalItem::invalidateMachine);
    connect(application_, &Application::stateChanged, this, &TerminalItem::refreshLinkHover);
    connect(application_, &Application::dialogChanged, this, &TerminalItem::refreshLinkHover);
    connect(application_, &Application::pointerModifiersChanged, this, &TerminalItem::refreshLinkHover);
    connect(application_, &Application::inputReleasing, this, [this](qulonglong pane_id) {
      if (pane_id != pane_id_) {
        return;
      }

      releaseKeys();
      releaseMouse();
      if (const auto *current = pane(); current != nullptr && keyboard_ && current->screen.modes().focus_events) {
        send("\x1b[O", PaneInputSource::terminal_report);
      }

      keyboard_ = false;
      preedit_.clear();
    });
  }

  measure();
  if (application_ != nullptr) {
    application_->registerTerminal(*this);
  }

  emit applicationChanged();
}

QString TerminalItem::paneId() const {
  return QString::number(pane_id_);
}

std::uint64_t TerminalItem::paneIdentity() const noexcept {
  return pane_id_;
}

QSizeF TerminalItem::cellSize() const noexcept {
  return font_.cell;
}

void TerminalItem::setPaneId(const QString &identity) {
  const auto next = identity.toULongLong();
  if (next == pane_id_) {
    return;
  }

  releaseKeys();
  releaseMouse();
  if (application_ != nullptr) {
    application_->unregisterTerminal(*this);
  }

  wheel_.reset();
  pane_id_ = next;
  font_row_revisions_.clear();
  presented_frame_id_ = 0;
  prepared_frame_.pane = {};
  prepared_frame_.links.reset();
  clearLinkHover();
  if (application_ != nullptr) {
    application_->registerTerminal(*this);
  }

  ++appearance_;
  refresh();
  emit paneIdChanged();
}

Pane<ApplicationAllocator> *TerminalItem::pane() const noexcept {
  return application_ == nullptr ? nullptr : application_->pane(pane_id_);
}

void TerminalItem::measure() {
  if (application_ == nullptr) {
    return;
  }

  try {
    link_gesture_.cancel();
    link_stamp_.reset();
    const auto scale = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    auto resolved = application_->resolveFont(scale);
    font_ = std::move(resolved.font);
    font_grid_ = resolved.grid;
    font_scale_ = scale;
    ++appearance_;
    polish();
    update();
    refreshLinkHover();
  } catch (const std::exception &error) {
    qWarning("Terminal font: %s", error.what());
  }
}

void TerminalItem::invalidateMachine() {
  wheel_.reset();
  preedit_.clear();
  font_row_revisions_.clear();
  prepared_frame_.pane = {};
  prepared_frame_.links.reset();
  presented_frame_id_ = 0;
  link_gesture_.cancel();
  clearLinkHover();
  keyboard_ = false;
  blink_.stop();
  ++appearance_;
  polish();
  update();
}

void TerminalItem::resizeTerminal() {
  if (application_ == nullptr || window() == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0) {
    return;
  }

  const TerminalGrid grid{.cell_width_px = font_grid_.width, .cell_height_px = font_grid_.height, .scale = font_scale_};
  if (const auto size = grid.fit(width(), height())) {
    application_->resize(pane_id_, *size);
  }
}

void TerminalItem::refresh() {
  cursor_on_ = true;
  synchronizeFocus();
  polish();
  update();
  refreshLinkHover();

  if (hasActiveFocus()) {
    QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
  }
}

void TerminalItem::refreshFonts() {
  auto *catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
  if (font_catalog_ != catalog) {
    QObject::disconnect(font_catalog_connection_);
    font_catalog_ = catalog;
    if (catalog != nullptr) {
      font_catalog_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, [this] {
        font_collection_.reset();
        font_row_revisions_.clear();
        ++appearance_;
        polish();
        update();
      });
    }
  }

  if (catalog != nullptr && application_ != nullptr) {
    catalog->configure(application_->configuration().font);
    if (font_collection_ != catalog->collection()) {
      font_collection_ = catalog->collection();
      fonts_ = ResidentFonts::shared(font_collection_);
    }
  }
}

void TerminalItem::updatePolish() {
  // QML delegates receive geometry and window density separately. Commit only
  // their settled viewport before rendering, never the windowless default grid.
  resizeTerminal();
  refreshFonts();
  const auto *current = pane();
  if (current == nullptr || !font_catalog_) {
    return;
  }

  const auto &screen = current->screen;
  font_row_revisions_.resize(screen.rows());
  for (std::size_t row = 0; row < screen.rows(); ++row) {
    auto &revision = font_row_revisions_[static_cast<qsizetype>(row)];
    if (revision == screen.rowRevision(row)) {
      continue;
    }

    requestRowFonts(screen.row(row));
    revision = screen.rowRevision(row);
  }

  if (!preedit_.isEmpty()) {
    const auto bytes = preedit_.toUtf8();
    font_catalog_->request({bytes.constData(), static_cast<std::size_t>(bytes.size())}, fonts::FontRole::primary);
  }

  application_->prepareImagePlacements();
}

void TerminalItem::requestRowFonts(std::span<const CellValue> cells) {
  const auto &primary = fonts_->face(fonts::FontRole::primary);
  for (const auto &cell : cells) {
    if (cell.width == CellWidth::continuation || cell.utf8().empty()) {
      continue;
    }

    try {
      if (!fonts::FontCoverage::covers(primary, cell.utf8())) {
        font_catalog_->request(cell.utf8(), fonts::FontRole::primary);
      }
    } catch (const std::invalid_argument &) {
      const auto normalized = QString::fromUtf8(cell.utf8()).toUtf8();
      font_catalog_->request({normalized.constData(), static_cast<std::size_t>(normalized.size())}, fonts::FontRole::primary);
    }
  }
}

void TerminalItem::geometryChange(const QRectF &current, const QRectF &previous) {
  if (current != previous) {
    link_gesture_.cancel();
    link_stamp_.reset();
  }

  wheel_.reset();
  QQuickItem::geometryChange(current, previous);
  polish();
  refreshLinkHover();
}

QSGNode *TerminalItem::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *update_data) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr || window() == nullptr || !font_collection_) {
    prepared_frame_.pane = {};
    prepared_frame_.links.reset();
    const std::unique_ptr<QSGNode> discarded{previous};

    return nullptr;
  }

  CellSelection selection;
  std::optional<Cursor> copy_cursor;
  const auto &copy = application_->copyState();
  if (copy && copy->pane_id == pane_id_) {
    selection = copy->selection(copyGrid(current->screen));
    if (!copy->pointer) {
      const auto offset = current->screen.scroll().offset;
      copy_cursor = Cursor{};
      if (copy->cursor.y >= offset && copy->cursor.y - offset < current->screen.rows()) {
        copy_cursor = Cursor{.visible = true, .x = copy->cursor.x, .y = static_cast<std::uint16_t>(copy->cursor.y - offset), .shape = CursorShape::block, .blink = false};
      }
    }
  }

  const TerminalPresentation frame{
      .screen = current->screen,
      .graphics = current->graphics,
      .configuration = application_->configuration(),
      .font = font_,
      .preedit = preedit_,
      .fonts = font_collection_,
      .grid = font_grid_,
      .selection = selection,
      .bounds = boundingRect(),
      .scale = window()->effectiveDevicePixelRatio(),
      .appearance = appearance_,
      .box_stroke = font_grid_.box_stroke,
      .pane_focused = hasActiveFocus(),
      .keyboard = keyboard_,
      .cursor_on = cursor_on_,
      .cursor_override = copy_cursor,
      .hovered_link = link_hover_.current() ? &link_hover_.current()->match : nullptr,
      .owner = this,
  };
  auto *node = TerminalScene::synchronizeNode(previous, *window(), frame);
  prepared_frame_ = {
      .pane = {.pane_id = current->id, .frame_id = current->screen.frameId(), .attached = current->attached, .attachment_generation = current->attachment_generation},
      .links = prepareLinkPresentation(),
      .revision = prepared_frame_.revision + 1,
  };

  return node;
}

void TerminalItem::keyPressEvent(QKeyEvent *event) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }

  if (application_->handleBindingKey(*event, *this, !preedit_.isEmpty())) {
    event->accept();

    return;
  }

  const Qt::KeyboardModifiers clipboard_modifiers = platform::usesCommandKey() ? Qt::ControlModifier : Qt::ControlModifier | Qt::ShiftModifier;
  const auto clipboard_shortcut = (event->modifiers() & (Qt::ControlModifier | Qt::ShiftModifier | Qt::AltModifier | Qt::MetaModifier)) == clipboard_modifiers;
  const auto &copy = application_->copyState();
  const auto selected = copy && copy->pane_id == pane_id_ && copy->pointer && copy->anchor;

  if (clipboard_shortcut && event->key() == Qt::Key_C && selected) {
    application_->copySelection(pane_id_);
  } else if (clipboard_shortcut && event->key() == Qt::Key_V) {
    application_->paste(pane_id_, QGuiApplication::clipboard()->text());
  } else if (preedit_.isEmpty()) {
    static_cast<void>(sendKeyPress(*event, current->screen.modes()));
  }

  const bool cursor_changed = !std::exchange(cursor_on_, true);
  if (blink_.isActive()) {
    blink_.start();
  }

  if (cursor_changed) {
    update();
  }

  event->accept();
}

bool TerminalItem::sendKeyPress(const QKeyEvent &event, const InputModes &modes) {
  const auto semantic = NativeKeyAdapter::terminalKey(event);
  const auto bytes = semantic ? encodeKey(*semantic, modes) : encodeKey(event, modes);
  if (bytes.isEmpty()) {
    return false;
  }

  auto *entry = std::ranges::find_if(pressed_keys_, [&](const auto &key) {
    return key.matches(event);
  });
  if (entry == pressed_keys_.end()) {
    entry = std::ranges::find_if(pressed_keys_, [](const auto &key) {
      return key.key == 0;
    });
  }

  if (entry == pressed_keys_.end()) {
    return false;
  }

  *entry = {
      .key = event.key(),
      .modifiers = event.modifiers(),
      .scan = event.nativeScanCode(),
      .native_key = event.nativeVirtualKey(),
      .native_modifiers = event.nativeModifiers(),
      .text = event.text(),
      .semantic = semantic,
  };
  const bool delivered = send(bytes);
  if (delivered && semantic && application_ != nullptr) {
    application_->attachmentKey(pane_id_, *semantic);
  }

  return delivered;
}

void TerminalItem::keyReleaseEvent(QKeyEvent *event) {
  if (application_ != nullptr && application_->handleBindingKey(*event, *this, !preedit_.isEmpty())) {
    event->accept();

    return;
  }

  const auto *current = pane();
  auto *const entry = std::ranges::find_if(pressed_keys_, [&](const auto &key) {
    return key.matches(*event);
  });
  if (current != nullptr && entry != pressed_keys_.end() && !event->isAutoRepeat()) {
    const auto released = std::exchange(*entry, PressedKey{});
    send(released.release(current->screen.modes()), PaneInputSource::key_release);
  }

  event->accept();
}

void TerminalItem::inputMethodEvent(QInputMethodEvent *event) {
  if (!event->commitString().isEmpty()) {
    if (application_ != nullptr) {
      application_->interruptBindings();
    }

    sendCommittedText(event->commitString());
  }

  preedit_ = event->preeditString();
  polish();
  update();
  event->accept();
}

void TerminalItem::sendCommittedText(const QString &text) {
  if (application_ == nullptr || !application_->copyModeActive()) {
    send(text.toUtf8());

    return;
  }

  for (qsizetype offset = 0; offset < text.size();) {
    const auto paired = text[offset].isHighSurrogate() && offset + 1 < text.size() && text[offset + 1].isLowSurrogate();
    const auto length = paired ? 2 : 1;
    const auto scalar = QString::fromRawData(text.constData() + offset, length);
    const QKeyEvent key{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, scalar};
    static_cast<void>(application_->handleCopyKey(pane_id_, key));
    offset += length;
  }
}

QVariant TerminalItem::inputMethodQuery(Qt::InputMethodQuery query) const {
  const auto *current = pane();
  if (current == nullptr) {
    return {};
  }

  const auto &cursor = current->screen.cursor();
  switch (query) {
  case Qt::ImEnabled:
    return current->attached;
  case Qt::ImCursorRectangle:
    return QRectF{cursor.x * font_.cell.width(), cursor.y * font_.cell.height(), font_.cell.width(), font_.cell.height()};
  case Qt::ImFont:
    return font_.faces[0];
  case Qt::ImHints:
    return static_cast<int>(Qt::ImhNoPredictiveText | Qt::ImhNoAutoUppercase);
  default:
    return QQuickItem::inputMethodQuery(query);
  }
}

void TerminalItem::focusInEvent(QFocusEvent *event) {
  QQuickItem::focusInEvent(event);
  synchronizeFocus();
}

void TerminalItem::focusOutEvent(QFocusEvent *event) {
  QQuickItem::focusOutEvent(event);
  synchronizeFocus();
}

void TerminalItem::synchronizeFocus() {
  const auto *current = pane();
  const auto window_active = window() != nullptr && window()->isActive();
  const auto keyboard = hasActiveFocus() && window_active;
  if (keyboard != keyboard_) {
    keyboard_ = keyboard;
    if (current != nullptr && current->screen.modes().focus_events) {
      send(keyboard ? "\x1b[I" : "\x1b[O", PaneInputSource::terminal_report);
    }

    if (!keyboard) {
      preedit_.clear();
      releaseKeys();
    }

    cursor_on_ = true;
  }

  if (window_active_ != window_active) {
    window_active_ = window_active;
    if (!window_active) {
      releaseMouse();
    }
  }

  const auto blinks = keyboard && current != nullptr && !application_->copyModeActive() && current->screen.cursor().visible && current->screen.cursor().blink && (current->screen.cursor().shape != CursorShape::default_shape || application_->configuration().cursor_blink);
  if (blinks) {
    blink_.setInterval(static_cast<int>(application_->configuration().blink_interval.count()));
    if (!blink_.isActive()) {
      blink_.start();
    }
  } else {
    blink_.stop();
  }

  update();
  refreshLinkHover();
}

void TerminalItem::releaseKeys() {
  const auto *current = pane();
  for (auto &key : pressed_keys_) {
    if (key.key == 0) {
      continue;
    }

    const auto held = std::exchange(key, PressedKey{});
    if (current != nullptr) {
      send(held.release(current->screen.modes()), PaneInputSource::key_release);
    }
  }
}

QByteArray TerminalItem::PressedKey::release(const InputModes &modes) const {
  if (semantic) {
    auto release = *semantic;
    release.phase = KeyPhase::release;

    return encodeKey(release, modes);
  }

  const QKeyEvent release{QEvent::KeyRelease, key, modifiers, scan, native_key, native_modifiers, text};

  return encodeKey(release, modes);
}

bool TerminalItem::send(const QByteArray &bytes, PaneInputSource source) {
  return application_ != nullptr && !bytes.isEmpty() && application_->input(pane_id_, bytes, source);
}

}
