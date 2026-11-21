#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "nvim_grid_item.hpp"
#include "ui/kit/cell_scene/terminal_scene.hpp"
#include <QQuickWindow>
#include <QSGNode>
#include <memory>

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

  void NvimGridItem::refresh() {
    const auto* current = grid();
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
        .bounds = boundingRect(),
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
    };

    return TerminalScene::synchronizeNode(previous, *window(), frame);
  }

}
