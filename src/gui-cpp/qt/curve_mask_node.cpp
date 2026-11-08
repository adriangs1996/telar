#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "curve_mask_node.hpp"
#include "alpha_mask_material.hpp"
#include "alpha_mask_vertex.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include "curve_mask.hpp"
#include "scene_nodes.hpp"
#include <QPointF>
#include <QRectF>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGNode>
#include <span>
#include <utility>



import telar.gui.core.metrics;

namespace telar::gui::qt {
namespace {
class CurveQuad final : public QSGGeometryNode {
public:
  CurveQuad(CurveMaskRef mask, const QRectF &bounds, Color foreground)
      : mask_(std::move(mask)),
        geometry_(alphaMaskAttributes(), quad_vertices),
        material_(*mask_->texture, foreground) {
    geometry_.setDrawingMode(QSGGeometry::DrawTriangleStrip);
    constexpr std::array corners{QPointF{0, 0}, QPointF{1, 0}, QPointF{0, 1}, QPointF{1, 1}};
    const auto vertices = std::span{static_cast<AlphaMaskVertex *>(geometry_.vertexData()), corners.size()};
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

void appendCurveMask(QSGNode &parent, CurveMaskRef mask, const QRectF &bounds, Color foreground) {
  appendSceneNode<CurveQuad>(parent, std::move(mask), bounds, foreground);
}

}
