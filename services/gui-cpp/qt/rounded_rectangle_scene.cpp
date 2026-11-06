#include "rounded_rectangle_scene.hpp"
#include "core/color.hpp"
#include "core/geometry.hpp"
#include "graphics/rounded_rectangle.hpp"
#include "physical_pixel_matrix.hpp"
#include <QByteArray>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGNode>
#include <QSGRendererInterface>
#include <QString>
#include <QtCore/qlogging.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qsgmaterialtype.h>
#include <array>
#include <cstddef>
#include <cstring>
#include <memory>
#include <span>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {
  namespace {

    struct ShapeUniforms {
      static constexpr std::size_t matrix_side = 4;
      std::array<float, matrix_side * matrix_side> matrix{};
      float opacity = 1;
      float replace_background = 0;
    };

    class ShapeShader final : public QSGMaterialShader {
    public:
      ShapeShader(bool physical_coordinates, bool replace_background)
          : physical_coordinates_(physical_coordinates),
            replace_background_(replace_background) {
        setShaderFileName(VertexStage, QStringLiteral(":/telar/shaders/rounded_rectangle.vert.qsb"));
        setShaderFileName(FragmentStage, QStringLiteral(":/telar/shaders/rounded_rectangle.frag.qsb"));
        setFlag(UpdatesGraphicsPipelineState);
      }

      bool updateUniformData(RenderState &state, [[maybe_unused]] QSGMaterial *material, QSGMaterial *last) override {
        auto &buffer = *state.uniformData();
        if (buffer.size() < static_cast<qsizetype>(sizeof(ShapeUniforms))) {
          qFatal("Rounded rectangle uniform buffer is too small");
        }

        bool changed = false;
        if (last == nullptr) {
          const float replace = replace_background_ ? 1 : 0;
          std::memcpy(buffer.data() + offsetof(ShapeUniforms, replace_background), &replace, sizeof(replace));
          changed = true;
        }
        if (state.isMatrixDirty() || last == nullptr) {
          auto matrix = physicalPixelMatrix(state);
          if (physical_coordinates_) {
            const auto inverse_density = 1 / state.devicePixelRatio();
            matrix.scale(inverse_density, inverse_density);
          }
          std::memcpy(buffer.data() + offsetof(ShapeUniforms, matrix), matrix.constData(), sizeof(ShapeUniforms::matrix));
          changed = true;
        }

        if (state.isOpacityDirty() || last == nullptr) {
          const auto opacity = state.opacity();
          std::memcpy(buffer.data() + offsetof(ShapeUniforms, opacity), &opacity, sizeof(opacity));
          changed = true;
        }

        return changed;
      }

      bool updateGraphicsPipelineState([[maybe_unused]] RenderState &state, GraphicsPipelineState *pipeline, [[maybe_unused]] QSGMaterial *material, [[maybe_unused]] QSGMaterial *last) override {
        pipeline->blendEnable = true;
        pipeline->srcColor = replace_background_ ? GraphicsPipelineState::One : GraphicsPipelineState::SrcAlpha;
        pipeline->dstColor = replace_background_ ? GraphicsPipelineState::Zero : GraphicsPipelineState::OneMinusSrcAlpha;
        pipeline->separateBlendFactors = true;
        pipeline->srcAlpha = GraphicsPipelineState::One;
        pipeline->dstAlpha = replace_background_ ? GraphicsPipelineState::Zero : GraphicsPipelineState::OneMinusSrcAlpha;

        return true;
      }

    private:
      bool physical_coordinates_;
      bool replace_background_;
    };

    class ShapeMaterial final : public QSGMaterial {
    public:
      explicit ShapeMaterial(bool physical_coordinates = false)
          : physical_coordinates_(physical_coordinates) {
        setFlag(Blending);
        setFlag(RequiresFullMatrix, physical_coordinates);
      }

      [[nodiscard]] QSGMaterialType *type() const override {
        static std::array<QSGMaterialType, 4> types;
        return &types[static_cast<std::size_t>(physical_coordinates_) + 2 * static_cast<std::size_t>(replace_background_)];
      }

      [[nodiscard]] QSGMaterialShader *createShader([[maybe_unused]] QSGRendererInterface::RenderMode render_mode) const override {
        return std::make_unique<ShapeShader>(physical_coordinates_, replace_background_).release();
      }

      int compare([[maybe_unused]] const QSGMaterial *other) const override {
        return 0;
      }

      bool setReplacement(bool replace) noexcept {
        return std::exchange(replace_background_, replace) != replace;
      }

    private:
      bool physical_coordinates_;
      bool replace_background_ = false;
    };

    struct ShapeVertex {
      Point position;
      Point local;
      Point size;
      Point outline;
      Color fill;
      Color border;
      Color backdrop;

      bool operator==(const ShapeVertex &) const = default;
    };

    constexpr std::size_t triangle_vertices = 6;
    constexpr std::array<Point, triangle_vertices> corners{{{.x = 0, .y = 0}, {.x = 1, .y = 0}, {.x = 1, .y = 1}, {.x = 0, .y = 0}, {.x = 1, .y = 1}, {.x = 0, .y = 1}}};

    ShapeVertex shapeVertex(RoundedRectanglePaint paint, Point corner, qreal density) {
      const auto shape = paint.shape;
      const Point local{.x = corner.x * shape.size.x, .y = corner.y * shape.size.y};

      return {.position = {.x = static_cast<float>((paint.origin.x + local.x) / density), .y = static_cast<float>((paint.origin.y + local.y) / density)}, .local = local, .size = shape.size, .outline = {.x = shape.style.square_bottom ? -shape.style.radius : shape.style.radius, .y = shape.style.border_width}, .fill = shape.style.fill, .border = shape.style.border, .backdrop = shape.style.backdrop};
    }

    const QSGGeometry::AttributeSet &shapeAttributes() {
      static const std::array attributes{
          QSGGeometry::Attribute::create(0, 2, QSGGeometry::FloatType, true),
          QSGGeometry::Attribute::create(1, 2, QSGGeometry::FloatType),
          QSGGeometry::Attribute::create(2, 2, QSGGeometry::FloatType),
          QSGGeometry::Attribute::create(3, 2, QSGGeometry::FloatType),
          QSGGeometry::Attribute::create(4, 4, QSGGeometry::FloatType),
          QSGGeometry::Attribute::create(5, 4, QSGGeometry::FloatType),
          QSGGeometry::Attribute::create(6, 4, QSGGeometry::FloatType),
      };
      static const QSGGeometry::AttributeSet layout{.count = static_cast<int>(attributes.size()), .stride = sizeof(ShapeVertex), .attributes = attributes.data()};

      return layout;
    }

    class RoundedRectangleNode final : public QSGGeometryNode {
    public:
      RoundedRectangleNode()
          : geometry_(shapeAttributes(), triangle_vertices) {
        geometry_.setDrawingMode(QSGGeometry::DrawTriangles);
        geometry_.setVertexDataPattern(QSGGeometry::DynamicPattern);
        setGeometry(&geometry_);
        setMaterial(&material_);
      }

      void refresh(RoundedRectanglePaint paint, qreal density) {
        const auto shape = paint.shape;
        if (shape_ == shape && density_ == density && origin_ == paint.origin) {
          return;
        }

        if (material_.setReplacement(shape.style.replace_background)) {
          markDirty(DirtyMaterial);
        }
        shape_ = shape;
        origin_ = paint.origin;
        density_ = density;
        const auto vertices = std::span{static_cast<ShapeVertex *>(geometry_.vertexData()), corners.size()};
        for (std::size_t index = 0; index < corners.size(); ++index) {
          vertices[index] = shapeVertex(paint, corners[index], density);
        }

        geometry_.markVertexDataDirty();
        markDirty(DirtyGeometry);
      }

    private:
      QSGGeometry geometry_;
      ShapeMaterial material_;
      RoundedRectangle shape_;
      Point origin_;
      qreal density_ = 0;
    };

    class RoundedRectangleBatchNode final : public QSGGeometryNode {
    public:
      RoundedRectangleBatchNode()
          : geometry_(shapeAttributes(), 0) {
        geometry_.setDrawingMode(QSGGeometry::DrawTriangles);
        geometry_.setVertexDataPattern(QSGGeometry::DynamicPattern);
        setGeometry(&geometry_);
        setMaterial(&material_);
      }

      void refresh(std::span<const RoundedRectanglePaint> paints) {
        const bool replace = !paints.empty() && paints.front().shape.style.replace_background;
        if (material_.setReplacement(replace)) {
          markDirty(DirtyMaterial);
        }
        const auto vertex_count = static_cast<int>(paints.size() * triangle_vertices);
        const auto resized = geometry_.vertexCount() != vertex_count;
        if (resized) {
          geometry_.allocate(vertex_count);
        }

        bool changed = resized;
        const auto vertices = std::span{static_cast<ShapeVertex *>(geometry_.vertexData()), static_cast<std::size_t>(vertex_count)};
        for (std::size_t index = 0; index < paints.size(); ++index) {
          if (paints[index].shape.style.replace_background != replace) {
            throw std::invalid_argument{"Mixed background composition in a rounded rectangle batch"};
          }
          for (std::size_t corner = 0; corner < corners.size(); ++corner) {
            const auto offset = (index * triangle_vertices) + corner;
            const auto vertex = shapeVertex(paints[index], corners[corner], 1);
            if (resized || vertices[offset] != vertex) {
              vertices[offset] = vertex;
              changed = true;
            }
          }
        }

        if (changed) {
          geometry_.markVertexDataDirty();
          markDirty(DirtyGeometry);
        }
      }

    private:
      QSGGeometry geometry_;
      ShapeMaterial material_{true};
    };

    QSGNode *paintSoftwareBatch(QQuickWindow &window, QSGNode &root, std::span<const RoundedRectanglePaint> paints, qreal density) {
      auto *next = root.firstChild();
      for (const auto paint : paints) {
        auto *current = next;
        next = current == nullptr ? nullptr : current->nextSibling();
        auto *painted = paintSoftwareRoundedRectangleAt(window, current, paint, density);
        if (painted == current) {
          continue;
        }

        if (next == nullptr) {
          root.appendChildNode(painted);
        } else {
          root.insertChildNodeBefore(painted, next);
        }
      }

      return next;
    }
  }

  QSGNode *paintRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density) {
    return paintRoundedRectangleAt(window, previous, {.shape = shape}, density);
  }

  QSGNode *paintRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density) {
    if (window.rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {
      return paintSoftwareRoundedRectangleAt(window, previous, paint, density);
    }

    auto owner = std::unique_ptr<QSGNode>{previous};
    auto *node = dynamic_cast<RoundedRectangleNode *>(previous);
    if (node == nullptr) {
      auto replacement = std::make_unique<RoundedRectangleNode>();
      node = replacement.get();
      owner = std::move(replacement);
    }

    node->refresh(paint, density);

    return owner.release();
  }

  void paintRoundedRectangles(QQuickWindow &window, QSGNode &root, std::span<const RoundedRectanglePaint> paints, qreal density) {
    auto *next = root.firstChild();
    if (window.rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {
      next = paintSoftwareBatch(window, root, paints, density);
    } else {
      auto *batch = dynamic_cast<RoundedRectangleBatchNode *>(next);
      if (batch == nullptr) {
        batch = std::make_unique<RoundedRectangleBatchNode>().release();
        root.prependChildNode(batch);
      } else {
        next = next->nextSibling();
      }

      batch->refresh(paints);
    }

    while (next != nullptr) {
      auto *retired = next;
      next = next->nextSibling();
      root.removeChildNode(retired);
      const std::unique_ptr<QSGNode> owner{retired};
    }
  }

}
