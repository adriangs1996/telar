#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "provider_mark.hpp"
#include "provider_artwork.hpp"
#include "tbc/view.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/scene/scene_nodes.hpp"
#include <QColor>
#include <QImage>
#include <QMatrix4x4>
#include <QObject>
#include <QPainter>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QSGTransformNode>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

import telar.gui.application;

namespace telar::gui::qt {

  namespace {

    class ProviderNode final : public QSGTransformNode {
    public:
      ProviderNode()
          : image(appendSceneNode<QSGSimpleTextureNode>(*this)) {}

      tbc::mut_self<QSGSimpleTextureNode> image;
      std::unique_ptr<QSGTexture> texture;
      int side = 0;
    };

    void tint(QImage& image, const QColor& color) {
      QPainter painter{&image};

      painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
      painter.fillRect(image.rect(), color);
    }

    // The artwork the item's properties pick.
    struct MarkStyle {
      AgentProvider provider = AgentProvider::unknown;
      bool telar_mark = false;
      bool monochrome = false;
      int theme = 0;
    };

    QImage coloredMark(const MarkStyle& style, int side, const QColor& color) {
      auto image = style.telar_mark ? ProviderArtwork::telar(side, style.monochrome, style.theme) : ProviderArtwork::image(style.provider, side);
      if (!image.isNull() && (style.monochrome || (!style.telar_mark && application::activity::ApplicationMark{.provider = style.provider}.followsTheme()))) {
        tint(image, color);
      }

      return image;
    }

    QImage coloredSymbol(const QString& symbol, int side, const QColor& color) {
      auto image = ProviderArtwork::symbol(symbol, side);
      if (!image.isNull()) {
        tint(image, color);
      }

      return image;
    }

  }

  ProviderMark::ProviderMark(QQuickItem* parent)
      : QQuickItem(parent),
        ancestors_(*this) {
    setFlag(ItemHasContents);
  }

  ProviderMark::~ProviderMark() = default;

  qreal ProviderMark::dimmedAlpha() noexcept {
    return application::activity::ApplicationMark::dimmed_alpha;
  }

  int ProviderMark::provider() const noexcept {
    return static_cast<int>(provider_);
  }

  QColor ProviderMark::color() const {
    return color_;
  }

  qreal ProviderMark::ratio() const noexcept {
    return ratio_;
  }

  void ProviderMark::setProvider(int provider) {
    const auto value = static_cast<AgentProvider>(provider);
    if (provider_ != value) {
      provider_ = value;
      dirty_ = true;
      emit providerChanged();
      update();
    }
  }

  bool ProviderMark::monochrome() const noexcept {
    return monochrome_;
  }

  void ProviderMark::setMonochrome(bool monochrome) {
    if (monochrome_ != monochrome) {
      monochrome_ = monochrome;
      dirty_ = true;
      emit monochromeChanged();
      update();
    }
  }

  int ProviderMark::theme() const noexcept {
    return theme_;
  }

  void ProviderMark::setTheme(int theme) {
    if (theme_ != theme) {
      theme_ = theme;
      dirty_ = true;
      emit themeChanged();
      update();
    }
  }

  bool ProviderMark::telarMark() const noexcept {
    return telar_mark_;
  }

  void ProviderMark::setTelarMark(bool enabled) {
    if (telar_mark_ != enabled) {
      telar_mark_ = enabled;
      dirty_ = true;
      emit telarMarkChanged();
      update();
    }
  }

  QString ProviderMark::symbol() const {
    return symbol_;
  }

  void ProviderMark::setSymbol(const QString& symbol) {
    if (symbol_ != symbol) {
      symbol_ = symbol;
      dirty_ = true;
      emit symbolChanged();
      update();
    }
  }

  void ProviderMark::setColor(const QColor& color) {
    if (color_ != color) {
      color_ = color;
      dirty_ = true;
      emit colorChanged();
      update();
    }
  }

  void ProviderMark::setRatio(qreal ratio) {
    if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
      ratio_ = ratio;
      dirty_ = true;
      emit ratioChanged();
      update();
    }
  }

  QSGNode* ProviderMark::updatePaintNode(QSGNode* previous, [[maybe_unused]] UpdatePaintNodeData* data) {
    std::unique_ptr<ProviderNode> node{dynamic_cast<ProviderNode*>(previous)};

    if (window() == nullptr || width() <= 0 || height() <= 0 || (provider_ == AgentProvider::unknown && !telar_mark_ && symbol_.isEmpty())) {
      return nullptr;
    }

    const auto scale = window()->effectiveDevicePixelRatio();
    // Rasterized at twice the size it is drawn, with mipmaps, so a reduced, rotated or
    // scaled mark stays smooth.
    constexpr qreal supersample = 2;
    const auto wanted = static_cast<float>(std::round(std::max(width(), height()) * scale * supersample));
    const auto side = static_cast<int>(std::clamp(wanted, static_cast<float>(application::activity::ApplicationMark::minimum_cell), static_cast<float>(application::activity::ApplicationMark::maximum_cell)));

    if (!node) {
      node = std::make_unique<ProviderNode>();
    }

    if (dirty_ || !node->texture || node->side != side) {
      const MarkStyle style{
          .provider = provider_,
          .telar_mark = telar_mark_,
          .monochrome = monochrome_,
          .theme = theme_,
      };

      const auto pixels = symbol_.isEmpty() ? coloredMark(style, side, color_) : coloredSymbol(symbol_, side, color_);
      if (pixels.isNull()) {
        return nullptr;
      }

      std::unique_ptr<QSGTexture> texture{window()->createTextureFromImage(pixels, QQuickWindow::TextureHasMipmaps)};
      if (!texture) {
        return nullptr;
      }

      texture->setMipmapFiltering(QSGTexture::Linear);
      node->image.setTexture(texture.get());
      node->texture = std::move(texture);
      node->image.setFiltering(QSGTexture::Linear);
      node->side = side;
      dirty_ = false;
    }

    const auto origin = mapToScene(QPointF{});
    const QPointF offset{(std::floor(origin.x() * scale) / scale) - origin.x(), (std::floor(origin.y() * scale) / scale) - origin.y()};
    QMatrix4x4 transform;

    transform.translate(static_cast<float>(offset.x()), static_cast<float>(offset.y()));
    node->setMatrix(transform);
    node->image.setRect(QRectF{QPointF{}, size()});

    return node.release();
  }

  void ProviderMark::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    update();
  }

  void ProviderMark::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemParentHasChanged) {
      ancestors_.observe();
      update();
    }

    if (change == ItemDevicePixelRatioHasChanged) {
      update();
    }
  }

}
