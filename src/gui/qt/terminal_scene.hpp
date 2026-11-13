#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "../application/dependencies.hpp"
#include "cell_glyphs.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <concepts>
#include <utility>
#include "graphics_scene.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/cell_position.hpp"
#include "../terminal/screen.hpp"
#include "text_scene.hpp"
#include "terminal_font.hpp"
#include <QList>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleRectNode>
#include <QSGTransformNode>
#include <QString>

#pragma once

#include "application/dependencies.hpp"
#include "terminal/screen.hpp"


import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.graphics.texture_cache;
import telar.gui.links.cell_links;
import telar.gui.terminal.copy_mode;

namespace telar::gui::qt {

// A row a scrolled or folded view draws: the screen's own row `screen_row`, or a row the
// runtime sent apart from the screen (`screen_row` -1). `source` names where it came from and
// `revision` its content there, so a painter knows when the row it drew is another.
struct TerminalRow {
  std::span<const CellValue> cells;
  std::uint64_t revision = 0;
  std::uint64_t source = 0;
  std::int32_t screen_row = -1;
};

// A search match drawn: on drawn row `row`, `length` cells from `column`; `current` is the one
// the copy-mode cursor is on.
struct MatchMark {
  std::size_t row = 0;
  std::uint16_t column = 0;
  std::uint16_t length = 0;
  bool current = false;

  bool operator==(const MatchMark &) const = default;
};

struct TerminalPresentation {
  const Screen<ApplicationAllocator> &screen;
  const GraphicsStore<ApplicationAllocator> &graphics;
  const Configuration &configuration;
  const TerminalFont &font;
  const QString &preedit;
  std::shared_ptr<const FontCollection> fonts;
  FontGrid grid;
  CellSelection selection;
  QRectF bounds;
  qreal scale = 1;
  std::uint64_t appearance = 0;
  std::optional<float> box_stroke = std::nullopt;
  bool pane_focused = false;
  bool keyboard = false;
  bool cursor_on = true;
  std::optional<Cursor> cursor_override = std::nullopt;
  const LinkMatch *hovered_link = nullptr;
  QQuickItem *owner = nullptr;
  bool background_provided = false;
  // Rows painted empty, one flag per row: the shell's own prompt while telar's editor stands
  // in for it, and the prompts of the commands it ran, which their separators stand in for.
  std::span<const std::uint8_t> hidden_rows{};
  // How far each row has come into view, 0 to 1, while a command's first lines of output
  // enter one after another; empty when every row is in place.
  std::span<const float> revealed_rows{};
  // The rows drawn, top first, when they are not the screen's: a view scrolled by pixels draws
  // a row past the screen's last, and a folded view rows from wherever its folds leave them.
  // Empty: the screen's rows, one for one. The hidden and revealed rows count these rows.
  std::span<const TerminalRow> rows;
  // How far the rows are drawn above their places, in logical pixels: the part of the top row
  // the view scrolled past.
  qreal shift = 0;
  // Where images go: the view's top shown row, the active screen's first row, the folds, and a
  // revision that changes with any of them or with the rows drawn. Without folds and with the
  // screen's own top, as the screen shows its rows.
  std::uint64_t top_row = 0;
  std::uint64_t live_top = 0;
  const FoldMap<> *folds = nullptr;
  std::uint64_t view_revision = 0;
  // While a fold opens or closes, how far below its place each drawn row is; empty otherwise.
  std::span<const float> row_offsets;
  // The scrollback search's matches on the drawn rows.
  std::span<const MatchMark> matches;
  // The drawn rows as a screen of their own, which a hovered link's cells are counted on while
  // the view draws its own rows.
  const Screen<ApplicationAllocator> *link_screen = nullptr;

  [[nodiscard]] std::size_t rowCount() const noexcept {
    return rows.empty() ? screen.rows() : rows.size();
  }

  [[nodiscard]] std::span<const CellValue> row(std::size_t index) const noexcept {
    if (rows.empty()) {
      return screen.row(index);
    }
    return index < rows.size() ? rows[index].cells : std::span<const CellValue>{};
  }

  [[nodiscard]] std::uint64_t rowRevision(std::size_t index) const noexcept {
    if (rows.empty()) {
      return screen.rowRevision(index);
    }
    return index < rows.size() ? rows[index].revision : 0;
  }

  [[nodiscard]] std::uint64_t rowSource(std::size_t index) const noexcept {
    if (rows.empty()) {
      return index;
    }
    return index < rows.size() ? rows[index].source : 0;
  }

