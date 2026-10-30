#include "attachment_image.hpp"
#include <QImage>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <memory>
#include <utility>

namespace telar::gui::qt {

namespace {

class PreviewNode final : public QSGSimpleTextureNode {
public:
  bool synchronize(QQuickWindow &window, const QImage &image) {
    if (texture_ && cache_key_ == image.cacheKey()) {
      return true;
    }

    std::unique_ptr<QSGTexture> replacement{window.createTextureFromImage(image)};
    if (!replacement) {
      return false;
    }

    setTexture(replacement.get());
    texture_ = std::move(replacement);
    cache_key_ = image.cacheKey();
    setFiltering(QSGTexture::Linear);

    return true;
  }

private:
  std::unique_ptr<QSGTexture> texture_;
  qint64 cache_key_ = 0;
};

}

AttachmentImage::AttachmentImage(QQuickItem *parent)
    : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
}

QImage AttachmentImage::image() const {
  return image_;
}

void AttachmentImage::setImage(QImage image) {
  if (image_.cacheKey() == image.cacheKey()) {
    return;
  }

  image_ = std::move(image);
  emit imageChanged();
  update();
}

bool AttachmentImage::thumbnail() const noexcept {
  return thumbnail_;
}

void AttachmentImage::setThumbnail(bool thumbnail) {
  if (thumbnail_ != thumbnail) {
    thumbnail_ = thumbnail;
    emit imageChanged();
    update();
  }
}

QSGNode *AttachmentImage::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  std::unique_ptr<PreviewNode> node{dynamic_cast<PreviewNode *>(previous)};
  if (image_.isNull() || window() == nullptr || width() <= 0 || height() <= 0) {
    return nullptr;
  }

  if (!node) {
    node = std::make_unique<PreviewNode>();
  }

  if (!node->synchronize(*window(), image_)) {
    return nullptr;
  }
  node->setRect(boundingRect());
  constexpr qreal half_texel = 0.5;
  node->setSourceRect(thumbnail_ ? QRectF{half_texel, half_texel, static_cast<qreal>(image_.width() - 1), static_cast<qreal>(image_.height() - 1)} : QRectF{0, 0, static_cast<qreal>(image_.width()), static_cast<qreal>(image_.height())});

  return node.release();
}

}
