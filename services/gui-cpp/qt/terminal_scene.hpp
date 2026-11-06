#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
  static QSGNode *synchronizeNode(QSGNode *previous, QQuickWindow &window, const TerminalPresentation &frame);

private:
  struct Row {
    QSGNode *text = nullptr;
    QSGNode *background = nullptr;
    QSGNode *text_content = nullptr;
    std::uint64_t revision = 0;
    std::uint64_t appearance = 0;
    CellSelection selection{};
    std::optional<std::size_t> cursor = std::nullopt;
  };

  void synchronizeGrid(CellRectangle visible);
  void paintRow(const TerminalPresentation &frame, Row &row, std::size_t row_index);
  void paintCursor(const TerminalPresentation &frame);
  void paintPreedit(const TerminalPresentation &frame);
  void paintHoveredLink(const TerminalPresentation &frame);

  QQuickWindow &window_;
  QSGSimpleRectNode &background_;
  QSGTransformNode &below_background_;
  QSGNode &cell_backgrounds_;
  QSGTransformNode &below_text_;
  QSGNode &rows_;
  QSGTransformNode &above_text_;
  QSGNode &overlay_;
  GraphicsScene images_;
  CellGlyphs glyphs_;
  TextScene text_;
  TextScene overlay_text_;
  QList<Row> row_nodes_;
  QRectF bounds_;
  std::uint16_t columns_ = 0;
  std::uint64_t appearance_ = 0;
  qreal scale_ = 0;
};
}
