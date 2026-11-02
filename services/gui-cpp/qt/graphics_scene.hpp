#pragma once

#include "application/dependencies.hpp"
#include "graphics/lifetime.hpp"
#include "graphics/placeholder.hpp"
#include "graphics/store.hpp"
#include "terminal/screen.hpp"
#include "window_images.hpp"
#include <QPointer>
#include <QQuickItem>
#include <QSGNode>
#include <QSGTexture>
#include <QSGTransformNode>
#include <QSizeF>
#include <array>
#include <limits>
#include <optional>
#include <span>

class QQuickWindow;

namespace telar::gui::qt {

struct ImageLayers {
  QSGTransformNode *below_background;
  QSGTransformNode *below_text;
  QSGTransformNode *above_text;
};

class GraphicsScene {
public:
  explicit GraphicsScene(ImageLayers layers) noexcept;
  ~GraphicsScene();
  GraphicsScene(const GraphicsScene &) = delete;
  GraphicsScene &operator=(const GraphicsScene &) = delete;
  GraphicsScene(GraphicsScene &&) = delete;
  GraphicsScene &operator=(GraphicsScene &&) = delete;
  void synchronize(QQuickItem &owner, const GraphicsStore<ApplicationAllocator> &store, const Screen<ApplicationAllocator> &screen, QSizeF cell, qreal scale);
  void invalidate() noexcept;
  void clearNodes() noexcept;

private:
  friend class WindowImages;
  static constexpr std::int32_t below_background_limit = std::numeric_limits<std::int32_t>::min() / 2;

  struct ResolvedImage {
    std::uint32_t image_id = 0;
    std::optional<WindowImage> texture;
  };

  [[nodiscard]] std::span<const ResolvedImage> resolvedImages() const noexcept;
  [[nodiscard]] const WindowImage *texture(const GraphicsStore<ApplicationAllocator> &store, ImageKey key);
  [[nodiscard]] QSGTransformNode &layer(std::int32_t z_index) const noexcept;
  void drawPlacements(const GraphicsStore<ApplicationAllocator> &store, std::span<const GraphicsPlacement> placements, std::int64_t back);
  void append(QSGNode &parent, ImageTextureHandle handle, const ImageGeometry &geometry);
  void drawPlaceholder(const GraphicsStore<ApplicationAllocator> &store, const PlaceholderRun &run, std::uint16_t row);
  void placeholders(const GraphicsStore<ApplicationAllocator> &store, const Screen<ApplicationAllocator> &screen);
  void placeholderRow(const GraphicsStore<ApplicationAllocator> &store, std::span<const CellValue> row, std::uint16_t row_index);

  ImageLayers layers_;
  QPointer<WindowImages> images_;
  QPointer<QQuickItem> owner_;
  GraphicsScene *previous_ = nullptr;
  GraphicsScene *next_ = nullptr;
  std::array<ResolvedImage, GraphicsStore<ApplicationAllocator>::image_capacity> resolved_;
  std::size_t resolved_count_ = 0;
  GraphicsLifetime graphics_lifetime_;
  std::uint64_t graphics_revision_ = 0;
  std::uint64_t placement_revision_ = 0;
  std::uint64_t screen_revision_ = 0;
  QSizeF cell_;
  Rect viewport_;
  qreal scale_ = 0;
  std::size_t draw_count_ = 0;
  bool invalidated_ = true;
  bool waiting_ = false;
  bool retry_requested_ = false;
};

}
