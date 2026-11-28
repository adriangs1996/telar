module telar.gui.ui.kit.scene;

import std;
import telar.gui.qt;
import telar.base.ds;

namespace telar::gui::qt {
  namespace {
    class CurveQuad final : public QSGGeometryNode {
    public:
      CurveQuad(CurveMaskRef mask, const QRectF& bounds, Color foreground)
          : mask_(std::move(mask)),
            geometry_(alphaMaskAttributes(), quad_vertices),
            material_(*mask_->texture, foreground) {
        geometry_.setDrawingMode(QSGGeometry::DrawTriangleStrip);
        constexpr ds::Array corners{QPointF{0, 0}, QPointF{1, 0}, QPointF{0, 1}, QPointF{1, 1}};
        const auto vertices = geometryVertices<AlphaMaskVertex>(geometry_, corners.size());

        for (std::size_t index = 0; index < corners.size(); ++index) {
          const auto corner = corners[index];

          vertices[index] = {.x = static_cast<float>(bounds.x() + (corner.x() * bounds.width())), .y = static_cast<float>(bounds.y() + (corner.y() * bounds.height())), .u = static_cast<float>(corner.x()), .v = static_cast<float>(corner.y()), .opacity = 1};
        }

        setGeometry(&geometry_);
        setMaterial(&material_);
      }

    private:
      static constexpr int quad_vertices = 4;
      CurveMaskRef mask_;
      QSGGeometry geometry_;
      AlphaMaskMaterial material_;
    };

  }

  void appendCurveMask(QSGNode& parent, CurveMaskRef mask, const QRectF& bounds, Color foreground) {
    appendSceneNode<CurveQuad>(parent, std::move(mask), bounds, foreground);
  }

}
