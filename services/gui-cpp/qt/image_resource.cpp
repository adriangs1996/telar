#include "image_resource.hpp"
#include "graphics/image_draw_budget.hpp"
#include "graphics/image_residency.hpp"
#include "graphics/placement.hpp"
#include "graphics_scene.hpp"
#include "scene_nodes.hpp"
#include <QImage>
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGNode>
#include <QSGOpacityNode>
#include <QSGTexture>
#include <QSize>
#include <QtCore/qtypes.h>
#include <memory>
#include <rhi/qrhi.h>
#include <tuple>
#include <utility>

namespace telar::gui::qt {

class UploadTexture final : public QSGTexture {
public:
  UploadTexture(std::unique_ptr<QSGTexture> texture, QImage pixels)
      : texture_(std::move(texture)),
        pixels_(std::move(pixels)) {}

  [[nodiscard]] qint64 comparisonKey() const override {
    return texture_->comparisonKey();
  }

  [[nodiscard]] QRhiTexture *rhiTexture() const override {
    return texture_->rhiTexture();
  }

  [[nodiscard]] QSize textureSize() const override {
    return texture_->textureSize();
  }

  [[nodiscard]] bool hasAlphaChannel() const override {
    return true;
  }

  [[nodiscard]] bool hasMipmaps() const override {
    return false;
  }

  void commitTextureOperations([[maybe_unused]] QRhi *rhi, QRhiResourceUpdateBatch *updates) override {
    if (!pixels_.isNull()) {
      updates->uploadTexture(rhiTexture(), pixels_);
      pixels_ = {};
    }
  }

  void replace(QImage pixels) noexcept {
    pixels_ = std::move(pixels);
  }

private:
  std::unique_ptr<QSGTexture> texture_;
  QImage pixels_;
};

class ImageDrawNode final : public QSGOpacityNode {
public:
  ImageDrawNode(QQuickWindow &window, ImageResource &resource, GraphicsScene &scene, ImageTextureHandle handle, const ImageGeometry &geometry)
      : resource_(&resource),
        scene_(scene),
        handle_(handle),
        next_(resource.first_node_) {
    setOpacity(0);
    auto node = createSceneImage(window);
    node->setTexture(resource_->texture_.get());
    node->setOwnsTexture(false);
    node->setFiltering(QSGTexture::Linear);
    const auto &source = geometry.source;
    const auto &destination = geometry.destination;
    node->setSourceRect({source.x, source.y, source.width, source.height});
    node->setRect({destination.x, destination.y, destination.width, destination.height});
    adoptSceneNode(*this, std::move(node));

    if (next_ != nullptr) {
      next_->previous_ = this;
    }

    resource_->first_node_ = this;
  }

  ~ImageDrawNode() override {
    if (resource_ == nullptr) {
      return;
    }

    if (previous_ != nullptr) {
      previous_->next_ = next_;
    } else {
      resource_->first_node_ = next_;
    }

    if (next_ != nullptr) {
      next_->previous_ = previous_;
    }
  }

  ImageDrawNode(const ImageDrawNode &) = delete;
  ImageDrawNode &operator=(const ImageDrawNode &) = delete;
  ImageDrawNode(ImageDrawNode &&) = delete;
  ImageDrawNode &operator=(ImageDrawNode &&) = delete;

  void invalidate() noexcept {
    scene_.invalidate();
  }

  [[nodiscard]] ImageTextureHandle admit(ImageDrawBudget &budget) noexcept {
    const auto admitted = budget.take();
    setOpacity(admitted ? 1 : 0);

    return admitted ? handle_ : 0;
  }

private:
  friend class ImageResource;
  ImageResource *resource_;
  GraphicsScene &scene_;
  ImageTextureHandle handle_;
  ImageDrawNode *previous_ = nullptr;
  ImageDrawNode *next_;
};

ImageResource::~ImageResource() {
  clear();
}

bool ImageResource::upload(QQuickWindow &window, const QImage &pixels) {
  detachNodes();
  if (window.rhi() == nullptr) {
    clear();
    texture_.reset(window.createTextureFromImage(pixels.copy()));
    usage_.allocations += texture_ != nullptr ? 1 : 0;
    return texture_ != nullptr;
  }

  auto owned_pixels = pixels.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
  if (owned_pixels.isNull()) {
    clear();
    return false;
  }

  if (upload_texture_ != nullptr && upload_texture_->textureSize() == pixels.size()) {
    upload_texture_->replace(std::move(owned_pixels));
    ++usage_.rewrites;
    return true;
  }

  clear();
  std::unique_ptr<QRhiTexture> native{window.rhi()->newTexture(QRhiTexture::RGBA8, pixels.size())};
  if (!native || !native->create()) {
    return false;
  }

  std::unique_ptr<QSGTexture> wrapped{window.createTextureFromRhiTexture(native.get(), QQuickWindow::TextureHasAlphaChannel)};
  if (!wrapped) {
    return false;
  }

  std::ignore = native.release();
  auto uploaded = std::make_unique<UploadTexture>(std::move(wrapped), std::move(owned_pixels));
  upload_texture_ = uploaded.get();
  texture_ = std::move(uploaded);
  ++usage_.allocations;
  return true;
}

void ImageResource::append(QQuickWindow &window, QSGNode &parent, GraphicsScene &scene, ImageTextureHandle handle, const ImageGeometry &geometry) {
  adoptSceneNode(parent, std::make_unique<ImageDrawNode>(window, *this, scene, handle, geometry));
}

ImageTextureHandle ImageResource::admit(QSGNode &node, ImageDrawBudget &budget) noexcept {
  auto *draw = dynamic_cast<ImageDrawNode *>(&node);

  return draw != nullptr ? draw->admit(budget) : 0;
}

void ImageResource::detachNodes() noexcept {
  while (first_node_ != nullptr) {
    std::unique_ptr<ImageDrawNode> node{std::exchange(first_node_, first_node_->next_)};
    if (first_node_ != nullptr) {
      first_node_->previous_ = nullptr;
    }

    node->resource_ = nullptr;
    node->invalidate();
    if (node->parent() != nullptr) {
      node->parent()->removeChildNode(node.get());
    }
  }
}

void ImageResource::clear() noexcept {
  detachNodes();
  usage_.releases += texture_ != nullptr ? 1 : 0;
  upload_texture_ = nullptr;
  texture_.reset();
}

bool ImageResource::empty() const noexcept {
  return texture_ == nullptr;
}

ImageResourceUsage ImageResource::usage() const noexcept {
  return usage_;
}

}
