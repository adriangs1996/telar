module telar.gui.ui.app.panes.nvim;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.cell_scene;
import telar.gui.ui.kit.scene;
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
    editorChanged();
  }

  void NvimGridItem::setGridId(int grid_id) {
    const auto next = grid_id < 0 ? 0U : static_cast<std::uint32_t>(grid_id);
    if (grid_id_ == next) {
      return;
    }

    grid_id_ = next;
    font_row_revisions_.clear();
    refresh();
    gridIdChanged();
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
    if (!counting_) {
      frames_ = connect(window(), &QQuickWindow::afterAnimating, this, &NvimGridItem::advance);
      counting_ = true;
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
    counting_ = false;
    if (!drawn_rows_.isEmpty() || clip()) {
      drawn_rows_.clear();
      shift_ = 0;
      setClip(false);
      update();
    }
  }

  namespace {

    // How far a grid's rows are from their places, in pixels, and the height of one.
    struct Slide {
      double offset = 0;
      double row_height = 0;
    };

    // The rows a slide draws, top first: the grid's own and the ones that left it, which come
    // back into view ahead of them. Returns how far above their places they are drawn, or
    // nothing drawn when the grid's own rows stand in their places.
    double slideRows(tbc::holds<QList<TerminalRow>&, tbc::lt::a> drawn, tbc::ref_a<application::nvim::Grid> grid, Slide slide) {
      const auto& screen = grid.screen;
      const auto& departed = grid.departed;
      // Rows that came up slide over the ones that left above them, and the other way around: a
      // slide the other way has no rows to show.
      constexpr double in_place = 0.01;
      const auto distance = std::min(std::abs(slide.offset), static_cast<double>(departed.count) * slide.row_height);

      if (distance < in_place || slide.row_height <= 0 || (slide.offset > 0) != departed.above) {
        return 0;
      }

      constexpr std::uint64_t departed_source = std::uint64_t{1} << 63U;
      const auto rows = static_cast<std::size_t>(screen.rows());
      const auto whole = static_cast<std::size_t>(std::ceil(distance / slide.row_height));
      const auto first = static_cast<std::size_t>(std::floor(distance / slide.row_height));

      drawn.reserve(static_cast<qsizetype>(rows) + 1);
      if (departed.above) {
        for (auto index = whole; index-- > 0;) {
          drawn.append({.cells = departed.row(index), .revision = departed.stamp(index), .source = departed_source});
        }
      }

      for (auto row = departed.above ? 0 : first; row < (departed.above ? std::min(rows, rows - whole + 1) : rows); ++row) {
        drawn.append({.cells = screen.row(row), .revision = screen.rowRevision(row), .source = row, .screen_row = static_cast<std::int32_t>(row)});
      }

      if (!departed.above) {
        for (std::size_t index = 0; index < whole; ++index) {
          drawn.append({.cells = departed.row(index), .revision = departed.stamp(index), .source = departed_source});
        }
      }

      return departed.above ? (static_cast<double>(whole) * slide.row_height) - distance : distance - (static_cast<double>(first) * slide.row_height);
    }

  }

  void NvimGridItem::composeRows() {
    // The grid is the editor's, not this item's: the rows drawn view its cells.
    const auto* shown = editor_ == nullptr ? nullptr : editor_->editorState();
    const auto* current = shown == nullptr ? nullptr : shown->grid(grid_id_);

    drawn_rows_.clear();
    shift_ = 0;
    if (current != nullptr && motion_.moving()) {
      shift_ = slideRows(drawn_rows_, *current, {.offset = motion_.position() - reach_, .row_height = editor_->cellHeight()});
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

    ds::Option<Drawn> next;

    if (current != nullptr && editor_ != nullptr) {
      const auto* shown = editor_->editorState();
      const bool base = grid_id_ == 1;

      next = Drawn{
          .revision = current->screen.revision(),
          .appearance = editor_->appearance(),
          .layout = base ? shown->layout_revision : 0,
          .status_row = base && shown->status_row ? static_cast<std::int32_t>(*shown->status_row) : -1,
      };
    }

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

  namespace {

    // The default grid's rows into `rows`, with the cells the window does not draw from it left
    // empty, so the pane's own background shows there as under a terminal's cells. A row
    // covered in part is drawn from a copy in `copies`, one covered whole from `blank`; `flags`
    // holds the covered cells of one row.
    void coverRows(tbc::holds<QList<TerminalRow>&, tbc::lt::a> rows, const application::nvim::Editor& editor, tbc::ref_a<application::nvim::Grid> base, tbc::mut_a<QList<CellValue>> copies, tbc::mut_a<QList<CellValue>> blank, QList<Byte>& flags) { // NOLINT(readability-function-size): the rows lend from the copies and the blank row, each a borrow of its own
      const auto& screen = base.screen;
      const auto count = static_cast<std::size_t>(screen.rows());
      const auto columns = static_cast<std::size_t>(screen.columns());
      // A row covered in part is drawn again whenever what covers it changes: its revision is
      // the screen's, mixed with the cells covered.
      const auto mixed = [](std::uint64_t revision, std::span<const Byte> covered) {
        // FNV-1a's offset and prime.
        constexpr std::uint64_t offset = 0xcbf2'9ce4'8422'2325ULL;
        constexpr std::uint64_t prime = 0x0000'0100'0000'01b3ULL;
        std::uint64_t hash = offset;

        for (const auto flag : covered) {
          hash = (hash ^ flag) * prime;
        }

        return revision ^ (hash | 1U);
      };

      // A row covered whole draws as the one empty row, whatever Neovim left on it.
      constexpr std::uint64_t blank_revision = std::numeric_limits<std::uint64_t>::max();

      flags.resize(static_cast<qsizetype>(columns));
      blank.resize(static_cast<qsizetype>(columns));
      rows.reserve(static_cast<qsizetype>(count));

      const std::span<Byte> covered{flags};
      const auto covered_count = [&] {
        return static_cast<std::size_t>(std::ranges::count(covered, Byte{1}));
      };

      std::size_t partial = 0;

      for (std::size_t row = 0; row < count; ++row) {
        application::nvim::coverDefaultRow(editor, row, covered);

        const auto cells = covered_count();

        partial += cells != 0 && cells != columns ? 1 : 0;
      }

      // Each copy keeps its place while the rows are drawn: the copies are made once there is
      // room for all of them.
      copies.resize(static_cast<qsizetype>(partial) * static_cast<qsizetype>(columns));

      std::size_t copied = 0;

      for (std::size_t row = 0; row < count; ++row) {
        application::nvim::coverDefaultRow(editor, row, covered);

        const auto cells = screen.row(row);
        const auto hidden = covered_count();
        TerminalRow drawn{.cells = cells, .revision = screen.rowRevision(row), .source = row, .screen_row = static_cast<std::int32_t>(row)};

        if (hidden == columns) {
          drawn.cells = std::span<const CellValue>{std::as_const(blank)};
          drawn.revision = blank_revision;
        } else if (hidden != 0) {
          const auto copy = std::span<CellValue>{copies}.subspan(copied++ * columns, columns);

          for (std::size_t column = 0; column < columns; ++column) {
            copy[column] = covered[column] != 0 || column >= cells.size() ? CellValue{} : cells[column];
          }

          drawn.cells = copy;
          drawn.revision = mixed(drawn.revision, covered);
        }

        rows.append(drawn);
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

    // The default grid keeps what Neovim drew under its windows; the window draws the
    // separators and the status line itself. None of that is drawn from its cells. A slide
    // draws its own rows.
    QList<TerminalRow> covered;

    if (grid_id_ == 1 && drawn_rows_.isEmpty()) {
      coverRows(covered, *editor_->editorState(), *current, covered_cells_, blank_row_, covered_);
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
        // The pane draws the cursor in a layer of its own, which moves and blinks without the
        // cells being drawn again.
        .pane_focused = true,
        .keyboard = editor_->hasActiveFocus(),
        .cursor_on = false,
        .owner = this,
        // The pane, or the float's own surface, is behind the cells that have no color.
        .background_provided = true,
        .rows = std::span<const TerminalRow>{std::as_const(covered.isEmpty() ? drawn_rows_ : covered)},
        .shift = shift_,
    };

    return TerminalScene::synchronizeNode(previous, *window(), frame);
  }

}
