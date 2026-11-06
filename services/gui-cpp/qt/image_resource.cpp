#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "image_resource.hpp"
#include <cstddef>
#include <atomic>
#include <cstdint>
#include <limits>
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <optional>
#include <span>
#include <cmath>
#include "telar_client/serializers/telar_messages.hpp"
#include "graphics_scene.hpp"
#include "scene_nodes.hpp"
#include <QImage>
#include <QRgb>
#include <QScopeGuard>
#include <QThread>
#include <QThreadPool>
#include <QtConcurrent/QtConcurrentRun>
#if (defined(__aarch64__))
#include <arm_neon.h>
#endif
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGNode>
#include <QSGOpacityNode>
#include <QSGTexture>
#include <QSize>
#include <QtCore/qtypes.h>
#include <QtCore/qtversionchecks.h>
#include <bit>
#include <cstring>
#include <memory>
#include <rhi/qrhi.h>
#include <tuple>
#include <utility>

#ifdef __aarch64__
#include <arm_neon.h>
#endif


import telar.gui.graphics.texture_cache;
import telar.gui.graphics.placeholder;

namespace telar::gui::qt {

namespace {

#ifdef __aarch64__
constexpr std::size_t vector_bytes = 16;
constexpr std::uint32_t alpha_mask = 0xff000000U;

// Alpha stays unchanged; the other lanes use Qt's exact integer rounding.
uint8x16_t premultiplied(uint8x16_t pixels) noexcept {
  constexpr std::array<std::uint8_t, vector_bytes> alpha_indices{3, 3, 3, 16, 7, 7, 7, 16, 11, 11, 11, 16, 15, 15, 15, 16};
  constexpr int channel_bits = 8;
  const auto alphas = vorrq_u8(vqtbl1q_u8(pixels, vld1q_u8(alpha_indices.data())), vreinterpretq_u8_u32(vdupq_n_u32(alpha_mask)));
  auto low = vmull_u8(vget_low_u8(pixels), vget_low_u8(alphas));
  auto high = vmull_high_u8(pixels, alphas);
  low = vsraq_n_u16(low, low, channel_bits);
  high = vsraq_n_u16(high, high, channel_bits);

  return vcombine_u8(vrshrn_n_u16(low, channel_bits), vrshrn_n_u16(high, channel_bits));
}

void convertRow(const std::uint8_t *input, std::uint8_t *output, int width) noexcept {
  constexpr std::size_t block_pixels = 32;
  constexpr std::size_t vector_pixels = vector_bytes / sizeof(QRgb);
  constexpr std::uint8_t channel_maximum = 255;
  int column = 0;
  for (; column + static_cast<int>(block_pixels) <= width; column += block_pixels) {
    std::array<uint8x16_t, block_pixels / vector_pixels> vectors{};
    auto all = vdupq_n_u8(channel_maximum);
    for (std::size_t index = 0; index < vectors.size(); ++index) {
      vectors[index] = vld1q_u8(input + (column * sizeof(QRgb)) + (index * vector_bytes));
      all = vandq_u8(all, vectors[index]);
    }

    if (vminvq_u32(vreinterpretq_u32_u8(all)) < alpha_mask) {
      for (auto &pixels : vectors) {
        pixels = premultiplied(pixels);
      }
    }

    for (std::size_t index = 0; index < vectors.size(); ++index) {
      vst1q_u8(output + (column * sizeof(QRgb)) + (index * vector_bytes), vectors[index]);
    }
  }

  for (; column < width; ++column) {
    QRgb pixel = 0;
    std::memcpy(&pixel, input + (column * sizeof(QRgb)), sizeof(pixel));
    pixel = qPremultiply(pixel);
    std::memcpy(output + (column * sizeof(QRgb)), &pixel, sizeof(pixel));
  }
}

QThreadPool &conversionWorkers() {
  struct Workers {
    QThreadPool pool;

    Workers() {
      constexpr int maximum_workers = 2;
      pool.setMaxThreadCount(std::clamp(QThread::idealThreadCount() - 1, 1, maximum_workers));
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
      pool.setServiceLevel(QThread::QualityOfService::High);
#endif
    }
  };
  thread_local Workers workers;

  return workers.pool;
}
#endif

// Copy and premultiply together. Queued uploads retain immutable destinations;
// workers finish before returning and write disjoint rows without QImage mutation.
QImage convertedPixels(const QImage &source, QImage &retained) {
#ifndef __aarch64__
  retained = {};
  return source.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
#else
  if (std::endian::native != std::endian::little || source.format() != QImage::Format_RGBA8888) {
    retained = {};
    return source.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
  }

  if (retained.size() != source.size() || !retained.isDetached()) {
    retained = QImage{source.size(), QImage::Format_RGBA8888_Premultiplied};
  }

  if (retained.isNull()) {
    return {};
  }

  const auto *input_bytes = source.constBits();
  auto *output_bytes = retained.bits();
  const auto input_stride = source.bytesPerLine();
  const auto output_stride = retained.bytesPerLine();
  const auto width = source.width();
  const auto height = source.height();
  const auto convert_rows = [&](int begin, int end) noexcept {
    for (int row = begin; row < end; ++row) {
      convertRow(input_bytes + (static_cast<qsizetype>(row) * input_stride), output_bytes + (static_cast<qsizetype>(row) * output_stride), width);
    }
  };
  constexpr qsizetype parallel_bytes = qsizetype{1024} * 1024;
  if (source.sizeInBytes() >= parallel_bytes && height > 1) {
    auto &workers = conversionWorkers();
    constexpr int parallel_parts = 3;
    if (workers.maxThreadCount() > 1 && height >= parallel_parts) {
      const auto first = height / parallel_parts;
      const auto second = first + first;
      auto first_future = QtConcurrent::run(&workers, [&] noexcept { convert_rows(first, second); });
      const auto finish_first = qScopeGuard([&] { first_future.waitForFinished(); });
      auto second_future = QtConcurrent::run(&workers, [&] noexcept { convert_rows(second, height); });
      const auto finish_second = qScopeGuard([&] { second_future.waitForFinished(); });
      convert_rows(0, first);
    } else {
      const auto middle = height / 2;
      auto future = QtConcurrent::run(&workers, [&] noexcept { convert_rows(middle, height); });
      const auto finish = qScopeGuard([&] { future.waitForFinished(); });
      convert_rows(0, middle);
    }
  } else {
    convert_rows(0, height);
  }

  return retained;
#endif
}

}

class UploadTexture final : public QSGTexture {
public:
  UploadTexture(std::unique_ptr<QSGTexture> texture, QImage pixels, QImage retained)
      : texture_(std::move(texture)),
        pixels_(std::move(pixels)),
        retained_(std::move(retained)) {}

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

  [[nodiscard]] bool replace(const QImage &source) {
    pixels_ = {};
    pixels_ = convertedPixels(source, retained_);
    return !pixels_.isNull();
  }

private:
  std::unique_ptr<QSGTexture> texture_;
  QImage pixels_;
  QImage retained_;
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

  if (upload_texture_ != nullptr && upload_texture_->textureSize() == pixels.size()) {
    if (!upload_texture_->replace(pixels)) {
      clear();
      return false;
    }

    ++usage_.rewrites;
    return true;
  }

  QImage retained;
  auto owned_pixels = convertedPixels(pixels, retained);
  if (owned_pixels.isNull()) {
    clear();
    return false;
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
  auto uploaded = std::make_unique<UploadTexture>(std::move(wrapped), std::move(owned_pixels), std::move(retained));
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
