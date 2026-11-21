#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "nvim_grid_item.hpp"
#include "ui/kit/cell_scene/terminal_scene.hpp"
#include "ui/kit/scene/window_animation_clock.hpp"
#include <QQuickWindow>
#include <QSGNode>
#include <algorithm>
#include <cmath>
#include <memory>
#include <span>

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  NvimGridItem::NvimGridItem(QQuickItem* parent)
      : QQuickItem(parent) {
    setFlag(ItemHasContents);
  }

  void NvimGridItem::setEditor(NvimItem* editor) {
    if (editor_ == editor) {
      return;
    }

    if (editor_ != nullptr) {
      disconnect(editor_, nullptr, this, nullptr);
    }

    editor_ = editor;
    if (editor_ != nullptr) {
      connect(editor_, &NvimItem::frameShown, this, &NvimGridItem::refresh);
    }

    refresh();
    emit editorChanged();
  }

  void NvimGridItem::setGridId(int grid_id) {
    const auto next = grid_id < 0 ? 0U : static_cast<std::uint32_t>(grid_id);
    if (grid_id_ == next) {
      return;
    }

    grid_id_ = next;
    font_row_revisions_.clear();
    refresh();
    emit gridIdChanged();
  }

  const application::nvim::Grid* NvimGridItem::grid() const noexcept {
    const auto* shown = editor_ == nullptr ? nullptr : editor_->editorState();

    return shown == nullptr ? nullptr : shown->grid(grid_id_);
  }

  ScrollTime NvimGridItem::now() const {
    return {.nanoseconds = window() == nullptr ? 0 : static_cast<std::int64_t>(WindowAnimationClock::forWindow(*window()).now())};
  }

  void NvimGridItem::itemChange(ItemChange change, const ItemChangeData& data) {
    // The frames a slide counts are its window's.
    if (change == ItemSceneChange) {
      rest();
    }

    QQuickItem::itemChange(change, data);
  }

  void NvimGridItem::slide(double distance, const application::nvim::Grid& current) {
    const auto reach = static_cast<double>(current.screen.rows()) * editor_->cellHeight();
    const auto from = motion_.moving() ? motion_.position() - reach_ : 0.0;

    // A view each way is as far as rows are kept to slide.
    reach_ = reach;
    motion_.tune({.wheel_ms = static_cast<double>(editor_->controller()->configuration().scroll.wheel_ms)});
    motion_.setLimit(2 * reach);
    motion_.place(reach + from + distance);
    motion_.wheel(reach - motion_.position(), now());
    if (!motion_.moving()) {
      rest();
      return;
    }

    setClip(true);
    if (!frames_) {
      frames_ = connect(window(), &QQuickWindow::afterAnimating, this, &NvimGridItem::advance);
    }

    composeRows();
    window()->update();
  }

  void NvimGridItem::advance() {
    if (!motion_.advance(now()) || !isVisible()) {
      rest();
      return;
    }

    composeRows();
    update();
    window()->update();
  }

  void NvimGridItem::rest() {
    motion_.stop();
    disconnect(frames_);
    frames_ = {};
    if (!drawn_rows_.isEmpty() || clip()) {
      drawn_rows_.clear();
      shift_ = 0;
      setClip(false);
      update();
    }
  }

  void NvimGridItem::composeRows() {
    const auto* current = grid();

    drawn_rows_.clear();
    shift_ = 0;
    if (current == nullptr || editor_ == nullptr || !motion_.moving()) {
      return;
    }

    const auto& screen = current->screen;
    const auto& departed = current->departed;
    const auto height = editor_->cellHeight();
    const auto offset = motion_.position() - reach_;
    // Rows that came up slide over the ones that left above them, and the other way around: a
    // slide the other way has no rows to show, and the grid's own stand in their places.
    constexpr double in_place = 0.01;
    const auto distance = std::min(std::abs(offset), static_cast<double>(departed.count) * height);

    if (distance < in_place || height <= 0 || (offset > 0) != departed.above) {
      return;
    }

    constexpr std::uint64_t departed_source = std::uint64_t{1} << 63U;
    const auto rows = static_cast<std::size_t>(screen.rows());
    const auto whole = static_cast<std::size_t>(std::ceil(distance / height));
    const auto own = [&](std::size_t row) {
      drawn_rows_.append({.cells = screen.row(row), .revision = screen.rowRevision(row), .source = row, .screen_row = static_cast<std::int32_t>(row)});
    };
    const auto gone = [&](std::size_t index) {
      drawn_rows_.append({.cells = departed.row(index), .revision = departed.stamp(index), .source = departed_source});
    };

    drawn_rows_.reserve(static_cast<qsizetype>(rows + 1));
    if (departed.above) {
      shift_ = (static_cast<double>(whole) * height) - distance;
      for (auto index = whole; index-- > 0;) {
        gone(index);
      }

      for (std::size_t row = 0; row < std::min(rows, rows - whole + 1); ++row) {
        own(row);
      }

      return;
    }

    const auto first = static_cast<std::size_t>(std::floor(distance / height));

    shift_ = distance - (static_cast<double>(first) * height);
    for (auto row = first; row < rows; ++row) {
      own(row);
    }

    for (std::size_t index = 0; index < whole; ++index) {
      gone(index);
    }
  }

  void NvimGridItem::refresh() {
    const auto* current = grid();

    if (current == nullptr || editor_ == nullptr) {
      moved_seen_ = ds::none;
      rest();
    } else {
      const auto moved = current->departed.moved;
      const auto before = moved_seen_.valueOr(moved);

      moved_seen_ = moved;
      // The setting a terminal's rows follow: without it they arrive at once.
      if (moved != before && isVisible() && window() != nullptr && editor_->controller() != nullptr && editor_->controller()->configuration().scroll.smooth) {
        slide(static_cast<double>(moved - before) * editor_->cellHeight(), *current);
      } else if (motion_.moving()) {
        // The rows drawn view the grid's cells, which this frame changed.
        composeRows();
      }
    }
    const ds::Option<Drawn> next = current == nullptr || editor_ == nullptr ? ds::Option<Drawn>{} : Drawn{.revision = current->screen.revision(), .appearance = editor_->appearance(), .cursor_on = editor_->cursorOn(), .keyboard = editor_->hasActiveFocus()};

    // Most frames change one grid: the others keep what they drew.
    if (next == drawn_ && next) {
      return;
    }

    drawn_ = next;
    polish();
    update();
  }

  // The fonts of the rows that changed are asked for before they are drawn, as a terminal's.
  void NvimGridItem::updatePolish() {
    const auto* current = grid();
    if (current == nullptr || editor_ == nullptr) {
      return;
    }

    if (font_appearance_ != editor_->appearance()) {
      font_appearance_ = editor_->appearance();
      font_row_revisions_.clear();
    }

    const auto& screen = current->screen;

    font_row_revisions_.resize(screen.rows());
    for (std::size_t row = 0; row < screen.rows(); ++row) {
      auto& revision = font_row_revisions_[static_cast<qsizetype>(row)];
      if (revision != screen.rowRevision(row)) {
        editor_->requestFonts(screen.row(row));
        revision = screen.rowRevision(row);
      }
    }
  }

  QSGNode* NvimGridItem::updatePaintNode(QSGNode* previous, [[maybe_unused]] UpdatePaintNodeData* data) {
    const auto* current = grid();
    const auto* pane = editor_ == nullptr ? nullptr : editor_->pane();
    if (current == nullptr || pane == nullptr || editor_->controller() == nullptr || window() == nullptr || !editor_->fontCollection() || current->screen.columns() == 0) {
      const std::unique_ptr<QSGNode> discarded{previous};

      return nullptr;
    }

    [[clang::no_destroy]] static const QString no_preedit;
    const TerminalPresentation frame{
        .screen = current->screen,
        // An editor shows no images: its pane's store is the empty one a scene asks for.
        .graphics = pane->graphics,
        .configuration = editor_->controller()->configuration(),
        .font = editor_->font(),
        .preedit = no_preedit,
        .fonts = editor_->fontCollection(),
        .grid = editor_->fontGrid(),
        // A slide draws one row past the grid's last, partly shown, which the item clips.
        .bounds = drawn_rows_.isEmpty() ? boundingRect() : boundingRect().adjusted(0, 0, 0, editor_->cellHeight()),
        .scale = window()->effectiveDevicePixelRatio(),
        .appearance = editor_->appearance(),
        .box_stroke = editor_->fontGrid().box_stroke,
        // The cursor is Neovim's to show or hide; without the keyboard it is drawn hollow.
        .pane_focused = true,
        .keyboard = editor_->hasActiveFocus(),
        .cursor_on = editor_->cursorOn(),
        .owner = this,
        // The pane, or the float's own surface, is behind the cells that have no color.
        .background_provided = true,
        .rows = std::span<const TerminalRow>{drawn_rows_.constData(), static_cast<std::size_t>(drawn_rows_.size())},
        .shift = shift_,
    };

    return TerminalScene::synchronizeNode(previous, *window(), frame);
  }

}
