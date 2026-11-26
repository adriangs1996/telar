#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "image_resource.hpp"
#include "tbc/view.hpp"
#include <QObject>
#include <QQuickWindow>
#include <QTimer>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <tuple>
#include <utility>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  class GraphicsScene;

  struct ImagePlacementSource {
    QQuickItem* owner = nullptr;
    const application::terminal::graphics::GraphicsStore<Memory>* store = nullptr;
    QSizeF cell;
  };

  struct WindowImage {
    application::terminal::graphics::ImageTextureHandle handle = 0;
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
    explicit WindowImages(QQuickWindow& window);
    static WindowImages& forWindow(QQuickWindow& window);
    [[nodiscard]] static WindowImages* findWindow(const QQuickWindow& window) noexcept;
    void attach(GraphicsScene& scene) noexcept;
    void detach(GraphicsScene& scene) noexcept;
    void beginCatalogSnapshot() noexcept;
    void observeCatalog(const application::terminal::graphics::GraphicsStore<Memory>& store) noexcept;
    // The reach names the selection's declared limit.
    [[nodiscard]] tbc::val_static<ds::Option<LimitReach>> preparePlacements(std::span<const ImagePlacementSource> sources);
    [[nodiscard]] const application::terminal::graphics::ImagePlacementSelection& placements() const noexcept;
    [[nodiscard]] ds::Option<WindowImage> resolve(GraphicsScene& scene, const application::terminal::graphics::GraphicsStore<Memory>& store, ImageKey key);
    void append(GraphicsScene& scene, QSGNode& parent, application::terminal::graphics::ImageTextureHandle handle, const application::terminal::graphics::ImageGeometry& geometry);
    void requestUpdate(const GraphicsScene& scene);
    [[nodiscard]] WindowImageStatistics statistics() const noexcept;
    [[nodiscard]] bool empty() const noexcept;
    bool eventFilter(QObject* watched, QEvent* event) override;

  private:
    struct Resources {
      ds::Array<ImageResource, application::terminal::graphics::image_texture_capacity> images;
      void release(application::terminal::graphics::ImageTextureHandle handle) noexcept;
    };

    using Residency = application::terminal::graphics::ImageResidency<Resources>;
    using Image = application::terminal::graphics::GraphicsStore<Memory>::Image;

    struct CatalogRows {
      application::terminal::graphics::GraphicsLifetime lifetime;
      application::terminal::graphics::ImageTextureHandle first_row = 0;
    };

    struct PlacementSourceStamp {
      application::terminal::graphics::GraphicsLifetime lifetime;
      std::uint64_t revision = 0;
      application::terminal::graphics::ImageDisplayBox::Cell cell;

      bool operator==(const PlacementSourceStamp&) const noexcept = default;
    };

    static constexpr std::size_t cached_source_capacity = 64;
    static constexpr std::size_t catalog_bucket_capacity = application::terminal::graphics::image_texture_capacity * 2;

    [[nodiscard]] PlacementSourceStamp placementStamp(const ImagePlacementSource& source) const noexcept;
    [[nodiscard]] bool placementSourcesChanged(std::span<const ImagePlacementSource> sources) noexcept;
    void selectPlacements(std::span<const ImagePlacementSource> sources) noexcept;
    [[nodiscard]] bool placementHasExtent(application::terminal::graphics::GraphicsLifetime catalog, const GraphicsPlacement& placement, application::terminal::graphics::ImageSourceRect source, std::span<const ImagePlacementSource> views) const noexcept;
    void prepare();
    void finish();
    void admitDraws();
    void admitLayer(const QSGNode& layer, application::terminal::graphics::ImageDrawBudget& budget);
    void orderScenes();
    template <typename Use>
    void visitVisibleTextures(const Use& use) const noexcept;
    template <typename Use>
    void observeVisibleTextures(const Use& use) noexcept;
    void clear();
    void stopRendering();
    void scheduleTimer(std::uint32_t delay_ms);
    void cancelTimer();
    void wakeWaitingScenes() noexcept;
    void notifyReady(const GraphicsScene& scene, application::terminal::graphics::ImageTextureIdentity identity) noexcept;
    void requestImage(GraphicsScene& scene, const application::terminal::graphics::GraphicsStore<Memory>& store, const Image& image);
    void indexCatalogs() noexcept;
    [[nodiscard]] std::size_t catalogBucket(application::terminal::graphics::GraphicsLifetime lifetime) const noexcept;
    [[nodiscard]] bool upload(application::terminal::graphics::ImageTextureHandle handle, const Image& image);
    [[nodiscard]] bool canRetry(const Image& image, std::size_t retained_bytes) const noexcept;
    [[nodiscard]] ds::Option<WindowImage> newest(application::terminal::graphics::ImageTextureIdentity identity) const noexcept;

    QQuickWindow& window_;
    QTimer timer_;
    Resources resources_;
    tbc::val_self<Residency> residency_{resources_};
    application::terminal::graphics::ImagePlacementSelection placements_;
    ds::Array<PlacementSourceStamp, cached_source_capacity> placement_sources_{};
    std::size_t placement_source_count_ = 0;
    bool placement_sources_cached_ = false;
    bool placement_limit_reached_ = false;
    ds::Array<bool, Residency::capacity> retained_{};
    ds::Array<bool, Residency::capacity> visible_rows_{};
    ds::Array<CatalogRows, catalog_bucket_capacity> catalogs_{};
    ds::Array<application::terminal::graphics::ImageTextureHandle, Residency::capacity> next_catalog_row_{};
    ds::Array<std::uint16_t, Residency::capacity> occupied_catalog_buckets_{};
    std::size_t catalog_count_ = 0;
    GraphicsScene* first_scene_ = nullptr;
    std::uint64_t now_ns_ = 0;
    std::size_t global_retained_bytes_ = 0;
    std::size_t image_draws_ = 0;
    std::atomic<std::uint64_t> timer_deadline_ns_{0};
    std::uint64_t active_timer_deadline_ns_ = 0;
    std::atomic<bool> requested_visible_{false};
  };

}