  // The screen row drawn at `index`, if it is one of the screen's.
  [[nodiscard]] std::optional<std::size_t> screenRow(std::size_t index) const noexcept {
    if (rows.empty()) {
      return index;
    }
    if (index >= rows.size() || rows[index].screen_row < 0) {
      return std::nullopt;
    }
    return static_cast<std::size_t>(rows[index].screen_row);
  }

  // Where the screen's row `screen_row` is drawn, if it is.
  [[nodiscard]] std::optional<std::size_t> drawnRow(std::size_t screen_row) const noexcept {
    if (rows.empty()) {
      return screen_row;
    }
    for (std::size_t index = 0; index < rows.size(); ++index) {
      if (std::cmp_equal(rows[index].screen_row, screen_row)) {
        return index;
      }
    }
    return std::nullopt;
  }

  // Whether the cell at `cell.x` of drawn row `cell.y` is selected.
  [[nodiscard]] bool selected(CellPosition cell) const noexcept {
    const auto screen_row = screenRow(cell.y);
    return screen_row && selection.contains((*screen_row * screen.columns()) + cell.x);
  }

  [[nodiscard]] bool hidden(std::size_t row) const noexcept {
    return row < hidden_rows.size() && hidden_rows[row] != 0;
  }

  [[nodiscard]] float revealed(std::size_t row) const noexcept {
    return row < revealed_rows.size() ? revealed_rows[row] : 1.0F;
  }

  // How far below its place drawn row `row` is while a fold opens or closes, in logical pixels.
  [[nodiscard]] float offset(std::size_t row) const noexcept {
    return row < row_offsets.size() ? row_offsets[row] : 0.0F;
  }
};

class TerminalScene final : public QSGTransformNode {
public:
  explicit TerminalScene(QQuickWindow &window);
  ~TerminalScene() override;
  TerminalScene(const TerminalScene &) = delete;
  TerminalScene &operator=(const TerminalScene &) = delete;
  TerminalScene(TerminalScene &&) = delete;
  TerminalScene &operator=(TerminalScene &&) = delete;

  void synchronize(QQuickWindow &window, const TerminalPresentation &frame);
  // The result reuses the previous node or is a new one the caller adopts.
  static tbc::view<QSGNode *, tbc::lt::a> synchronizeNode(tbc::view<QSGNode *, tbc::lt::a> previous, QQuickWindow &window, const TerminalPresentation &frame);

private:
  struct Row {
    QSGTransformNode *text = nullptr;
    QSGTransformNode *background = nullptr;
    QSGOpacityNode *text_opacity = nullptr;
    QSGOpacityNode *background_opacity = nullptr;
    float revealed = 1.0F;
    float offset = 0;
    QSGNode *text_content = nullptr;
    std::uint64_t revision = 0;
    std::uint64_t appearance = 0;
    CellSelection selection{};
    std::optional<std::size_t> cursor = std::nullopt;
    std::uint64_t source = 0;
    bool hidden = false;
  };

  void synchronizeGrid(CellRectangle visible);
  void paintRow(const TerminalPresentation &frame, std::size_t row_index);
  void paintCursor(const TerminalPresentation &frame);
  void paintPreedit(const TerminalPresentation &frame);
  void paintHoveredLink(const TerminalPresentation &frame);
  void paintMatches(const TerminalPresentation &frame);

  QQuickWindow &window_;
  // The layers are this node's children, and the images draw into them.
  tbc::view<QSGSimpleRectNode &, tbc::lt::self> background_;
  tbc::view<QSGTransformNode &, tbc::lt::self> below_background_;
  tbc::view<QSGTransformNode &, tbc::lt::self> cell_backgrounds_;
  // Search matches, lit over the cells' backgrounds and under their text.
  tbc::view<QSGTransformNode &, tbc::lt::self> matches_;
  tbc::view<QSGTransformNode &, tbc::lt::self> below_text_;
  tbc::view<QSGTransformNode &, tbc::lt::self> rows_;
  tbc::view<QSGTransformNode &, tbc::lt::self> above_text_;
  tbc::view<QSGTransformNode &, tbc::lt::self> overlay_;
  tbc::view<GraphicsScene, tbc::lt::self> images_;
  CellGlyphs glyphs_;
  TextScene text_;
  TextScene overlay_text_;
  QList<Row> row_nodes_;
  QRectF bounds_;
  std::uint16_t columns_ = 0;
  std::uint64_t appearance_ = 0;
  qreal scale_ = 0;
  // The layers' offset as last set: the rows' shift.
  qreal shift_ = 0;
  // The cells of each row drawn, for the images their placeholders show.
  std::vector<std::span<const CellValue>> drawn_cells_;
  // The matches as last lit, with the row offsets they were lit at.
  std::vector<MatchMark> lit_matches_;
  std::vector<float> lit_offsets_;
  QRectF lit_bounds_;
};
}
