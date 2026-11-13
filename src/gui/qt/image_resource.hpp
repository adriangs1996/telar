#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include <QImage>
#include <QSGNode>
#include <QSGTexture>
#include <memory>

#pragma once


import telar.gui.graphics.texture_cache;
import telar.gui.graphics.placeholder;

class QQuickWindow;

namespace telar::gui::qt {

class GraphicsScene;
class ImageDrawNode;
class UploadTexture;

struct ImageResourceUsage {
  std::uint64_t allocations = 0;
  std::uint64_t rewrites = 0;
  std::uint64_t releases = 0;
};

class ImageResource {
public:
  ImageResource() = default;
  ~ImageResource();
  ImageResource(const ImageResource &) = delete;
  ImageResource &operator=(const ImageResource &) = delete;
  ImageResource(ImageResource &&) = delete;
  ImageResource &operator=(ImageResource &&) = delete;

  [[nodiscard]] bool upload(QQuickWindow &window, const QImage &pixels);
  void append(QQuickWindow &window, QSGNode &parent, GraphicsScene &scene, ImageTextureHandle handle, const ImageGeometry &geometry);
  [[nodiscard]] static ImageTextureHandle admit(QSGNode &node, ImageDrawBudget &budget) noexcept;
  void detachNodes() noexcept;
  void clear() noexcept;
  [[nodiscard]] bool empty() const noexcept;
  [[nodiscard]] ImageResourceUsage usage() const noexcept;

private:
  friend class ImageDrawNode;
  std::unique_ptr<QSGTexture> texture_;
  UploadTexture *upload_texture_ = nullptr;
  ImageDrawNode *first_node_ = nullptr;
  ImageResourceUsage usage_;
};

}
