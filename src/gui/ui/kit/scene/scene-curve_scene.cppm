export module telar.gui.ui.kit.scene:curve_scene;

import std;
import telar.gui.qt;
import :curve_mask;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  struct CurvePaint {
    glyphs::BoxCurve::Shape shape = glyphs::BoxCurve::Shape::rounded_down_right;
    Rect cell;
    Color foreground;
    float thickness = 1;
    qreal scale = 1;
  };

  class CurveScene {
  public:
    explicit CurveScene(QQuickWindow& window) noexcept;
    ~CurveScene();
    CurveScene(const CurveScene&) = delete;
    CurveScene& operator=(const CurveScene&) = delete;
    CurveScene(CurveScene&&) = delete;
    CurveScene& operator=(CurveScene&&) = delete;
    void paint(QSGNode& parent, const CurvePaint& paint);
    void reset() noexcept;

  private:
    using Cache = glyphs::CurveCache<CurveMaskRef>;

    [[nodiscard]] ds::Option<CurveMaskRef> createMask(glyphs::BoxCurve::Shape shape, Rect cell, float thickness);
    [[nodiscard]] CurveMaskRef mask(const CurvePaint& paint);
    void software(QSGNode& parent, const CurveMaskRef& mask, const CurvePaint& paint) const;

    QQuickWindow& window_;
    Cache masks_;
    ds::Array<ds::Option<CurveMaskRef>, glyphs::BoxCurve::shape_count> fallback_{};
  };

}
