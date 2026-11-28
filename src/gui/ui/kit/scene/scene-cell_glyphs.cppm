export module telar.gui.ui.kit.scene:cell_glyphs;

import std;
import telar.gui.qt;
import :curve_scene;
import :scene_nodes;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class CellGlyphs {
  public:
    [[tbc::hot_path]] inline explicit CellGlyphs(QQuickWindow& window) noexcept
        : curves_(window) {}

    [[tbc::hot_path]] [[nodiscard]] inline static ds::Option<glyphs::Symbol> parse(std::string_view text) noexcept {
      return glyphs::Symbol::parse(text);
    }

    [[tbc::hot_path]] inline void configure(const QFont& regular, qreal scale, ds::Option<float> physical_stroke = ds::none) {
      thickness_ = physical_stroke ? *physical_stroke : BoxFont::thickness(regular, scale);
      curves_.reset();
    }

    [[tbc::hot_path]] inline void paint(QSGNode& parent, glyphs::Symbol symbol, const QRectF& bounds, qreal scale, Color foreground) {
      const Rect cell{.x = static_cast<float>(bounds.x() * scale), .y = static_cast<float>(bounds.y() * scale), .width = static_cast<float>(bounds.width() * scale), .height = static_cast<float>(bounds.height() * scale)};

      switch (symbol.kind) {
      case glyphs::SymbolKind::braille:
        append(parent, glyphs::Braille::draw(cell, static_cast<std::uint8_t>(symbol.codepoint - glyphs::Symbol::first_braille)), scale, foreground);
        break;
      case glyphs::SymbolKind::block:
        append(parent, glyphs::Block::draw(cell, symbol.codepoint), scale, foreground);
        break;
      case glyphs::SymbolKind::powerline:
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
    [[tbc::generic]] static void append(QSGNode& parent, const glyphs::Ink<Capacity>& ink, qreal scale, Color foreground) {
      foreground.a *= ink.coverage();
      const auto color = toQColor(foreground);

      for (const auto rectangle : ink.rectangles()) {
        appendSceneNode<QSGSimpleRectNode>(parent, QRectF{static_cast<qreal>(rectangle.x) / scale, static_cast<qreal>(rectangle.y) / scale, static_cast<qreal>(rectangle.width) / scale, static_cast<qreal>(rectangle.height) / scale}, color);
      }
    }

    CurveScene curves_;
    float thickness_ = 1;
  };

}
