#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "terminal_scene.hpp"
#include <QMatrix4x4>
#include "cell_glyphs.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "../core/terminal_size.hpp"
#include <span>
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/cell_position.hpp"
#include "../terminal/screen.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "projection.hpp"
#include "scene_nodes.hpp"
#include <bit>
#include <stdexcept>
#include "terminal_decorations.hpp"
#include "text_scene.hpp"
#include <QPointF>
#include <QRectF>
#include <QString>
#include <QTextCharFormat>
#include <QtCore/qchar.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <QtGui/qcolor.h>
#include <QtQuick/qquickwindow.h>
#include <QtQuick/qsggeometry.h>
#include <QtQuick/qsgnode.h>
#include <QtQuick/qsgsimplerectnode.h>
#include <cmath>
#include <memory>
#include <utility>

#include "core/terminal_size.hpp"
#include "terminal/screen.hpp"


import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.core.json_writer;
import telar.gui.fonts.face;
import telar.gui.links.path_expansion;
import telar.gui.links.link_hover;
import telar.gui.terminal.copy_mode;

namespace telar::gui::qt {

namespace {

struct CellRun {
  CellStyle style;
  QString text;
  std::optional<glyphs::Symbol> symbol;
  Color foreground;
  Color background;
  std::size_t consumed_cells = 1;
  std::size_t columns = 1;
  bool visible = true;
};

struct RowLayers {
  QSGNode &shapes;
  QSGNode &backgrounds;
  QSGNode &decorations;
  QQuickWindow &window;
};

std::size_t faceIndex(const CellStyle &style) noexcept {
  constexpr std::size_t regular = 0;
  constexpr std::size_t bold = 1;
  constexpr std::size_t italic = 2;

  return (hasAttribute(style, CellAttribute::bold) ? bold : regular) | (hasAttribute(style, CellAttribute::italic) ? italic : regular);
}

fonts::GlyphStyle glyphStyle(const CellStyle &style) noexcept {
  return {.bold = hasAttribute(style, CellAttribute::bold), .italic = hasAttribute(style, CellAttribute::italic)};
}

bool joinsLatinLigature(Byte previous, Byte next) noexcept {
  return (previous == 'f' && (next == 'i' || next == 'l')) || (previous == 's' && next == 't');
}

UnderlineStyle underlineStyle(const CellStyle &style) noexcept {
  constexpr unsigned underline_shift = 8;
  constexpr unsigned underline_mask = 7;

  return static_cast<UnderlineStyle>((static_cast<unsigned>(style.flags) >> underline_shift) & underline_mask);
}

QTextCharFormat textFormat(Color foreground) {
  QTextCharFormat format;
  format.setForeground(toQColor(foreground));

  return format;
}

CellRectangle visibleCells(const TerminalPresentation &frame) {
  const TerminalGrid grid{.cell_width_px = frame.grid.width, .cell_height_px = frame.grid.height};
  const auto fitted = grid.fit(std::round(frame.bounds.width() * frame.scale), std::round(frame.bounds.height() * frame.scale));
  if (!fitted) {
    return {};
  }

  // A view scrolled by pixels draws one row past the screen's last, partly shown.
  const auto drawn = frame.rows.empty() ? fitted->rows : fitted->rows + 1;
  return {.width = std::min(fitted->cols, frame.screen.columns()), .height = static_cast<std::uint16_t>(std::min<std::size_t>(drawn, frame.rowCount()))};
}

std::optional<std::size_t> cursorColumn(const TerminalPresentation &frame, std::size_t row, std::size_t columns) {
  const auto &cursor = frame.cursor_override ? *frame.cursor_override : frame.screen.cursor();
  if (!frame.pane_focused || !cursor.visible || frame.screenRow(row) != std::optional<std::size_t>{cursor.y} || cursor.x >= columns) {
    return std::nullopt;
  }

  auto column = static_cast<std::size_t>(cursor.x);
  if (column != 0 && frame.row(row)[column].width == CellWidth::continuation) {
    --column;
  }

  return column;
}

CellRun cellRun(const TerminalPresentation &frame, std::size_t row_index, std::size_t column) {
  const auto row = frame.row(row_index);
  const auto &cell = row[column];
  const auto &theme = frame.configuration.theme;
  const auto selected = frame.selected({.x = static_cast<std::uint16_t>(column), .y = static_cast<std::uint32_t>(row_index)});
  const auto symbol = CellGlyphs::parse(cell.utf8());
  CellRun run{
      .style = cell.style,
      .text = {},
      .symbol = symbol,
      .foreground = theme.resolve(cell.style.foreground, theme.foreground),
      .background = theme.resolve(cell.style.background, theme.background),
      .visible = cell.width != CellWidth::continuation && !cell.utf8().empty() && !cell.utf8().starts_with(placeholder_prefix) && !hasAttribute(cell.style, CellAttribute::invisible),
  };

  if (hasAttribute(cell.style, CellAttribute::inverse) != selected) {
    std::swap(run.foreground, run.background);
  }

  if (hasAttribute(cell.style, CellAttribute::faint)) {
    constexpr float faint_opacity = 0.5F;
    run.foreground.a *= faint_opacity;
  }

  run.columns = cell.width == CellWidth::wide ? 2 : 1;

  return run;
}

CellRun textRun(const TerminalPresentation &frame, std::size_t row_index, std::size_t column, std::size_t columns) {
  auto run = cellRun(frame, row_index, column);
  const auto row = frame.row(row_index).first(columns);
  const auto &cell = row[column];
  const auto selected = frame.selected({.x = static_cast<std::uint16_t>(column), .y = static_cast<std::uint32_t>(row_index)});
  run.text = run.symbol ? QString{} : toQString(cell.utf8());
  constexpr Byte ascii_limit = 128;
  if (frame.font.fixed_pitch && cell.width == CellWidth::single && cell.length == 1 && cell.text[0] < ascii_limit) {
    while (column + run.consumed_cells < row.size()) {
      const auto &next = row[column + run.consumed_cells];
      const auto next_selected = frame.selected({.x = static_cast<std::uint16_t>(column + run.consumed_cells), .y = static_cast<std::uint32_t>(row_index)});
      if (next.width != CellWidth::single || next.length != 1 || next.text[0] >= ascii_limit || next.style != cell.style || next_selected != selected || joinsLatinLigature(row[column + run.consumed_cells - 1].text[0], next.text[0])) {
        break;
      }

      run.text += QLatin1Char(static_cast<char>(next.text[0]));
      ++run.consumed_cells;
    }
  }

  run.columns = cell.width == CellWidth::wide ? 2 : run.consumed_cells;

  return run;
}

void paintUnderline(RowLayers layers, const CellRun &run, const TerminalPresentation &frame, const QRectF &bounds) {
  constexpr qreal underline_inset_pixels = 2;
  const auto thickness = 1 / frame.scale;
  const auto y = bounds.bottom() - (underline_inset_pixels / frame.scale);
  const auto color = frame.configuration.theme.resolve(run.style.underline_color, run.foreground);
  TerminalDecorations::rectangle(layers.window, layers.decorations, {bounds.x(), y, bounds.width(), thickness}, color, frame.scale);
}

void paintRun(RowLayers layers, const CellRun &run, const TerminalPresentation &frame, const QPointF &origin, CellGlyphs &glyphs) {
  const QRectF bounds{origin, QSizeF{static_cast<qreal>(run.columns) * frame.font.cell.width(), frame.font.cell.height()}};
  const auto &theme = frame.configuration.theme;
  if (run.background != theme.background) {
    appendSceneNode<QSGSimpleRectNode>(layers.backgrounds, bounds, toQColor(run.background));
  }

  if (!run.visible) {
    return;
  }

  if (run.symbol) {
    glyphs.paint(layers.shapes, *run.symbol, bounds, frame.scale, run.foreground);
  }

  if (underlineStyle(run.style) != UnderlineStyle::none) {
    paintUnderline(layers, run, frame, bounds);
  }

  if (hasAttribute(run.style, CellAttribute::strikethrough)) {
    constexpr qreal strike_position = 0.5;
    TerminalDecorations::rectangle(layers.window, layers.decorations, {bounds.x(), bounds.y() + (bounds.height() * strike_position), bounds.width(), 1 / frame.scale}, run.foreground, frame.scale);
  }
}

void paintOutline(QSGNode &parent, const QRectF &bounds, const QColor &color, qreal thickness) {
  appendSceneNode<QSGSimpleRectNode>(parent, QRectF{bounds.left(), bounds.top(), bounds.width(), thickness}, color);
  appendSceneNode<QSGSimpleRectNode>(parent, QRectF{bounds.left(), bounds.bottom() - thickness, bounds.width(), thickness}, color);
  appendSceneNode<QSGSimpleRectNode>(parent, QRectF{bounds.left(), bounds.top(), thickness, bounds.height()}, color);
  appendSceneNode<QSGSimpleRectNode>(parent, QRectF{bounds.right() - thickness, bounds.top(), thickness, bounds.height()}, color);
}

}

TerminalScene::TerminalScene(QQuickWindow &window)
    : window_(window),
      background_(appendSceneNode<QSGSimpleRectNode>(*this)),
      below_background_(appendSceneNode<QSGTransformNode>(*this)),
      cell_backgrounds_(appendSceneNode<QSGTransformNode>(*this)),
      matches_(appendSceneNode<QSGTransformNode>(*this)),
      below_text_(appendSceneNode<QSGTransformNode>(*this)),
      rows_(appendSceneNode<QSGTransformNode>(*this)),
      above_text_(appendSceneNode<QSGTransformNode>(*this)),
      overlay_(appendSceneNode<QSGTransformNode>(*this)),
      images_({.below_background = &below_background_, .below_text = &below_text_, .above_text = &above_text_}),
      glyphs_(window),
      text_(window),
      overlay_text_(window) {}

TerminalScene::~TerminalScene() {
  images_.clearNodes();
}

QSGNode *TerminalScene::synchronizeNode(QSGNode *previous, QQuickWindow &window, const TerminalPresentation &frame) {
  std::unique_ptr<QSGNode> node{previous};
  auto *scene = dynamic_cast<TerminalScene *>(node.get());
  if (scene == nullptr) {
    auto replacement = std::make_unique<TerminalScene>(window);
    scene = replacement.get();
    node = std::move(replacement);
  }

  scene->synchronize(window, frame);

  return node.release();
}

void TerminalScene::synchronizeGrid(CellRectangle visible) {
  if (std::cmp_equal(row_nodes_.size(), visible.height) && columns_ == visible.width) {
    return;
  }

  clearSceneChildren(rows_);
  clearSceneChildren(cell_backgrounds_);
  row_nodes_.clear();
  row_nodes_.reserve(visible.height);
  for (std::size_t index = 0; index < visible.height; ++index) {
    // Each row can fade and rise into place on its own, for a command's first output.
    QSGOpacityNode *text_opacity = &appendSceneNode<QSGOpacityNode>(rows_);
    QSGOpacityNode *background_opacity = &appendSceneNode<QSGOpacityNode>(cell_backgrounds_);
    row_nodes_.append({.text = &appendSceneNode<QSGTransformNode>(*text_opacity), .background = &appendSceneNode<QSGTransformNode>(*background_opacity), .text_opacity = text_opacity, .background_opacity = background_opacity});
  }

  columns_ = visible.width;
}

void TerminalScene::paintRow(const TerminalPresentation &frame, std::size_t row_index) {
  auto &row = row_nodes_[static_cast<qsizetype>(row_index)];
  std::unique_ptr<QSGNode> previous{row.text_content};
  row.text_content = nullptr;
  if (previous) {
    row.text->removeChildNode(previous.get());
  }

  clearSceneChildren(*row.text);
  clearSceneChildren(*row.background);
  auto &shapes = appendSceneNode<QSGNode>(*row.text);
  const QRectF row_bounds{0, static_cast<qreal>(row_index) * frame.font.cell.height(), columns_ * frame.font.cell.width(), frame.font.cell.height()};
  text_.begin(row_bounds, frame.scale, frame.bounds, std::move(previous));
  const auto cursor_column = cursorColumn(frame, row_index, columns_);

  const auto cells = frame.row(row_index).first(std::min<std::size_t>(columns_, frame.row(row_index).size()));
  const auto screen_row = frame.screenRow(row_index);
  const auto grouped_text = text_.prepare(cells, {.pixel_height = frame.grid.pixel_height, .cell_width = frame.grid.width, .cursor = cursor_column, .selection = screen_row ? frame.selection : CellSelection{}, .first_cell = screen_row.value_or(0) * frame.screen.columns()});
  auto decorations = std::make_unique<QSGNode>();
  for (std::size_t column = 0; column < cells.size(); ++column) {
    const auto run = cellRun(frame, row_index, column);
    std::unique_ptr<QSGNode> inline_ink;
    if (grouped_text && run.visible && (run.symbol || underlineStyle(run.style) != UnderlineStyle::none || hasAttribute(run.style, CellAttribute::strikethrough))) {
      inline_ink = std::make_unique<QSGNode>();
    }

    const RowLayers layers{.shapes = inline_ink ? *inline_ink : shapes, .backgrounds = *row.background, .decorations = inline_ink ? *inline_ink : *decorations, .window = window_};
    const QPointF origin{static_cast<qreal>(column) * frame.font.cell.width(), static_cast<qreal>(row_index) * frame.font.cell.height()};
    paintRun(layers, run, frame, origin, glyphs_);
    if (grouped_text && run.visible && !run.symbol) {
      text_.addCell(cells, column, frame.font.faces[faceIndex(run.style)], run.foreground, glyphStyle(run.style));
    }

    if (inline_ink) {
      text_.appendInline(cells, std::move(inline_ink));
    }
  }

  if (!grouped_text) {
    for (std::size_t column = 0; column < cells.size();) {
      const auto run = textRun(frame, row_index, column, cells.size());
      if (run.visible && !run.symbol) {
        const QPointF origin{static_cast<qreal>(column) * frame.font.cell.width(), static_cast<qreal>(row_index) * frame.font.cell.height()};
        text_.add(run.text, frame.font.faces[faceIndex(run.style)], textFormat(run.foreground), {.origin = origin, .baseline = frame.font.baseline, .style = glyphStyle(run.style)});
      }

      column += run.consumed_cells;
    }
  }

  row.text_content = text_.append(*row.text, cells);
  adoptSceneNode(*row.text, std::move(decorations));
  row.revision = frame.rowRevision(row_index);
  row.source = frame.rowSource(row_index);
  row.appearance = frame.appearance;
  row.selection = screen_row ? frame.selection.within(*screen_row * frame.screen.columns(), frame.screen.columns()) : CellSelection{};
  row.cursor = cursor_column;
}

void TerminalScene::synchronize(QQuickWindow &window, const TerminalPresentation &frame) {
  background_.setRect(frame.bounds);
  // Live panes provide their background; standalone scenes retain their own fill.
  background_.setColor(frame.background_provided || frame.configuration.background_opacity < 1 ? QColor{Qt::transparent} : toQColor(frame.configuration.theme.background));
  synchronizeGrid(visibleCells(frame));
  // The rows, the images and what is drawn over them move up by the shift.
  if (shift_ != frame.shift) {
    QMatrix4x4 rows;
    rows.translate(0, static_cast<float>(-frame.shift));
    for (auto *layer : {&cell_backgrounds_, &matches_, &rows_, &overlay_, &below_background_, &below_text_, &above_text_}) {
      layer->setMatrix(rows);
    }
    shift_ = frame.shift;
  }

  const auto glyphs_changed = appearance_ != frame.appearance || scale_ != frame.scale;
  if (glyphs_changed) {
    glyphs_.configure(frame.font.faces.front(), frame.scale, frame.box_stroke);
    text_.configure(frame.configuration.font, frame.grid, frame.fonts);
    overlay_text_.configure(frame.configuration.font, frame.grid, frame.fonts);
  }

  for (qsizetype index = 0; index < row_nodes_.size(); ++index) {
    auto &row = row_nodes_[index];
    const auto position = static_cast<std::size_t>(index);
    if (frame.hidden(position)) {
      if (!row.hidden) {
        std::unique_ptr<QSGNode> previous{row.text_content};
        row.text_content = nullptr;
        if (previous) {
          row.text->removeChildNode(previous.get());
        }
        clearSceneChildren(*row.text);
        clearSceneChildren(*row.background);
        row.hidden = true;
      }
      continue;
    }
    const auto revealed = frame.revealed(position);
    const auto offset = frame.offset(position);
    if (revealed != row.revealed || offset != row.offset) {
      row.revealed = revealed;
      row.offset = offset;
      const auto settled = 1.0F - (1.0F - revealed) * (1.0F - revealed) * (1.0F - revealed);
      QMatrix4x4 lift;
      lift.translate(0, (static_cast<float>(frame.font.cell.height()) * 0.25F * (1.0F - settled)) + offset);
      row.text->setMatrix(lift);
      row.background->setMatrix(lift);
      row.text_opacity->setOpacity(revealed);
      row.background_opacity->setOpacity(revealed);
    }
    const bool shown = std::exchange(row.hidden, false);
    const auto screen_row = frame.screenRow(position);
    const auto selection = screen_row ? frame.selection.within(*screen_row * frame.screen.columns(), frame.screen.columns()) : CellSelection{};
    if (shown || glyphs_changed || bounds_ != frame.bounds || row.revision != frame.rowRevision(position) || row.source != frame.rowSource(position) || row.appearance != frame.appearance || row.selection != selection || row.cursor != cursorColumn(frame, position, columns_)) {
      paintRow(frame, static_cast<std::size_t>(index));
    }
  }

  auto image_rows = ImageRows::of(frame.screen, drawn_cells_);
  if (!frame.rows.empty()) {
    // A view's own rows: from its top shown row, through its folds.
    drawn_cells_.clear();
    for (std::size_t index = 0; index < frame.rowCount(); ++index) {
      drawn_cells_.push_back(frame.row(index));
    }
    image_rows.top = frame.top_row;
    image_rows.folds = frame.folds;
    image_rows.rows = drawn_cells_;
    image_rows.revision = frame.view_revision;
  }
  images_.synchronize(frame.owner != nullptr ? *frame.owner : *window.contentItem(), frame.graphics, image_rows, frame.font.cell, frame.scale);
  paintMatches(frame);
  clearSceneChildren(overlay_);
  paintCursor(frame);
  paintPreedit(frame);
  paintHoveredLink(frame);
  appearance_ = frame.appearance;
  scale_ = frame.scale;
  bounds_ = frame.bounds;
}

// Every match lit, the current one more, only when they or where they are drawn changed.
void TerminalScene::paintMatches(const TerminalPresentation &frame) {
  const bool same_offsets = std::ranges::equal(lit_offsets_, frame.row_offsets);
  if (std::ranges::equal(lit_matches_, frame.matches) && same_offsets && lit_bounds_ == frame.bounds) {
    return;
  }
  lit_matches_.assign(frame.matches.begin(), frame.matches.end());
  lit_offsets_.assign(frame.row_offsets.begin(), frame.row_offsets.end());
  lit_bounds_ = frame.bounds;
  clearSceneChildren(matches_);
  constexpr float match_alpha = 0.32F;
  constexpr float current_alpha = 0.8F;
  const auto &theme = frame.configuration.theme;
  for (const auto &match : frame.matches) {
    if (match.row >= row_nodes_.size() || frame.hidden(match.row)) {
      continue;
    }
    auto color = theme.warning;
    color.a *= match.current ? current_alpha : match_alpha;
    const QRectF bounds{static_cast<qreal>(match.column) * frame.font.cell.width(), (static_cast<qreal>(match.row) * frame.font.cell.height()) + frame.offset(match.row), static_cast<qreal>(match.length) * frame.font.cell.width(), frame.font.cell.height()};
    appendSceneNode<QSGSimpleRectNode>(matches_, bounds, toQColor(color));
  }
}

void TerminalScene::paintHoveredLink(const TerminalPresentation &frame) {
  if (frame.hovered_link == nullptr) {
    return;
  }

  const auto &screen = frame.link_screen != nullptr ? *frame.link_screen : frame.screen;
  const LinkGrid grid{.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = screen.rowFlags()};
  LinkRegions regions{*frame.hovered_link, grid, screen.linkRuns(), {.columns = columns_, .rows = static_cast<std::uint16_t>(row_nodes_.size())}};
  constexpr qreal underline_inset_pixels = 2;
  constexpr qreal underline_thickness_pixels = 1;
  while (const auto area = regions.next()) {
    // On the drawn rows' own screen a row is where it is drawn.
    const auto drawn = frame.link_screen != nullptr ? std::optional<std::size_t>{area->y} : frame.drawnRow(area->y);
    if (!drawn) {
      continue;
    }
    const QRectF bounds{area->x * frame.font.cell.width(), ((static_cast<qreal>(*drawn) + 1) * frame.font.cell.height()) + frame.offset(*drawn) - (underline_inset_pixels / frame.scale), area->width * frame.font.cell.width(), underline_thickness_pixels / frame.scale};
    appendSceneNode<QSGSimpleRectNode>(overlay_, bounds, toQColor(frame.configuration.theme.accent));
  }
}

void TerminalScene::paintCursor(const TerminalPresentation &frame) {
  const auto &cursor = frame.cursor_override ? *frame.cursor_override : frame.screen.cursor();
  if (!cursor.visible || !frame.pane_focused || (!frame.cursor_on && !frame.cursor_override)) {
    return;
  }

  const auto drawn = frame.drawnRow(cursor.y);
  if (!drawn || std::cmp_greater_equal(*drawn, row_nodes_.size()) || cursor.x >= columns_ || frame.hidden(*drawn)) {
    return;
  }

  const auto row = frame.row(*drawn);
  if (cursor.x >= row.size()) {
    return;
  }

  auto column = static_cast<std::size_t>(cursor.x);
  if (column != 0 && row[column].width == CellWidth::continuation) {
    --column;
  }

  const auto &cell = row[column];
  const auto cell_columns = cell.width == CellWidth::wide ? 2 : 1;

  auto shape = cursor.shape == CursorShape::default_shape ? frame.configuration.cursor : cursor.shape;
  if (!frame.keyboard) {
    shape = CursorShape::hollow;
  }

  const auto &theme = frame.configuration.theme;
  QRectF bounds{static_cast<qreal>(column) * frame.font.cell.width(), (static_cast<qreal>(*drawn) * frame.font.cell.height()) + frame.offset(*drawn), cell_columns * frame.font.cell.width(), frame.font.cell.height()};
  const auto color = toQColor(theme.cursor);
  constexpr qreal cursor_thickness = 2;
  if (shape == CursorShape::hollow) {
    paintOutline(overlay_, bounds, color, 1 / frame.scale);

    return;
  }

  if (shape == CursorShape::bar) {
    bounds.setWidth(cursor_thickness);
  } else if (shape == CursorShape::underline) {
    bounds.setTop(bounds.bottom() - cursor_thickness);
  }

  appendSceneNode<QSGSimpleRectNode>(overlay_, bounds, color);
  if (shape != CursorShape::block) {
    return;
  }

  if (hasAttribute(cell.style, CellAttribute::invisible) || cell.utf8().starts_with(placeholder_prefix)) {
    return;
  }

  const auto foreground = theme.cursor_text.value_or(theme.background);
  if (const auto symbol = CellGlyphs::parse(cell.utf8())) {
    glyphs_.paint(overlay_, *symbol, bounds, frame.scale, foreground);

    return;
  }

  overlay_text_.begin(bounds, frame.scale, frame.bounds);
  QTextCharFormat format;
  format.setForeground(toQColor(foreground));
  overlay_text_.add(toQString(cell.utf8()), frame.font.faces[faceIndex(cell.style)], format, {.origin = bounds.topLeft(), .baseline = frame.font.baseline, .style = glyphStyle(cell.style)});
  overlay_text_.append(overlay_);
}

void TerminalScene::paintPreedit(const TerminalPresentation &frame) {
  const auto drawn = frame.drawnRow(frame.screen.cursor().y);
  if (frame.preedit.isEmpty() || frame.screen.cursor().x >= columns_ || !drawn || std::cmp_greater_equal(*drawn, row_nodes_.size())) {
    return;
  }

  const auto &cursor = frame.screen.cursor();
  const QRectF bounds{cursor.x * frame.font.cell.width(), static_cast<qreal>(*drawn) * frame.font.cell.height(), static_cast<qreal>(frame.preedit.size()) * frame.font.cell.width(), frame.font.cell.height()};
  overlay_text_.begin(bounds, frame.scale, frame.bounds);
  QTextCharFormat format;
  format.setForeground(toQColor(frame.configuration.theme.foreground));
  overlay_text_.add(frame.preedit, frame.font.faces[0], format, {.origin = bounds.topLeft(), .baseline = frame.font.baseline});
  overlay_text_.append(overlay_);
  constexpr qreal underline_inset_pixels = 2;
  TerminalDecorations::rectangle(window_, overlay_, {bounds.x(), bounds.bottom() - (underline_inset_pixels / frame.scale), bounds.width(), 1 / frame.scale}, frame.configuration.theme.foreground, frame.scale);
}

}
