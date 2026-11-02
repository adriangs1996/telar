#pragma once

#include "box_font.hpp"
#include "core/color.hpp"
#include "core/geometry.hpp"
#include "curve_scene.hpp"
#include "projection.hpp"
#include "scene_nodes.hpp"
#include "terminal/glyphs/block.hpp"
#include "terminal/glyphs/box.hpp"
#include "terminal/glyphs/box_curve.hpp"
#include "terminal/glyphs/braille.hpp"
#include "terminal/glyphs/ink.hpp"
#include "terminal/glyphs/symbol.hpp"
#include <QFont>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleRectNode>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

class CellGlyphs {
public:
  explicit CellGlyphs(QQuickWindow &window) noexcept
      : curves_(window) {}

  [[nodiscard]] static std::optional<glyphs::Symbol> parse(std::string_view text) noexcept {
    return glyphs::Symbol::parse(text);
  }

  void configure(const QFont &regular, qreal scale, std::optional<float> physical_stroke = std::nullopt) {
    thickness_ = physical_stroke ? *physical_stroke : BoxFont::thickness(regular, scale);
    curves_.reset();
  }

  void paint(QSGNode &parent, glyphs::Symbol symbol, const QRectF &bounds, qreal scale, Color foreground) {
    const Rect cell{.x = static_cast<float>(bounds.x() * scale), .y = static_cast<float>(bounds.y() * scale), .width = static_cast<float>(bounds.width() * scale), .height = static_cast<float>(bounds.height() * scale)};
    switch (symbol.kind) {
    case glyphs::SymbolKind::braille:
      append(parent, glyphs::Braille::draw(cell, static_cast<std::uint8_t>(symbol.codepoint - glyphs::Symbol::first_braille)), scale, foreground);
      break;
    case glyphs::SymbolKind::block:
      append(parent, glyphs::Block::draw(cell, symbol.codepoint), scale, foreground);
      break;
    case glyphs::SymbolKind::box:
      if (const auto shape = glyphs::BoxCurve::shape(symbol.codepoint)) {
        curves_.paint(parent, {.shape = *shape, .cell = cell, .foreground = foreground, .thickness = thickness_, .scale = scale});
      } else {
        append(parent, glyphs::Box::draw(symbol.codepoint, cell, thickness_), scale, foreground);
      }
      break;
    }
  }

private:
  template <std::size_t Capacity>
  static void append(QSGNode &parent, const glyphs::Ink<Capacity> &ink, qreal scale, Color foreground) {
    foreground.a *= ink.coverage();
    const auto color = toQColor(foreground);
    for (const auto rectangle : ink.rectangles()) {
      appendSceneNode<QSGSimpleRectNode>(parent, QRectF{rectangle.x / scale, rectangle.y / scale, rectangle.width / scale, rectangle.height / scale}, color);
    }
  }

  CurveScene curves_;
  float thickness_ = 1;
};

}
