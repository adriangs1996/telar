#pragma once

#include "application/dependencies.hpp"
#include "core/geometry.hpp"
#include "graphics/display_box.hpp"
#include "graphics/image_draw_budget.hpp"
#include "graphics/image_residency.hpp"
#include "graphics/placement_selection.hpp"
#include "graphics/source_rect.hpp"
#include "graphics/store.hpp"
#include "image_resource.hpp"
#include <QObject>
#include <QQuickWindow>
#include <QTimer>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

class GraphicsScene;

struct ImagePlacementSource {
  QQuickItem *owner = nullptr;
  const GraphicsStore<ApplicationAllocator> *store = nullptr;
  QSizeF cell;
};

struct WindowImage {
  ImageTextureHandle handle = 0;
  std::uint64_t generation = 0;
  Rect bounds;
};

struct WindowImageStatistics {
  std::uint64_t frame = 0;
  std::size_t resident_bytes = 0;
  std::size_t images = 0;
  std::size_t spares = 0;
  std::size_t uploads_started = 0;
  std::size_t image_draws = 0;
  std::size_t placements = 0;
  std::size_t dropped_placements = 0;
  ImageResourceUsage resources{};
};

class WindowImages final : public QObject {
public:
  explicit WindowImages(QQuickWindow &window);
  static WindowImages &forWindow(QQuickWindow &window);
  [[nodiscard]] static WindowImages *findWindow(const QQuickWindow &window) noexcept;
  void attach(GraphicsScene &scene) noexcept;
  void detach(GraphicsScene &scene) noexcept;
  void beginCatalogSnapshot() noexcept;
  void observeCatalog(const GraphicsStore<ApplicationAllocator> &store) noexcept;
  [[nodiscard]] std::optional<LimitReach> preparePlacements(std::span<const ImagePlacementSource> sources);
  [[nodiscard]] const ImagePlacementSelection &placements() const noexcept;
  [[nodiscard]] std::optional<WindowImage> resolve(GraphicsScene &scene, const GraphicsStore<ApplicationAllocator> &store, ImageKey key);
  void append(GraphicsScene &scene, QSGNode &parent, ImageTextureHandle handle, const ImageGeometry &geometry);
  void requestUpdate(const GraphicsScene &scene);
  [[nodiscard]] WindowImageStatistics statistics() const noexcept;
  [[nodiscard]] bool empty() const noexcept;
  bool eventFilter(QObject *watched, QEvent *event) override;

private:
  struct Resources {
    std::array<ImageResource, image_texture_capacity> images;
    void release(ImageTextureHandle handle) noexcept;
  };

  using Residency = ImageResidency<Resources>;
  using Image = GraphicsStore<ApplicationAllocator>::Image;

  struct CatalogRows {
    GraphicsLifetime lifetime;
    ImageTextureHandle first_row = 0;
  };

  struct PlacementSourceStamp {
    GraphicsLifetime lifetime;
    std::uint64_t revision = 0;
    ImageDisplayBox::Cell cell;

    bool operator==(const PlacementSourceStamp &) const noexcept = default;
  };

  static constexpr std::size_t cached_source_capacity = 64;
  static constexpr std::size_t catalog_bucket_capacity = image_texture_capacity * 2;

  [[nodiscard]] PlacementSourceStamp placementStamp(const ImagePlacementSource &source) const noexcept;
  [[nodiscard]] bool placementSourcesChanged(std::span<const ImagePlacementSource> sources) noexcept;
  void selectPlacements(std::span<const ImagePlacementSource> sources) noexcept;
  [[nodiscard]] bool placementHasExtent(GraphicsLifetime catalog, const GraphicsPlacement &placement, ImageSourceRect source, std::span<const ImagePlacementSource> views) const noexcept;
  void prepare();
  void finish();
  void admitDraws();
  void admitLayer(const QSGNode &layer, ImageDrawBudget &budget);
  void orderScenes();
  template <typename Use>
  void visitVisibleTextures(const Use &use) const noexcept;
  template <typename Use>
  void observeVisibleTextures(const Use &use) noexcept;
  void clear();
  void stopRendering();
  void scheduleTimer(std::uint32_t delay_ms);
  void cancelTimer();
  void wakeWaitingScenes() noexcept;
  void notifyReady(const GraphicsScene &scene, ImageTextureIdentity identity) noexcept;
  void requestImage(GraphicsScene &scene, const GraphicsStore<ApplicationAllocator> &store, const Image &image);
  void indexCatalogs() noexcept;
  [[nodiscard]] std::size_t catalogBucket(GraphicsLifetime lifetime) const noexcept;
  [[nodiscard]] bool upload(ImageTextureHandle handle, const Image &image);
  [[nodiscard]] bool canRetry(const Image &image, std::size_t retained_bytes) const noexcept;
  [[nodiscard]] std::optional<WindowImage> newest(ImageTextureIdentity identity) const noexcept;

  QQuickWindow &window_;
  QTimer timer_;
  Resources resources_;
  Residency residency_{resources_};
  ImagePlacementSelection placements_;
  std::array<PlacementSourceStamp, cached_source_capacity> placement_sources_{};
  std::size_t placement_source_count_ = 0;
  bool placement_sources_cached_ = false;
  bool placement_limit_reached_ = false;
  std::array<bool, Residency::capacity> retained_{};
  std::array<bool, Residency::capacity> visible_rows_{};
  std::array<CatalogRows, catalog_bucket_capacity> catalogs_{};
  std::array<ImageTextureHandle, Residency::capacity> next_catalog_row_{};
  std::array<std::uint16_t, Residency::capacity> occupied_catalog_buckets_{};
  std::size_t catalog_count_ = 0;
  GraphicsScene *first_scene_ = nullptr;
  std::uint64_t now_ns_ = 0;
  std::size_t global_retained_bytes_ = 0;
  std::size_t image_draws_ = 0;
  std::atomic<std::uint64_t> timer_deadline_ns_{0};
  std::uint64_t active_timer_deadline_ns_ = 0;
  std::atomic<bool> requested_visible_{false};
};

}
