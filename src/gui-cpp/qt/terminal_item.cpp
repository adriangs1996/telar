#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "terminal_item.hpp"
#include "application.hpp"
#include "../application/dependencies.hpp"
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include <bit>
#include <stdexcept>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "prompt_keys.hpp"
#include <chrono>
#include <cmath>
#include <type_traits>
#include "graphics_scene.hpp"
#include <tuple>
#include "../input/wheel_accumulator.hpp"
#include "key_adapter.hpp"
#include "key_encoding.hpp"
#include "../platform/window.hpp"
#include "resident_fonts.hpp"
#include "../terminal/cell_position.hpp"
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

#include "application/dependencies.hpp"
#include "core/terminal_size.hpp"
#include "input/wheel_accumulator.hpp"
#include "platform/window.hpp"
#include "terminal/screen.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.face;
import telar.gui.input.key_encoder;
import telar.gui.terminal.font_grid;
import telar.gui.terminal.copy_mode;

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
  hold_limit_.setSingleShot(true);
  connect(&hold_limit_, &QTimer::timeout, this, &TerminalItem::releaseOutput);

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

  // QML owns the application; this item registers with it and unregisters before it changes.
  application_ = tbc::raw(next);
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
    connect(application_, &Application::promptChanged, this, [this](qulonglong pane_id) {
      if (pane_id == pane_id_) {
        refreshBlocks();
        update();
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
    // The configuration may have changed the editor's mode, and the font the rows' height.
    refreshBlocks();
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
  refreshBlocks();
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

QString TerminalItem::preeditText() const {
  return preedit_;
}

QRectF TerminalItem::promptCaret() const noexcept {
  return prompt_caret_;
}

void TerminalItem::setPromptCaret(const QRectF &caret) {
  if (prompt_caret_ != caret) {
    prompt_caret_ = caret;
    if (hasActiveFocus()) {
      QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
    }
    emit promptCaretChanged();
  }
}

struct PromptRows {
  std::size_t first = 0;
  std::size_t count = 0;
  // Whether the last row is the cursor's, where the command's separator will be.
  bool cursor = false;
};

// The rows of the shell's prompt the cursor sits in, which telar's editor stands in for, while
// the editor has the pane: from the nearest row the shell marked as a prompt start down to the
// cursor. Scrolled up, the cursor may sit below the view with the prompt's first rows still at
// its bottom: those count only past `live_from`, where the last command's rows end, counted
// from the top of the scrollback, and run to the view's last row.
static PromptRows promptRows(const Screen<ApplicationAllocator> &screen, bool editing, std::uint64_t live_from) {
  const auto rows = static_cast<std::size_t>(screen.rows());
  if (!editing || rows == 0) {
    return {};
  }
  const auto offset = static_cast<std::uint64_t>(screen.scroll().offset);
  const auto bottom = static_cast<std::uint64_t>(copyGrid(screen).maximumOffset());
  const auto &cursor = screen.cursor();
  const bool below = offset < bottom && !cursor.visible;
  const std::size_t last = below ? rows - 1 : cursor.y;
  if (last >= rows) {
    return {};
  }
  constexpr std::size_t search = 8;
  for (std::size_t row = last + 1; row-- > 0 && last - row < search;) {
    if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
      // The cursor is at or under the scrollback's live screen, at most `search` rows under its prompt.
      if (below && (offset + row < live_from || offset + row + search <= bottom)) {
        return {};
      }
      return {row, last - row + 1, !below};
    }
  }
  return {};
}

// Where the last command's rows end, counted from the top of the scrollback: the live prompt is past it.
static std::uint64_t liveFrom(const auto &blocks) noexcept {
  return blocks.empty() ? 0 : static_cast<std::uint64_t>(blocks.back().row) + blocks.back().rows;
}

static QString blockState(CommandBlockState state) {
  switch (state) {
  case CommandBlockState::running:
    return QStringLiteral("running");
  case CommandBlockState::succeeded:
    return QStringLiteral("succeeded");
  case CommandBlockState::failed:
    return QStringLiteral("failed");
  case CommandBlockState::interrupted:
    break;
  }
  return QStringLiteral("interrupted");
}

// The rows painted empty, and the separators and rail drawn for the commands the shell ran.
// Read on the GUI thread whenever the pane or its editor changes, for the next paint.
void TerminalItem::refreshBlocks() {
  const auto *current = pane();
  QVariantList separators;
  QVariantList rail;
  int prompt_row = -1;
  int prompt_top = -1;
  int cursor_row = -1;
  int screen_rows = 0;
  int rows_below = 0;
  hidden_rows_.clear();
  if (current != nullptr && application_ != nullptr) {
    const auto &screen = current->screen;
    const auto rows = static_cast<std::size_t>(screen.rows());
    hidden_rows_.assign(rows, 0);
    const auto [first, count, cursor] = promptRows(screen, application_->promptSurface(pane_id_) == prompt::Surface::editor, liveFrom(current->blocks));
    std::fill_n(hidden_rows_.begin() + static_cast<std::ptrdiff_t>(std::min(first, rows)), std::min(count, rows - std::min(first, rows)), std::uint8_t{1});
    // The command's own row, where its separator will be, and the prompt's first.
    prompt_row = count == 0 || !cursor ? -1 : static_cast<int>(first + count - 1);
    prompt_top = count == 0 ? -1 : static_cast<int>(first);
    // On the live screen the cursor is always in view, wherever the program hid it.
    const auto offset = static_cast<std::uint64_t>(screen.scroll().offset);
    const auto bottom = static_cast<std::uint64_t>(copyGrid(screen).maximumOffset());
    const auto &shown = screen.cursor();
    cursor_row = !screen.modes().alternate_screen && (offset >= bottom || shown.visible) && shown.y < rows ? static_cast<int>(shown.y) : -1;
    screen_rows = static_cast<int>(rows);
    rows_below = bottom > offset ? static_cast<int>(std::min<std::uint64_t>(bottom - offset, std::numeric_limits<int>::max())) : 0;
    // Output held while the line turns into its separator.
    if (held_from_ && !screen.modes().alternate_screen) {
      const auto top = static_cast<std::uint64_t>(screen.scroll().offset);
      for (std::size_t row = 0; row < rows; ++row) {
        if (top + row >= *held_from_) {
          hidden_rows_[row] = 1;
        }
      }
    }
    const bool telar = application_->configuration().prompt.mode == PromptMode::telar && current->shell.shell != IntegratedShell::none && !screen.modes().alternate_screen;
    const auto top = static_cast<std::uint64_t>(screen.scroll().offset);
    const auto selected = application_->selectedBlock(pane_id_);
    for (std::size_t index = 0; telar && index < current->blocks.size(); ++index) {
      const auto &block = current->blocks[index];
      rail.push_back(QVariantMap{{QStringLiteral("state"), blockState(block.state)}, {QStringLiteral("index"), static_cast<int>(index)}, {QStringLiteral("selected"), selected == index}});
      const auto begin = static_cast<std::uint64_t>(block.row);
      const auto end = begin + block.rows;
      if (end <= top || begin >= top + rows) {
        continue;
      }
      for (auto row = std::max(begin, top); row < std::min(end, top + rows); ++row) {
        hidden_rows_[row - top] = 1;
      }
      // On the command's last row: the prompt's other rows stay empty above it, as a margin.
      if (end - 1 >= top && end - 1 < top + rows) {
        separators.push_back(QVariantMap{
            {QStringLiteral("row"), static_cast<int>(end - 1 - top)},
            {QStringLiteral("command"), QString::fromUtf8(block.command.data(), static_cast<qsizetype>(block.command.size()))},
            {QStringLiteral("lines"), static_cast<int>(block.lines)},
            {QStringLiteral("state"), blockState(block.state)},
            {QStringLiteral("status"), block.status},
            {QStringLiteral("duration"), static_cast<qulonglong>(block.duration_ms)},
            {QStringLiteral("index"), static_cast<int>(index)},
            {QStringLiteral("selected"), selected == index},
        });
      }
    }
  }
  if (prompt_top != prompt_top_ || cursor_row != cursor_row_ || screen_rows != rows_ || rows_below != rows_below_) {
    prompt_top_ = prompt_top;
    cursor_row_ = cursor_row;
    rows_ = screen_rows;
    rows_below_ = rows_below;
    emit placeChanged();
  }
  if (separators != separators_ || rail != rail_ || prompt_row != prompt_row_ || font_.cell != shown_cell_) {
    separators_ = std::move(separators);
    rail_ = std::move(rail);
    prompt_row_ = prompt_row;
    shown_cell_ = font_.cell;
    emit blocksChanged();
  }
}

QVariantList TerminalItem::separators() const {
  return separators_;
}

QVariantList TerminalItem::rail() const {
  return rail_;
}

int TerminalItem::promptRow() const noexcept {
  return prompt_row_;
}

void TerminalItem::holdOutput() {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr || current->screen.modes().alternate_screen) {
    return;
  }
  const auto &screen = current->screen;
  const auto prompt = promptRows(screen, true, liveFrom(current->blocks));
  const auto row = prompt.count == 0 ? static_cast<std::size_t>(screen.cursor().y) : prompt.first;
  held_from_ = static_cast<std::uint64_t>(screen.scroll().offset) + row;
  reveal_rows_ = 0;
  // Never longer than a moment, whatever becomes of the flight.
  hold_limit_.start(400);
  refreshBlocks();
  update();
}

void TerminalItem::releaseOutput() {
  hold_limit_.stop();
  const auto *current = pane();
  const auto held = std::exchange(held_from_, std::nullopt);
  if (!held || current == nullptr) {
    refreshBlocks();
    update();
    return;
  }
  // What arrived while held enters line by line, at most a screen in at most 150 ms; what
  // arrives later is drawn as it comes.
  const auto &screen = current->screen;
  const auto top = static_cast<std::uint64_t>(screen.scroll().offset);
  std::uint64_t rows = 0;
  for (std::size_t row = 0; row < screen.rows() && !screen.modes().alternate_screen; ++row) {
    if (top + row < *held) {
      continue;
    }
    const auto cells = screen.row(row);
    if (std::ranges::any_of(cells, [](const CellValue &cell) { return cell.utf8() != " " && !cell.utf8().empty(); })) {
      rows = top + row - *held + 1;
    }
  }
  if (rows != 0) {
    constexpr qint64 cascade_ms = 150;
    reveal_from_ = *held;
    reveal_rows_ = rows;
    reveal_step_ms_ = std::min<qint64>(12, cascade_ms / static_cast<qint64>(rows));
    reveal_clock_.start();
  }
  refreshBlocks();
  update();
}

void TerminalItem::selectBlock(int index) {
  const auto *current = pane();
  if (current != nullptr && application_ != nullptr && index >= 0 && std::cmp_less(index, current->blocks.size())) {
    application_->selectBlock(pane_id_, static_cast<std::size_t>(index));
  }
}

bool TerminalItem::backgroundProvided() const noexcept {
  return background_provided_;
}

void TerminalItem::setBackgroundProvided(bool provided) {
  if (background_provided_ != provided) {
    background_provided_ = provided;
    update();
    emit backgroundProvidedChanged();
  }
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

  // A command's first lines of output enter one after another, each rising into place.
  revealed_rows_.clear();
  if (reveal_rows_ != 0) {
    constexpr qint64 entrance_ms = 140;
    const auto elapsed = reveal_clock_.elapsed();
    const auto top = static_cast<std::uint64_t>(current->screen.scroll().offset);
    revealed_rows_.assign(current->screen.rows(), 1.0F);
    bool entering = false;
    for (std::size_t row = 0; row < revealed_rows_.size(); ++row) {
      const auto line = top + row;
      if (line >= reveal_from_ && line < reveal_from_ + reveal_rows_) {
        const auto progress = std::clamp(static_cast<float>(elapsed - static_cast<qint64>(line - reveal_from_) * reveal_step_ms_) / entrance_ms, 0.0F, 1.0F);
        revealed_rows_[row] = progress;
        entering |= progress < 1.0F;
      }
    }
    if (entering) {
      QMetaObject::invokeMethod(this, &QQuickItem::update, Qt::QueuedConnection);
    } else {
      reveal_rows_ = 0;
      revealed_rows_.clear();
    }
  }
  static const QString no_preedit;
  const TerminalPresentation frame{
      .screen = current->screen,
      .graphics = current->graphics,
      .configuration = application_->configuration(),
      .font = font_,
      .preedit = application_->editsPrompt(pane_id_) ? no_preedit : preedit_,
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
      .background_provided = background_provided_,
      .hidden_rows = hidden_rows_,
      .revealed_rows = revealed_rows_,
  };
  auto *node = TerminalScene::synchronizeNode(previous, *window(), frame);
  prepared_frame_ = {
      .pane = {.pane_id = current->id, .frame_id = current->screen.frameId(), .attached = current->attached, .attachment_generation = current->attachment_generation, .graphics_revision = current->graphics.revision()},
      .links = prepareLinkPresentation(),
      .revision = prepared_frame_.revision + 1,
  };

  return node;
}

void TerminalItem::bypassInputMethod() noexcept {
  input_method_bypassed_ = true;
}

void TerminalItem::keyPressEvent(QKeyEvent *event) {
  input_method_bypassed_ = false;
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
  } else if (preedit_.isEmpty() && application_->editsPrompt(pane_id_)) {
    // telar's command editor takes the key; the terminal gets what it hands back, and at the
    // prompt nothing the editor cannot use reaches the shell's own line editor.
    QByteArray text;
    const auto key = promptKey(*event, text);
    const bool taken = key && application_->promptKey(pane_id_, *key);
    if (!taken && (key || application_->promptSurface(pane_id_) != prompt::Surface::editor)) {
      static_cast<void>(sendKeyPress(*event, current->screen.modes()));
    }
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
  input_method_bypassed_ = false;
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

    if (application_ == nullptr || !application_->promptText(pane_id_, event->commitString())) {
      sendCommittedText(event->commitString());
    }
  }

  if (std::exchange(preedit_, event->preeditString()) != preedit_) {
    emit preeditChanged();
  }
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
    return current->attached && !input_method_bypassed_;
  case Qt::ImCursorRectangle:
    if (application_ != nullptr && application_->editsPrompt(pane_id_) && prompt_caret_.isValid()) {
      return prompt_caret_;
    }
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
