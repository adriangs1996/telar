#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "terminal_item.hpp"
#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "foundation/core/wheel_accumulator.hpp"
#include "platform/font.h"
#include "platform/window.hpp"
#include "tbc/view.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/panes/terminal/prompt/prompt_keys.hpp"
#include "ui/app/panes/terminal/scene/graphics_scene.hpp"
#include "ui/app/panes/terminal/scene/terminal_scene.hpp"
#include "ui/app/panes/terminal/scene/window_images.hpp"
#include "ui/kit/fonts/resident_fonts.hpp"
#include "ui/kit/fonts/terminal_font.hpp"
#include "ui/kit/fonts/window_font_catalog.hpp"
#include "ui/kit/input/key_adapter.hpp"
#include "ui/kit/input/key_encoding.hpp"
#include <QClipboard>
#include <QDebug>
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
#include <array>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <freetype/freetype.h>
#include <functional>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>
#include <variant>

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  TerminalItem::TerminalItem(QQuickItem* parent)
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

    // At rest, with nothing drawn from them, the rows kept beyond the screen are given back.
    scroll_release_.setSingleShot(true);
    connect(&scroll_release_, &QTimer::timeout, this, [this] {
      if (auto* current = controller_ == nullptr ? nullptr : controller_->sessionMut().findPaneMut(pane_id_); current != nullptr && !motion_.moving() && std::equal_to<>{}(shift_, 0) && current->folds.empty()) {
        current->rows.release();
      }
    });

    connect(this, &QQuickItem::activeFocusChanged, this, &TerminalItem::synchronizeFocus);
    connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow* window) {
      prepared_frame_.pane = {};
      prepared_frame_.links.reset();
      QObject::disconnect(window_activity_connection_);
      if (window != nullptr) {
        WindowImages::forWindow(*window);
        window_activity_connection_ = connect(window, &QWindow::activeChanged, this, &TerminalItem::synchronizeFocus);
      }

      bindScrollClock();
      measure();
    });

    // An item built inside a window already has it, without the change above.
    bindScrollClock();
  }

  void TerminalItem::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged) {
      measure();
    }
  }

  TerminalController* TerminalItem::controller() const noexcept {
    return controller_;
  }

  TerminalItem::~TerminalItem() {
    QObject::disconnect(this, nullptr, this, nullptr);
    QObject::disconnect(window_activity_connection_);
    QObject::disconnect(scroll_frame_connection_);

    if (controller_ != nullptr) {
      controller_->unregisterTerminal(*this);
    }

    try {
      releaseKeys();
      releaseMouse();
    } catch (const std::exception& error) {
      qWarning() << "Unable to release terminal input:" << error.what();
    }
  }

  void TerminalItem::setController(TerminalController* controller) {
    if (controller == controller_) {
      return;
    }

    if (controller_ != nullptr) {
      releaseKeys();
      releaseMouse();
      controller_->unregisterTerminal(*this);
      controller_->disconnect(this);
      controller_->copy().disconnect(this);
      controller_->prompt().disconnect(this);
    }

    // QML owns the controller; this item registers with it and unregisters before it changes.
    controller_ = tbc::raw(controller);
    prepared_frame_.pane = {};
    prepared_frame_.links.reset();
    presented_frame_id_ = 0;
    if (controller_ != nullptr) {
      connect(controller_, &QObject::destroyed, this, [this] {
        controller_ = nullptr;
        update();
        emit controllerChanged();
      });

      connect(controller_, &TerminalController::terminalChanged, this, [this](qulonglong pane_id) {
        if (pane_id == pane_id_) {
          refresh();
        }
      });

      connect(&controller_->prompt(), &PromptController::lineChanged, this, [this](qulonglong pane_id) {
        if (pane_id == pane_id_) {
          refreshBlocks();
          update();
        }
      });

      connect(controller_, &TerminalController::configurationChanged, this, &TerminalItem::measure);
      connect(controller_, &TerminalController::machineChanged, this, &TerminalItem::invalidateMachine);
      connect(controller_, &TerminalController::refreshed, this, &TerminalItem::refreshLinkHover);
      connect(&controller_->copy(), &CopyController::activeChanged, this, &TerminalItem::refreshLinkHover);
      connect(controller_, &TerminalController::dialogChanged, this, &TerminalItem::refreshLinkHover);
      connect(controller_, &TerminalController::pointerModifiersChanged, this, &TerminalItem::refreshLinkHover);
      connect(controller_, &TerminalController::inputReleasing, this, [this](qulonglong pane_id) {
        if (pane_id != pane_id_) {
          return;
        }

        releaseKeys();
        releaseMouse();
        if (const auto* current = pane(); current != nullptr && keyboard_ && current->screen.modes().focus_events) {
          send("\x1b[O", application::PaneInputSource::terminal_report);
        }

        keyboard_ = false;
        preedit_.clear();
      });
    }

    measure();
    if (controller_ != nullptr) {
      controller_->registerTerminal(*this);
    }

    emit controllerChanged();
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

  void TerminalItem::setPaneId(const QString& identity) {
    const auto next = identity.toULongLong();
    if (next == pane_id_) {
      return;
    }

    releaseKeys();
    releaseMouse();
    if (controller_ != nullptr) {
      controller_->unregisterTerminal(*this);
    }

    wheel_.reset();
    pane_id_ = next;
    font_row_revisions_.clear();
    presented_frame_id_ = 0;
    prepared_frame_.pane = {};
    prepared_frame_.links.reset();
    clearLinkHover();
    if (controller_ != nullptr) {
      controller_->registerTerminal(*this);
    }

    ++appearance_;
    refresh();
    emit paneIdChanged();
  }

  const application::Pane<Memory>* TerminalItem::pane() const noexcept {
    return controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
  }

  void TerminalItem::measure() {
    if (controller_ == nullptr) {
      return;
    }

    try {
      link_gesture_.cancel();
      link_stamp_.reset();
      const auto scale = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
      auto resolved = controller_->host().resolveFont(scale);

      font_ = std::move(resolved.font);
      font_grid_ = resolved.grid;
      font_scale_ = scale;
      ++appearance_;
      // The configuration may have changed the editor's mode, and the font the rows' height.
      synchronizeScroll();
      refreshBlocks();
      polish();
      update();
      refreshLinkHover();
    } catch (const std::exception& error) {
      qWarning() << "Terminal font:" << error.what();
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
    if (controller_ == nullptr || window() == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0) {
      return;
    }

    const TerminalGrid grid{.cell_width_px = font_grid_.width, .cell_height_px = font_grid_.height, .scale = font_scale_};
    if (const auto size = grid.fit(width(), height())) {
      controller_->resize(pane_id_, *size);
    }
  }

  void TerminalItem::refresh() {
    synchronizeScroll();
    refreshBlocks();
    markMatches();
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
    auto* catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
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

    if (catalog != nullptr && controller_ != nullptr) {
      catalog->configure(controller_->configuration().font);
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
    if (scroll_frame_requested_ || animating()) {
      advanceScroll();
    }

    const auto* current = pane();
    if (current == nullptr || !font_catalog_) {
      return;
    }

    const auto& screen = current->screen;

    font_row_revisions_.resize(screen.rows());
    for (std::size_t row = 0; row < screen.rows(); ++row) {
      auto& revision = font_row_revisions_[static_cast<qsizetype>(row)];
      if (revision == screen.rowRevision(row)) {
        continue;
      }

      requestRowFonts(*fonts_, *font_catalog_, screen.row(row));
      revision = screen.rowRevision(row);
    }

    // Rows drawn from beyond the screen need their fonts too.
    for (const auto& view : view_rows_) {
      if (view.exists && view.screen_row < 0) {
        if (const auto kept = current->rows.find(current->scrollback_trimmed + view.row)) {
          requestRowFonts(*fonts_, *font_catalog_, kept->cells);
        }
      }
    }

    if (!preedit_.isEmpty()) {
      const auto bytes = preedit_.toUtf8();

      font_catalog_->request({bytes.constData(), static_cast<std::size_t>(bytes.size())}, fonts::FontRole::primary);
    }

    controller_->prepareImagePlacements();
  }

  void TerminalItem::requestRowFonts(ResidentFonts& fonts, WindowFontCatalog& catalog, std::span<const CellValue> cells) {
    const auto& primary = fonts.face(fonts::FontRole::primary);

    for (const auto& cell : cells) {
      if (cell.width == CellWidth::continuation || cell.utf8().empty()) {
        continue;
      }

      try {
        if (!fonts::FontCoverage::covers(primary, cell.utf8())) {
          catalog.request(cell.utf8(), fonts::FontRole::primary);
        }
      } catch (const std::invalid_argument&) {
        const auto normalized = QString::fromUtf8(cell.utf8()).toUtf8();

        catalog.request({normalized.constData(), static_cast<std::size_t>(normalized.size())}, fonts::FontRole::primary);
      }
    }
  }

  void TerminalItem::geometryChange(const QRectF& current, const QRectF& previous) {
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

  void TerminalItem::setPromptCaret(const QRectF& caret) {
    if (prompt_caret_ != caret) {
      prompt_caret_ = caret;
      if (hasActiveFocus()) {
        QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
      }

      emit promptCaretChanged();
    }
  }

  namespace {

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
    PromptRows promptRows(const Screen<Memory>& screen, bool editing, std::uint64_t live_from) {
      const auto rows = static_cast<std::size_t>(screen.rows());
      if (!editing || rows == 0) {
        return {};
      }

      const auto offset = static_cast<std::uint64_t>(screen.scroll().offset);
      const auto bottom = static_cast<std::uint64_t>(copyGrid(screen).maximumOffset());
      const auto& cursor = screen.cursor();
      const bool below = offset < bottom && !cursor.visible;
      const std::size_t last = below ? rows - 1 : cursor.y;
      if (last >= rows) {
        return {};
      }

      constexpr std::size_t search = 8;

      for (std::size_t distance = 0; distance < search && distance <= last; ++distance) {
        const auto row = last - distance;
        if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
          // A prompt above where the last command's rows end is that command's: the shell's state
          // can arrive before the frame with its next prompt, and that one's output is not prompt.
          if (offset + row < live_from) {
            return {};
          }

          // The cursor is at or under the scrollback's live screen, at most `search` rows under its prompt.
          if (below && offset + row + search <= bottom) {
            return {};
          }

          return {.first = row, .count = last - row + 1, .cursor = !below};
        }
      }

      return {};
    }

    // Where the last command's rows end, counted from the top of the scrollback: the live prompt is past it.
    std::uint64_t liveFrom(const auto& blocks) noexcept {
      return blocks.empty() ? 0 : static_cast<std::uint64_t>(blocks.back().row) + blocks.back().rows;
    }

    QString blockState(CommandBlockState state) {
      switch (state) {
      case CommandBlockState::running:
        return QStringLiteral("running");
      case CommandBlockState::succeeded:
        return QStringLiteral("succeeded");
      case CommandBlockState::failed:
        return QStringLiteral("failed");
      case CommandBlockState::session:
        return QStringLiteral("session");
      case CommandBlockState::interrupted:
        break;
      }

      return QStringLiteral("interrupted");
    }

    // The rows drawn: the screen's own, or a view's, scrolled by pixels and folded.
    template <typename ViewRows>
    struct DrawnRows {
      const ViewRows& view_rows;
      bool mapped = false;
      // The screen's first row, counted from the top of the scrollback.
      std::uint64_t top = 0;
      // The screen's rows.
      std::size_t rows = 0;
      std::size_t count = 0;

      // The row drawn at `index`, counted from the top of the scrollback; nothing where the view has none.
      [[nodiscard]] ds::Option<std::uint64_t> absolute(std::size_t index) const noexcept {
        if (!mapped) {
          return top + index;
        }

        return view_rows[index].exists ? ds::Option{view_rows[index].row} : ds::none;
      }

      // Where screen row `screen_row` is drawn, when it is.
      [[nodiscard]] ds::Option<std::size_t> of(std::size_t screen_row) const noexcept {
        if (!mapped) {
          return screen_row < rows ? ds::Option{screen_row} : ds::none;
        }

        for (std::size_t index = 0; index < view_rows.size(); ++index) {
          if (view_rows[index].screen_row >= 0 && std::cmp_equal(view_rows[index].screen_row, screen_row)) {
            return index;
          }
        }

        return ds::none;
      }

      // As `of`, for QML: -1 where the row is not drawn.
      [[nodiscard]] int indexOf(std::size_t screen_row) const noexcept {
        return static_cast<int>(of(screen_row).valueOr(static_cast<std::size_t>(-1)));
      }
    };

    // The lists QML draws the commands' blocks and the documents from.
    struct BlockLists {
      QVariantList separators;
      QVariantList documents;
      QVariantMap document_rows;
      QVariantList rail;
      QVariantList remote_rows;
    };

    // Where the prompt and the cursor are drawn, and how much of the scrollback lies below the view.
    struct RowPlaces {
      int prompt_row = -1;
      int prompt_top = -1;
      int cursor_row = -1;
      int screen_rows = 0;
      int rows_below = 0;
    };

    // The prompt's rows the editor stands in for, left unpainted.
    template <typename ViewRows>
    void hidePrompt(ds::Vec<std::uint8_t, Memory>& hidden, const DrawnRows<ViewRows>& drawn, PromptRows prompt) {
      for (auto row = prompt.first; row < prompt.first + prompt.count && row < drawn.rows; ++row) {
        if (const auto index = drawn.of(row)) {
          hidden.atMut(*index) = 1;
        }
      }
    }

    // The live prompt drawn from rows kept apart from the screen, as while the view glides
    // there: hidden from where it was last seen to start, past the last command's rows.
    template <typename ViewRows>
    void hideLivePrompt(ds::Vec<std::uint8_t, Memory>& hidden, const ViewRows& view_rows, const application::Pane<Memory>& pane) {
      if (!pane.live_prompt_row || *pane.live_prompt_row < liveFrom(pane.blocks)) {
        return;
      }

      for (std::size_t index = 0; index < view_rows.size(); ++index) {
        if (view_rows[index].exists && view_rows[index].screen_row < 0 && view_rows[index].row >= *pane.live_prompt_row) {
          hidden.atMut(index) = 1;
        }
      }
    }

    // The command's own row, where its separator will be, the prompt's first, the cursor's, and
    // the rows below the view.
    template <typename ViewRows>
    RowPlaces rowPlaces(const application::Pane<Memory>& pane, const DrawnRows<ViewRows>& drawn, PromptRows prompt, std::uint64_t top_row) {
      RowPlaces places;

      if (prompt.count != 0 && prompt.cursor) {
        places.prompt_row = drawn.indexOf(prompt.first + prompt.count - 1);
      }

      if (prompt.count != 0) {
        places.prompt_top = drawn.indexOf(prompt.first);
      }

      // On the live screen the cursor is always in view, wherever the program hid it.
      const auto& screen = pane.screen;
      const auto bottom = static_cast<std::uint64_t>(copyGrid(screen).maximumOffset());
      const auto& shown = screen.cursor();
      if (!screen.modes().alternate_screen && (drawn.top >= bottom || shown.visible) && shown.y < drawn.rows) {
        places.cursor_row = drawn.indexOf(shown.y);
      }

      places.screen_rows = static_cast<int>(drawn.rows);
      if (drawn.mapped) {
        const auto total_shown = pane.folds.shownRows(screen.scroll().total_rows);

        places.rows_below = total_shown > top_row + drawn.rows ? static_cast<int>(std::min<std::uint64_t>(total_shown - top_row - drawn.rows, std::numeric_limits<int>::max())) : 0;
      } else {
        places.rows_below = bottom > drawn.top ? static_cast<int>(std::min<std::uint64_t>(bottom - drawn.top, std::numeric_limits<int>::max())) : 0;
      }

      return places;
    }

    // What a command's separator shows beyond the command itself.
    struct SeparatorContext {
      const GuiSession& session;
      std::uint64_t pane_id = 0;
      ds::Option<std::size_t> selected;
      // The first command of the remote session the pane is in: its separators name the host.
      std::size_t live_session = 0;
      const QString& host;
      // Whether the view folds, so that a command's output can fold.
      bool mapped = false;
    };

    // The shell's host, for the separators of the commands run on it.
    QString shellHost(const application::Pane<Memory>& pane) {
      const auto& host = pane.shell.host;

      return host.empty() ? QString{} : QString::fromUtf8(host.data(), static_cast<qsizetype>(host.size()));
    }

    QVariantMap separatorAt(const application::Pane<Memory>& pane, std::size_t index, int row, const SeparatorContext& context) {
      const auto& block = pane.blocks[index];
      const auto [output_first, output_end] = GuiSession::blockRows(pane, index);

      return QVariantMap{
          {QStringLiteral("row"), row},
          {QStringLiteral("command"), QString::fromUtf8(block.command.data(), static_cast<qsizetype>(block.command.size()))},
          {QStringLiteral("lines"), static_cast<int>(block.lines)},
          {QStringLiteral("state"), blockState(block.state)},
          {QStringLiteral("status"), block.status},
          {QStringLiteral("duration"), static_cast<qulonglong>(block.duration_ms)},
          {QStringLiteral("index"), static_cast<int>(index)},
          {QStringLiteral("selected"), context.selected == index},
          {QStringLiteral("folded"), context.session.folded({.pane_id = context.pane_id, .index = index})},
          {QStringLiteral("rows"), static_cast<int>(output_end - output_first)},
          {QStringLiteral("foldable"), context.mapped && output_end > output_first},
          {QStringLiteral("remote"), block.nest == CommandBlockNest::inside},
          {QStringLiteral("host"), index >= context.live_session ? context.host : QString{}},
      };
    }

    // The rail's marks and the separators for the commands the shell ran, their rows painted empty.
    template <typename ViewRows>
    void markCommands(const application::Pane<Memory>& pane, const DrawnRows<ViewRows>& drawn, const SeparatorContext& context, ds::Vec<std::uint8_t, Memory>& hidden, BlockLists& lists) {
      for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
        const auto& block = pane.blocks[index];

        lists.rail.push_back(QVariantMap{{QStringLiteral("state"), blockState(block.state)}, {QStringLiteral("index"), static_cast<int>(index)}, {QStringLiteral("selected"), context.selected == index}});
        const auto begin = static_cast<std::uint64_t>(block.row);
        const auto end = begin + block.rows;

        for (std::size_t drawn_index = 0; drawn_index < drawn.count; ++drawn_index) {
          const auto row = drawn.absolute(drawn_index);
          if (!row || *row < begin || *row >= end) {
            continue;
          }

          hidden.atMut(drawn_index) = 1;
          // On the command's last row: the prompt's other rows stay empty above it, as a margin.
          if (*row == end - 1) {
            lists.separators.push_back(separatorAt(pane, index, static_cast<int>(drawn_index), context));
          }
        }
      }
    }

    // The sessions whose rows are marked, the newest ones.
    constexpr std::size_t session_stretch_capacity = 8;

    // Each session's rows, from its ssh to the end of its last command's output; the one the
    // pane is in runs on to the live end.
    struct SessionStretches {
      ds::Array<std::pair<std::uint64_t, std::uint64_t>, session_stretch_capacity> spans{};
      std::size_t count = 0;
    };

    SessionStretches sessionStretches(const application::Pane<Memory>& pane) {
      SessionStretches stretches;
      const auto& blocks = pane.blocks;

      for (std::size_t index = 0; index < blocks.size();) {
        if (blocks[index].nest == CommandBlockNest::none) {
          ++index;
          continue;
        }

        // From the separator's row, under the margin its prompt left.
        const auto begin = static_cast<std::uint64_t>(blocks[index].row) + blocks[index].rows - 1;
        auto last = index;

        while (last + 1 < blocks.size() && blocks[last + 1].nest == CommandBlockNest::inside) {
          ++last;
        }

        const auto end = last + 1 == blocks.size() && pane.shell.remote ? std::numeric_limits<std::uint64_t>::max() : static_cast<std::uint64_t>(GuiSession::blockRows(pane, last).second);

        if (stretches.count == stretches.spans.size()) {
          // The oldest give way to the newest.
          std::ranges::shift_left(stretches.spans.viewMut(), 1);
          --stretches.count;
        }

        stretches.spans.atMut(stretches.count++) = {begin, end};
        index = last + 1;
      }

      return stretches;
    }

    // The runs of drawn rows inside a session's stretch.
    template <typename ViewRows>
    QVariantList remoteRuns(const SessionStretches& stretches, const DrawnRows<ViewRows>& drawn) {
      QVariantList runs;
      int run_first = -1;
      const auto spans = std::span{stretches.spans}.first(stretches.count);

      for (std::size_t index = 0; stretches.count != 0 && index <= drawn.count; ++index) {
        const auto row = index < drawn.count ? drawn.absolute(index) : ds::none;
        const bool inside = row && std::ranges::any_of(spans, [&](const auto& stretch) {
          return *row >= stretch.first && *row < stretch.second;
        });
        if (inside && run_first < 0) {
          run_first = static_cast<int>(index);
        } else if (!inside && run_first >= 0) {
          runs.push_back(QVariantMap{{QStringLiteral("row"), run_first}, {QStringLiteral("rows"), static_cast<int>(index) - run_first}});
          run_first = -1;
        }
      }

      return runs;
    }

    // Where the view draws the pane's documents.
    struct DocumentPlacement {
      const application::FoldMap<>& folds;
      std::uint64_t top_row = 0;
      std::size_t drawn = 0;
      bool mapped = false;
    };

    // Far enough past either edge to draw a document out of view, and well inside an int.
    constexpr std::int64_t document_start_limit = 1'000'000;

    // Documents drawn in place of the rows they stand for: where each one's display rows start
    // among the drawn rows, its cells left unpainted under it. One the view is yet to measure is
    // listed unplaced, for the view to lay it out and measure it.
    void placeDocuments(const application::Pane<Memory>& pane, const DocumentPlacement& placement, ds::Vec<std::uint8_t, Memory>& hidden, BlockLists& lists) {
      for (const auto& document : pane.inline_documents) {
        if (!document.shown) {
          continue;
        }

        const auto id = static_cast<qulonglong>(document.id);
        const auto first = document.first_row - pane.scrollback_trimmed;
        const auto placed = placement.mapped && document.view_rows != 0 && std::ranges::any_of(placement.folds.spans(), [&](const application::FoldMap<>::Span& span) {
          return span.first == first && span.shown != 0;
        });

        lists.documents.push_back(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("rows"), placed ? static_cast<int>(document.view_rows) : 0}, {QStringLiteral("placed"), placed}});
        if (!placed) {
          continue;
        }

        const auto start = static_cast<std::int64_t>(placement.folds.display(first)) - static_cast<std::int64_t>(placement.top_row);
        const auto end = start + document.view_rows;

        for (auto index = std::max<std::int64_t>(start, 0); index < std::min<std::int64_t>(end, static_cast<std::int64_t>(placement.drawn)); ++index) {
          hidden.atMut(static_cast<std::size_t>(index)) = 1;
        }

        lists.document_rows.insert(QString::number(id), static_cast<int>(std::clamp<std::int64_t>(start, -document_start_limit, document_start_limit)));
      }
    }

    // The selection copy mode draws on the pane, and the cursor it draws in place of the terminal's.
    struct CopyMarks {
      CellSelection selection;
      ds::Option<Cursor> cursor;
    };

    CopyMarks copyMarks(const ds::Option<application::terminal::copy_mode::CopyState>& copy, const application::Pane<Memory>& pane, std::uint64_t pane_id) {
      CopyMarks marks;

      if (!copy || copy->pane_id != pane_id) {
        return marks;
      }

      marks.selection = copy->selection(copyGrid(pane.screen));
      if (!copy->pointer) {
        const auto offset = pane.screen.scroll().offset;

        marks.cursor = Cursor{};
        if (copy->cursor.y >= offset && copy->cursor.y - offset < pane.screen.rows()) {
          marks.cursor = Cursor{.visible = true, .x = copy->cursor.x, .y = static_cast<std::uint16_t>(copy->cursor.y - offset), .shape = CursorShape::block, .blink = false};
        }
      }

      return marks;
    }

    // The rows a view scrolled by pixels or folded draws, from the screen and from the rows kept
    // apart from it.
    template <typename ViewRows>
    void collectDrawnRows(tbc::holds<ds::Vec<TerminalRow, Memory>&, tbc::lt::a> drawn, const ViewRows& view_rows, tbc::ref_a<application::Pane<Memory>> pane) {
      const auto& screen = pane.screen;

      drawn.reserve(view_rows.size());
      constexpr std::uint64_t kept_source = std::uint64_t{1} << 63U;
      constexpr std::uint64_t missing_source = std::uint64_t{1} << 62U;

      for (const auto& view : view_rows) {
        if (!view.exists) {
          drawn.push({.source = missing_source});
        } else if (view.screen_row >= 0 && std::cmp_less(view.screen_row, screen.rows())) {
          const auto row = static_cast<std::size_t>(view.screen_row);

          drawn.push({.cells = screen.row(row), .revision = screen.rowRevision(row), .source = row, .screen_row = view.screen_row});
        } else if (const auto kept = pane.rows.find(pane.scrollback_trimmed + view.row)) {
          drawn.push({.cells = kept->cells, .revision = kept->revision, .source = kept_source | (pane.scrollback_trimmed + view.row)});
        } else {
          drawn.push({.source = missing_source | view.row});
        }
      }
    }

  }

  std::size_t TerminalItem::liveSession(const application::Pane<Memory>& pane) noexcept {
    const auto& blocks = pane.blocks;
    auto first = blocks.size();

    if (!pane.shell.remote) {
      return first;
    }

    while (first > 0 && blocks[first - 1].nest == CommandBlockNest::inside) {
      --first;
    }

    if (first > 0 && blocks[first - 1].nest == CommandBlockNest::opens) {
      --first;
    }

    return first;
  }

  // The rows painted empty, and the separators and rail drawn for the commands the shell ran.
  // Read on the GUI thread whenever the pane or its editor changes, for the next paint.
  void TerminalItem::refreshBlocks() {
    const auto* current = pane();
    BlockLists lists;
    RowPlaces places;

    hidden_rows_.clear();
    if (current != nullptr && controller_ != nullptr) {
      const auto& screen = current->screen;
      const auto rows = static_cast<std::size_t>(screen.rows());
      const bool mapped = mapsRows();
      if (mapped) {
        layoutRows();
      }

      const DrawnRows drawn{
          .view_rows = view_rows_,
          .mapped = mapped,
          .top = static_cast<std::uint64_t>(screen.scroll().offset),
          .rows = rows,
          .count = mapped ? view_rows_.size() : rows,
      };

      hidden_rows_.clear();

      hidden_rows_.resize(drawn.count, 0);
      const bool editing = controller_->prompt().surface(pane_id_) == application::prompt::Surface::editor;
      const auto prompt = promptRows(screen, editing, liveFrom(current->blocks));

      hidePrompt(hidden_rows_, drawn, prompt);
      if (mapped && editing) {
        hideLivePrompt(hidden_rows_, view_rows_, *current);
      }

      places = rowPlaces(*current, drawn, prompt, top_row_);
      const bool telar = controller_->configuration().prompt.mode == PromptMode::telar && current->shell.shell != IntegratedShell::none && !screen.modes().alternate_screen;
      if (telar) {
        const auto host = shellHost(*current);
        const SeparatorContext context{
            .session = controller_->sessionMut(),
            .pane_id = pane_id_,
            .selected = controller_->prompt().selectedBlock(pane_id_),
            .live_session = liveSession(*current),
            .host = host,
            .mapped = mapped,
        };

        markCommands(*current, drawn, context, hidden_rows_, lists);
        lists.remote_rows = remoteRuns(sessionStretches(*current), drawn);
      }

      placeDocuments(*current, {.folds = mapped ? viewFolds() : current->folds, .top_row = top_row_, .drawn = drawn.count, .mapped = mapped}, hidden_rows_, lists);
    }

    if (places.prompt_top != prompt_top_ || places.cursor_row != cursor_row_ || places.screen_rows != rows_ || places.rows_below != rows_below_) {
      prompt_top_ = places.prompt_top;
      cursor_row_ = places.cursor_row;
      rows_ = places.screen_rows;
      rows_below_ = places.rows_below;
      emit placeChanged();
    }

    if (lists.documents != documents_) {
      documents_ = std::move(lists.documents);
      emit documentsChanged();
    }

    if (lists.separators != separators_) {
      QList<QVariantMap> rows;

      rows.reserve(lists.separators.size());
      for (const auto& separator : lists.separators) {
        auto row = separator.toMap();

        row.insert(QStringLiteral("key"), row.value(QStringLiteral("index")));
        rows.append(std::move(row));
      }

      separator_rows_.reconcile(std::move(rows));
    }

    if (lists.separators != separators_ || lists.document_rows != document_rows_ || lists.rail != rail_ || lists.remote_rows != remote_rows_ || places.prompt_row != prompt_row_ || font_.cell != shown_cell_) {
      separators_ = std::move(lists.separators);
      document_rows_ = std::move(lists.document_rows);
      rail_ = std::move(lists.rail);
      remote_rows_ = std::move(lists.remote_rows);
      prompt_row_ = places.prompt_row;
      shown_cell_ = font_.cell;
      emit blocksChanged();
    }

    refreshScrollViews();
  }

  QVariantList TerminalItem::separators() const {
    return separators_;
  }

  QVariantList TerminalItem::rail() const {
    return rail_;
  }

  QVariantList TerminalItem::remoteRows() const {
    return remote_rows_;
  }

  int TerminalItem::promptRow() const noexcept {
    return prompt_row_;
  }

  void TerminalItem::selectBlock(int index) {
    const auto* current = pane();
    if (current != nullptr && controller_ != nullptr && index >= 0 && std::cmp_less(index, current->blocks.size())) {
      controller_->selectBlock(pane_id_, static_cast<std::size_t>(index));
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

  QSGNode* TerminalItem::updatePaintNode(QSGNode* previous, [[maybe_unused]] UpdatePaintNodeData* update_data) {
    const auto* current = pane();
    if (current == nullptr || controller_ == nullptr || window() == nullptr || !font_collection_) {
      prepared_frame_.pane = {};
      prepared_frame_.links.reset();
      const std::unique_ptr<QSGNode> discarded{previous};

      return nullptr;
    }

    auto copy = copyMarks(controller_->copy().state(), *current, pane_id_);

    // Where no key would land, the terminal's cursor is not drawn (see hidesTerminalCursor).
    if (!copy.cursor && controller_->prompt().hidesTerminalCursor(pane_id_)) {
      copy.cursor = Cursor{};
    }

    drawn_rows_.clear();
    const bool mapped = mapsRows();
    if (mapped) {
      layoutRows();
      collectDrawnRows(drawn_rows_, view_rows_, *current);
    }

    revealed_rows_.clear();
    // While a fold opens or closes: the rows below on the moving edge, the output row it
    // crosses fading under it.
    row_offsets_.clear();
    if (mapped && fold_motion_ && fold_from_ >= 0) {
      row_offsets_.clear();
      row_offsets_.resize(view_rows_.size(), 0.0F);
      for (auto row = static_cast<std::size_t>(fold_from_); row < row_offsets_.size(); ++row) {
        row_offsets_.atMut(row) = static_cast<float>(fold_offset_);
      }

      if (fold_fade_row_ >= 0 && std::cmp_less(fold_fade_row_, view_rows_.size())) {
        if (revealed_rows_.empty()) {
          revealed_rows_.clear();
          revealed_rows_.resize(view_rows_.size(), 1.0F);
        }

        auto& revealed = revealed_rows_.atMut(static_cast<std::size_t>(fold_fade_row_));

        revealed = std::min(revealed, fold_fade_);
      }
    }

    [[clang::no_destroy]] static const QString no_preedit;
    const TerminalPresentation frame{
        .screen = current->screen,
        .graphics = current->graphics,
        .configuration = controller_->configuration(),
        .font = font_,
        .preedit = controller_->prompt().edits(pane_id_) ? no_preedit : preedit_,
        .fonts = font_collection_,
        .grid = font_grid_,
        .selection = copy.selection,
        .bounds = boundingRect(),
        .scale = window()->effectiveDevicePixelRatio(),
        .appearance = appearance_,
        .box_stroke = font_grid_.box_stroke,
        .pane_focused = hasActiveFocus(),
        .keyboard = keyboard_,
        .cursor_on = cursor_on_,
        .cursor_override = copy.cursor,
        .hovered_link = link_hover_.current() ? &link_hover_.current()->match : nullptr,
        .owner = this,
        .background_provided = background_provided_,
        .hidden_rows = hidden_rows_.view(),
        .revealed_rows = revealed_rows_.view(),
        .rows = drawn_rows_.view(),
        .shift = mapped ? shift_ : 0,
        .top_row = top_row_,
        .folds = &viewFolds(),
        .view_revision = mapped ? viewRevision(*current) : 0,
        .row_offsets = row_offsets_.view(),
        .matches = match_marks_.view(),
        .link_screen = mapped && link_hover_.current() ? drawnScreen() : nullptr,
    };

    auto* node = TerminalScene::synchronizeNode(previous, *window(), frame);

    prepared_frame_ = {
        .pane = {.pane_id = current->id, .frame_id = current->screen.frameId(), .attached = current->attached, .attachment_generation = current->attachment_generation, .graphics_revision = current->graphics.revision()},
        .links = prepareLinkPresentation(),
        .revision = prepared_frame_.revision + 1,
    };

    return node;
  }

  // Changes whenever the rows drawn do: the screen's, the view's top, its folds, or a row drawn
  // from beyond the screen.
  std::uint64_t TerminalItem::viewRevision(const application::Pane<Memory>& current) const noexcept {
    constexpr std::uint64_t prime = 0x100000001b3;
    auto revision = current.screen.revision();

    for (const auto value : {top_row_, current.fold_revision, static_cast<std::uint64_t>(fold_motion_ ? fold_shown_ + 1 : 0)}) {
      revision = (revision ^ value) * prime;
    }

    for (const auto& row : drawn_rows_) {
      if (row.screen_row < 0) {
        revision = (revision ^ row.source ^ row.revision) * prime;
      }
    }

    return revision;
  }

  void TerminalItem::bypassInputMethod() noexcept {
    input_method_bypassed_ = true;
  }

  void TerminalItem::keyPressEvent(QKeyEvent* event) {
    input_method_bypassed_ = false;
    if (pane() == nullptr || controller_ == nullptr) {
      return;
    }

    // The window's bindings and the views over the pane see the key first; what they leave, the
    // window hands to type().
    controller_->host().pressKey(*this, *event);
    event->accept();
  }

  bool TerminalItem::composing() const noexcept {
    return !preedit_.isEmpty();
  }

  ds::Option<TerminalKey> TerminalItem::type(const QKeyEvent& event) {
    const auto* current = pane();
    ds::Option<TerminalKey> typed;

    if (current == nullptr || controller_ == nullptr) {
      return typed;
    }

    const Qt::KeyboardModifiers clipboard_modifiers = platform::usesCommandKey() ? Qt::ControlModifier : Qt::ControlModifier | Qt::ShiftModifier;
    const auto clipboard_shortcut = (event.modifiers() & (Qt::ControlModifier | Qt::ShiftModifier | Qt::AltModifier | Qt::MetaModifier)) == clipboard_modifiers;
    const auto& copy = controller_->copy().state();
    const auto selected = copy && copy->pane_id == pane_id_ && copy->pointer && copy->anchor;

    if (clipboard_shortcut && event.key() == Qt::Key_C && selected) {
      controller_->copy().copySelection(pane_id_);
    } else if (clipboard_shortcut && event.key() == Qt::Key_V) {
      controller_->paste(pane_id_, QGuiApplication::clipboard()->text());
    } else if (preedit_.isEmpty() && controller_->prompt().edits(pane_id_)) {
      // telar's command editor takes the key; the terminal gets what it hands back, and at the
      // prompt nothing the editor cannot use reaches the shell's own line editor.
      QByteArray text;
      const auto key = promptKey(event, text);
      const bool taken = key && controller_->prompt().key(pane_id_, *key);
      if (!taken && (key || controller_->prompt().surface(pane_id_) != application::prompt::Surface::editor)) {
        typed = sendKeyPress(event, current->screen.modes());
      }
    } else if (preedit_.isEmpty()) {
      typed = sendKeyPress(event, current->screen.modes());
    }

    wakeCursor();

    return typed;
  }

  void TerminalItem::wakeCursor() {
    const bool cursor_changed = !std::exchange(cursor_on_, true);

    if (blink_.isActive()) {
      blink_.start();
    }

    if (cursor_changed) {
      update();
    }
  }

  ds::Option<TerminalKey> TerminalItem::sendKeyPress(const QKeyEvent& event, const InputModes& modes) {
    const auto semantic = NativeKeyAdapter::terminalKey(event);
    const auto bytes = semantic ? encodeKey(*semantic, modes) : encodeKey(event, modes);
    if (bytes.isEmpty()) {
      return ds::none;
    }

    const auto keys = pressed_keys_.viewMut();
    auto entry = std::ranges::find_if(keys, [&](const auto& key) {
      return key.matches(event);
    });
    if (entry == keys.end()) {
      entry = std::ranges::find_if(keys, [](const auto& key) {
        return key.key == 0;
      });
    }

    if (entry == keys.end()) {
      return ds::none;
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

    return send(bytes) ? semantic : ds::none;
  }

  void TerminalItem::keyReleaseEvent(QKeyEvent* event) {
    input_method_bypassed_ = false;
    if (controller_ != nullptr && controller_->host().releaseKey(*this, *event)) {
      event->accept();

      return;
    }

    const auto* current = pane();
    const auto keys = pressed_keys_.viewMut();
    const auto entry = std::ranges::find_if(keys, [&](const auto& key) {
      return key.matches(*event);
    });
    if (current != nullptr && entry != keys.end() && !event->isAutoRepeat()) {
      const auto released = std::exchange(*entry, PressedKey{});

      send(released.release(current->screen.modes()), application::PaneInputSource::key_release);
    }

    event->accept();
  }

  void TerminalItem::inputMethodEvent(QInputMethodEvent* event) {
    if (!event->commitString().isEmpty()) {
      if (controller_ != nullptr) {
        controller_->host().interruptKeys();
      }

      if (controller_ == nullptr || !controller_->prompt().text(pane_id_, event->commitString())) {
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

  void TerminalItem::sendCommittedText(const QString& text) {
    if (controller_ == nullptr || !controller_->copy().active()) {
      send(text.toUtf8());

      return;
    }

    for (qsizetype offset = 0; offset < text.size();) {
      const auto paired = text[offset].isHighSurrogate() && offset + 1 < text.size() && text[offset + 1].isLowSurrogate();
      const auto length = paired ? 2 : 1;
      const auto scalar = QString::fromRawData(QStringView{text}.sliced(offset, length).constData(), length);
      const QKeyEvent key{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, scalar};

      static_cast<void>(controller_->copy().handleKey(pane_id_, key));
      offset += length;
    }
  }

  QVariant TerminalItem::inputMethodQuery(Qt::InputMethodQuery query) const {
    const auto* current = pane();
    if (current == nullptr) {
      return {};
    }

    const auto& cursor = current->screen.cursor();

    switch (query) {
    case Qt::ImEnabled:
      return current->attached && !input_method_bypassed_;
    case Qt::ImCursorRectangle:
      if (controller_ != nullptr && controller_->prompt().edits(pane_id_) && prompt_caret_.isValid()) {
        return prompt_caret_;
      }

      return QRectF{cursor.x * font_.cell.width(), cursor.y * font_.cell.height(), font_.cell.width(), font_.cell.height()};
    case Qt::ImFont:
      return font_.faces[0];
    case Qt::ImHints:
      return static_cast<int>(Qt::ImhNoPredictiveText | Qt::ImhNoAutoUppercase);
    case Qt::ImCursorPosition:
    case Qt::ImSurroundingText:
    case Qt::ImCurrentSelection:
    case Qt::ImMaximumTextLength:
    case Qt::ImAnchorPosition:
    case Qt::ImPreferredLanguage:
    case Qt::ImAbsolutePosition:
    case Qt::ImTextBeforeCursor:
    case Qt::ImTextAfterCursor:
    case Qt::ImEnterKeyType:
    case Qt::ImAnchorRectangle:
    case Qt::ImInputItemClipRectangle:
    case Qt::ImReadOnly:
    case Qt::ImPlatformData:
    case Qt::ImQueryInput:
    case Qt::ImQueryAll:
      return QQuickItem::inputMethodQuery(query);
    }

    // Qt answers a query outside the enum, such as a combination of queries.
    return QQuickItem::inputMethodQuery(query);
  }

  void TerminalItem::focusInEvent(QFocusEvent* event) {
    QQuickItem::focusInEvent(event);
    synchronizeFocus();
  }

  void TerminalItem::focusOutEvent(QFocusEvent* event) {
    QQuickItem::focusOutEvent(event);
    synchronizeFocus();
  }

  void TerminalItem::synchronizeFocus() {
    const auto* current = pane();
    const auto window_active = window() != nullptr && window()->isActive();
    const auto keyboard = hasActiveFocus() && window_active;
    if (keyboard != keyboard_) {
      keyboard_ = keyboard;
      if (current != nullptr && current->screen.modes().focus_events) {
        send(keyboard ? "\x1b[I" : "\x1b[O", application::PaneInputSource::terminal_report);
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

    const auto blinks = keyboard && current != nullptr && !controller_->copy().active() && current->screen.cursor().visible && current->screen.cursor().blink && (current->screen.cursor().shape != CursorShape::default_shape || controller_->configuration().cursor_blink);
    if (blinks) {
      blink_.setInterval(static_cast<int>(controller_->configuration().blink_interval.count()));
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
    const auto* current = pane();

    // By index: sending re-enters this item, so no borrow of the keys is held across it.
    for (std::size_t index = 0; index < pressed_keys_.size(); ++index) {
      if (pressed_keys_[index].key == 0) {
        continue;
      }

      const auto held = std::exchange(pressed_keys_.atMut(index), PressedKey{});

      if (current != nullptr) {
        send(held.release(current->screen.modes()), application::PaneInputSource::key_release);
      }
    }
  }

  QByteArray TerminalItem::PressedKey::release(const InputModes& modes) const {
    if (semantic) {
      auto release = *semantic;

      release.phase = KeyPhase::release;

      return encodeKey(release, modes);
    }

    const QKeyEvent release{QEvent::KeyRelease, key, modifiers, scan, native_key, native_modifiers, text};

    return encodeKey(release, modes);
  }

  bool TerminalItem::send(const QByteArray& bytes, application::PaneInputSource source) {
    return controller_ != nullptr && !bytes.isEmpty() && controller_->input(pane_id_, bytes, source);
  }

}
