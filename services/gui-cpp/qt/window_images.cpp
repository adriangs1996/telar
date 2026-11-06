#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "window_images.hpp"
#include "../application/dependencies.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "deadline_timer.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <limits>
#include <cstddef>
#include <atomic>
#include "telar_config/graphics/limits.hpp"
#include <array>
#include <concepts>
#include <optional>
#include <span>
#include <string_view>
#include <tuple>
#include <utility>
#include "../core/memory.hpp"
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "graphics_scene.hpp"
#include "image_resource.hpp"
#include "scene_nodes.hpp"
#include <QEvent>
#include <QImage>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <bit>
#include <memory>

#include "application/dependencies.hpp"


import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.graphics.texture_cache;
import telar.gui.platform.profile_file;

namespace telar::gui::qt {

void WindowImages::Resources::release(ImageTextureHandle handle) noexcept {
  images[handle - 1].clear();
}

WindowImages::WindowImages(QQuickWindow &window)
    : QObject(&window),
      window_(window),
      timer_(this) {
  requested_visible_.store(window_.isVisible() && window_.visibility() != QWindow::Minimized, std::memory_order_relaxed);
  window_.installEventFilter(this);
  timer_.setObjectName(QStringLiteral("imageResidencyDeadline"));
  timer_.setSingleShot(true);
  timer_.setTimerType(Qt::PreciseTimer);
  connect(&timer_, &QTimer::timeout, this, [this] {
    auto expected = active_timer_deadline_ns_;
    timer_deadline_ns_.compare_exchange_strong(expected, 0, std::memory_order_relaxed);
    active_timer_deadline_ns_ = 0;
    window_.update();
  });
  connect(&window_, &QQuickWindow::beforeSynchronizing, this, &WindowImages::prepare, Qt::DirectConnection);
  connect(&window_, &QQuickWindow::afterSynchronizing, this, &WindowImages::finish, Qt::DirectConnection);
  connect(&window_, &QQuickWindow::sceneGraphAboutToStop, this, &WindowImages::stopRendering, Qt::DirectConnection);
  connect(&window_, &QQuickWindow::sceneGraphInvalidated, this, &WindowImages::clear, Qt::DirectConnection);
}

bool WindowImages::eventFilter(QObject *watched, QEvent *event) {
  if (watched == &window_ && (event->type() == QEvent::Expose || event->type() == QEvent::Show || event->type() == QEvent::Hide || event->type() == QEvent::WindowStateChange || event->type() == QEvent::PlatformSurface)) {
    requested_visible_.store(window_.isVisible() && window_.visibility() != QWindow::Minimized, std::memory_order_relaxed);
  }

  return QObject::eventFilter(watched, event);
}

WindowImages &WindowImages::forWindow(QQuickWindow &window) {
  if (auto *images = findWindow(window)) {
    return *images;
  }

  return *std::make_unique<WindowImages>(window).release();
}

WindowImages *WindowImages::findWindow(const QQuickWindow &window) noexcept {
  for (auto *child : window.children()) {
    if (auto *images = dynamic_cast<WindowImages *>(child)) {
      return images;
    }
  }

  return nullptr;
}

void WindowImages::attach(GraphicsScene &scene) noexcept {
  scene.next_ = first_scene_;
  if (first_scene_ != nullptr) {
    first_scene_->previous_ = &scene;
  }

  first_scene_ = &scene;
}

void WindowImages::detach(GraphicsScene &scene) noexcept {
  if (scene.previous_ != nullptr) {
    scene.previous_->next_ = scene.next_;
  } else {
    first_scene_ = scene.next_;
  }

  if (scene.next_ != nullptr) {
    scene.next_->previous_ = scene.previous_;
  }

  scene.previous_ = nullptr;
  scene.next_ = nullptr;
}

void WindowImages::beginCatalogSnapshot() noexcept {
  retained_.fill(false);
}

const ImagePlacementSelection &WindowImages::placements() const noexcept {
  return placements_;
}

WindowImages::PlacementSourceStamp WindowImages::placementStamp(const ImagePlacementSource &source) const noexcept {
  const Point cell{.x = static_cast<float>(source.cell.width()), .y = static_cast<float>(source.cell.height())};

  return {.lifetime = source.store->lifetime(), .revision = source.store->revision(), .cell = ImageGeometry::physicalCell(cell, static_cast<float>(window_.effectiveDevicePixelRatio()))};
}

bool WindowImages::placementSourcesChanged(std::span<const ImagePlacementSource> sources) noexcept {
  if (sources.size() > placement_sources_.size()) {
    placement_sources_cached_ = false;
    return true;
  }

  bool changed = !placement_sources_cached_ || placement_source_count_ != sources.size();
  for (std::size_t index = 0; index < sources.size(); ++index) {
    const auto stamp = placementStamp(sources[index]);
    changed = changed || placement_sources_[index] != stamp;
    placement_sources_[index] = stamp;
  }

  placement_source_count_ = sources.size();
  placement_sources_cached_ = true;

  return changed;
}

bool WindowImages::placementHasExtent(GraphicsLifetime catalog, const GraphicsPlacement &placement, ImageSourceRect source, std::span<const ImagePlacementSource> views) const noexcept {
  if (source.width == 0 || source.height == 0) {
    return false;
  }

  if (placement.location == PlacementLocation::placeholders) {
    return true;
  }

  return std::ranges::any_of(views, [this, catalog, &placement, source](const ImagePlacementSource &view) {
    if (view.store->lifetime() != catalog) {
      return false;
    }

    const auto box = ImageDisplayBox::resolve(placement, source, placementStamp(view).cell);
    return box.width != 0 && box.height != 0;
  });
}

void WindowImages::selectPlacements(std::span<const ImagePlacementSource> sources) noexcept {
  placements_.begin();
  for (std::size_t index = 0; index < sources.size(); ++index) {
    const auto &store = *sources[index].store;
    const auto lifetime = store.lifetime();
    if (std::ranges::any_of(sources.first(index), [lifetime](const ImagePlacementSource &source) {
          return source.store->lifetime() == lifetime;
        })) {
      continue;
    }

    for (const auto &placement : store.placements()) {
      const auto *image = store.findImage(placement.key);
      if (image != nullptr && placementHasExtent(lifetime, placement, ImageSourceRect::resolve(placement, image->description()), sources)) {
        placements_.keep({.identity = {.catalog = lifetime, .virtual_id = placement.virtual_id, .image_id = placement.key.image_id}, .layer = ImagePlacementSelection::layer(placement), .z_index = placement.z_index});
      }
    }
  }
}

std::optional<LimitReach> WindowImages::preparePlacements(std::span<const ImagePlacementSource> sources) {
  if (!placementSourcesChanged(sources)) {
    return std::nullopt;
  }

  selectPlacements(sources);
  if (placements_.finish()) {
    for (const auto &source : sources) {
      source.owner->update();
    }
  }

  const auto previously_reached = std::exchange(placement_limit_reached_, placements_.dropped() != 0);
  if (!placement_limit_reached_ || previously_reached) {
    return std::nullopt;
  }

  return LimitReach{.name = ImagePlacementSelection::limit_name, .noun = ImagePlacementSelection::limit_noun, .value = ImagePlacementSelection::capacity, .requested = placements_.selected().size() + placements_.dropped()};
}

void WindowImages::observeCatalog(const GraphicsStore<ApplicationAllocator> &store) noexcept {
  if (global_retained_bytes_ != store.globalRetainedBytes()) {
    global_retained_bytes_ = store.globalRetainedBytes();
    wakeWaitingScenes();
  }

  const auto lifetime = store.lifetime();
  auto handle = catalogs_[catalogBucket(lifetime)].first_row;
  while (handle != 0) {
    const auto row = handle - 1;
    const auto *state = residency_.state(handle);
    handle = next_catalog_row_[row];
    if (state == nullptr || state->identity.catalog != lifetime) {
      continue;
    }

    const auto *image = store.findImage({.image_id = state->identity.image_id, .generation = state->identity.generation});
    retained_[row] = image != nullptr && !image->retired();
  }
}

std::size_t WindowImages::catalogBucket(GraphicsLifetime lifetime) const noexcept {
  static_assert(std::has_single_bit(catalog_bucket_capacity));
  constexpr auto bucket_mask = catalog_bucket_capacity - 1;
  auto bucket = static_cast<std::size_t>(lifetime.value & bucket_mask);
  while (catalogs_[bucket].first_row != 0 && catalogs_[bucket].lifetime != lifetime) {
    bucket = (bucket + 1) & bucket_mask;
  }

  return bucket;
}

void WindowImages::indexCatalogs() noexcept {
  for (const auto bucket : std::span{occupied_catalog_buckets_}.first(catalog_count_)) {
    catalogs_[bucket] = {};
  }

  catalog_count_ = 0;
  for (const auto row : residency_.rows()) {
    const auto *state = residency_.state(Residency::handleOf(row));
    if (state == nullptr) {
      continue;
    }

    const auto bucket = catalogBucket(state->identity.catalog);
    auto &catalog = catalogs_[bucket];
    if (catalog.first_row == 0) {
      occupied_catalog_buckets_[catalog_count_++] = static_cast<std::uint16_t>(bucket);
    }

    next_catalog_row_[row] = catalog.first_row;
    catalog = {.lifetime = state->identity.catalog, .first_row = Residency::handleOf(row)};
  }
}

void WindowImages::prepare() {
  now_ns_ = std::max(now_ns_, platform::AwakeClock::nowNanoseconds());
  observeVisibleTextures([this](ImageTextureHandle handle) noexcept {
    residency_.keepWarm({.handle = handle, .now_ns = now_ns_});
  });

  const auto revision = residency_.revision();
  residency_.beginFrame(now_ns_);
  if (residency_.revision() != revision) {
    wakeWaitingScenes();
  }

  indexCatalogs();
}

template <typename Use>
void WindowImages::visitVisibleTextures(const Use &use) const noexcept {
  for (const auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    if (scene->owner_ == nullptr || !scene->owner_->isVisible()) {
      continue;
    }

    for (const auto &resolved : scene->resolvedImages()) {
      if (!resolved.texture || !placements_.containsImage(scene->graphics_lifetime_, resolved.image_id)) {
        continue;
      }

      const auto &texture = *resolved.texture;
      const auto *state = residency_.state(texture.handle);
      if (state != nullptr && state->stage == ImageTextureStage::ready && state->identity.catalog == scene->graphics_lifetime_ && state->identity.image_id == resolved.image_id && state->identity.generation == texture.generation) {
        use(texture.handle);
      }
    }
  }
}

template <typename Use>
void WindowImages::observeVisibleTextures(const Use &use) noexcept {
  if (empty()) {
    return;
  }

  std::array<bool, Residency::capacity> visible{};
  visitVisibleTextures([&](ImageTextureHandle handle) noexcept {
    visible[handle - 1] = true;
    use(handle);
  });

  bool released = false;
  for (std::size_t row = 0; row < visible.size(); ++row) {
    released = released || (visible_rows_[row] && !visible[row]);
  }

  visible_rows_ = visible;
  if (released) {
    wakeWaitingScenes();
  }
}

void WindowImages::finish() {
  admitDraws();
  observeVisibleTextures([this](ImageTextureHandle handle) noexcept {
    residency_.markNeeded(handle);
  });

  const auto revision = residency_.revision();
  residency_.sweep(std::span{retained_});

  if (residency_.revision() != revision) {
    wakeWaitingScenes();
  }

  for (const auto row : residency_.rows()) {
    const auto *state = residency_.state(Residency::handleOf(row));
    if (state != nullptr && state->stage == ImageTextureStage::spare) {
      resources_.images[row].detachNodes();
    }
  }

  const auto delay = residency_.wakeupAfter(now_ns_);
  for (const auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    if (scene->invalidated_ && scene->owner_ != nullptr && scene->owner_->isVisible()) {
      requestUpdate(*scene);
    }
  }

  scheduleTimer(delay);
}

void WindowImages::orderScenes() {
  auto *pending = std::exchange(first_scene_, nullptr);
  while (pending != nullptr) {
    auto *scene = pending;
    pending = scene->next_;
    auto *next = first_scene_;
    GraphicsScene *previous = nullptr;
    while (next != nullptr && !sceneNodePrecedes(*scene->layers_.below_background, *next->layers_.below_background)) {
      previous = next;
      next = next->next_;
    }

    scene->previous_ = previous;
    scene->next_ = next;
    if (previous != nullptr) {
      previous->next_ = scene;
    } else {
      first_scene_ = scene;
    }

    if (next != nullptr) {
      next->previous_ = scene;
    }
  }
}

void WindowImages::admitDraws() {
  std::size_t candidates = 0;
  for (const auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    if (scene->owner_ != nullptr && scene->owner_->isVisible()) {
      candidates += scene->draw_count_;
    }
  }

  if (candidates > ImageDrawBudget::capacity) {
    orderScenes();
  }

  ImageDrawBudget budget;
  for (const auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    if (scene->owner_ == nullptr || !scene->owner_->isVisible()) {
      continue;
    }

    for (const auto *layer : {scene->layers_.below_background, scene->layers_.below_text, scene->layers_.above_text}) {
      admitLayer(*layer, budget);
    }
  }

  image_draws_ = budget.used();
}

void WindowImages::admitLayer(const QSGNode &layer, ImageDrawBudget &budget) {
  for (auto *node = layer.firstChild(); node != nullptr; node = node->nextSibling()) {
    if (const auto handle = ImageResource::admit(*node, budget); handle != 0) {
      residency_.noteDrawn(handle);
    }
  }
}

void WindowImages::scheduleTimer(std::uint32_t delay_ms) {
  const auto armed = timer_deadline_ns_.load(std::memory_order_relaxed);
  if (delay_ms == 0) {
    if (armed != 0) {
      cancelTimer();
    }

    return;
  }

  constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
  const auto duration = static_cast<std::uint64_t>(delay_ms) * nanoseconds_per_millisecond;
  const auto deadline = now_ns_ + std::min(duration, std::numeric_limits<std::uint64_t>::max() - now_ns_);
  if (armed != 0 && armed <= deadline) {
    return;
  }

  timer_deadline_ns_.store(deadline, std::memory_order_relaxed);
  QTimer::singleShot(0, this, [this, deadline] {
    if (timer_deadline_ns_.load(std::memory_order_relaxed) == deadline) {
      active_timer_deadline_ns_ = deadline;
      scheduleDeadline(timer_, deadline, platform::AwakeClock::nowNanoseconds());
    }
  });
}

void WindowImages::cancelTimer() {
  if (timer_deadline_ns_.exchange(0, std::memory_order_relaxed) == 0) {
    return;
  }

  QTimer::singleShot(0, this, [this] {
    if (timer_deadline_ns_.load(std::memory_order_relaxed) == 0) {
      timer_.stop();
      active_timer_deadline_ns_ = 0;
    }
  });
}

void WindowImages::clear() {
  residency_.clear();
  image_draws_ = 0;
  retained_.fill(false);
  visible_rows_.fill(false);
  for (const auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    requestUpdate(*scene);
  }

  scheduleTimer(0);
}

void WindowImages::stopRendering() {
  if (!requested_visible_.load(std::memory_order_relaxed)) {
    clear();
  }
}

void WindowImages::requestUpdate(const GraphicsScene &scene) {
  const auto owner = scene.owner_;
  QTimer::singleShot(0, this, [owner] {
    if (owner != nullptr) {
      owner->update();
    }
  });
}

void WindowImages::wakeWaitingScenes() noexcept {
  for (auto *scene = first_scene_; scene != nullptr; scene = scene->next_) {
    if (scene->waiting_) {
      scene->invalidate();
    }
  }
}

WindowImageStatistics WindowImages::statistics() const noexcept {
  WindowImageStatistics statistics{.frame = residency_.frame(), .resident_bytes = residency_.residentBytes(), .images = residency_.size(), .spares = residency_.spares(), .uploads_started = residency_.uploadsStarted(), .image_draws = image_draws_, .placements = placements_.selected().size(), .dropped_placements = placements_.dropped()};
  for (const auto &image : resources_.images) {
    const auto usage = image.usage();
    statistics.resources.allocations += usage.allocations;
    statistics.resources.rewrites += usage.rewrites;
    statistics.resources.releases += usage.releases;
  }

  return statistics;
}

bool WindowImages::empty() const noexcept {
  return residency_.size() == 0;
}

bool WindowImages::upload(ImageTextureHandle handle, const Image &image) {
  const auto &description = image.description();
  const auto format = description.format == ImageFormat::rgba ? QImage::Format_RGBA8888 : QImage::Format_RGB888;
  constexpr int rgb_channels = 3;
  constexpr int rgba_channels = 4;
  const auto channels = description.format == ImageFormat::rgba ? rgba_channels : rgb_channels;
  const QImage pixels{image.pixels().data(), static_cast<int>(description.width), static_cast<int>(description.height), static_cast<qsizetype>(description.width) * channels, format};
  return resources_.images[handle - 1].upload(window_, pixels);
}

bool WindowImages::canRetry(const Image &image, std::size_t retained_bytes) const noexcept {
  if (residency_.uploadsStarted() == Residency::maximum_uploads) {
    return true;
  }

  const auto &description = image.description();
  constexpr std::size_t rgba_channels = 4;
  const auto bytes = static_cast<std::size_t>(description.width) * description.height * rgba_channels;
  if (retained_bytes > Residency::byte_capacity || bytes > Residency::byte_capacity - retained_bytes) {
    return false;
  }

  std::array<bool, Residency::capacity> visible{};
  visitVisibleTextures([&visible](ImageTextureHandle handle) noexcept {
    visible[handle - 1] = true;
  });

  return std::ranges::any_of(residency_.rows(), [this, &visible](auto row) {
    const auto *state = residency_.state(Residency::handleOf(row));
    return !visible[row] && state != nullptr && state->stage == ImageTextureStage::ready && state->used_frame + 1 == residency_.frame();
  });
}

std::optional<WindowImage> WindowImages::newest(ImageTextureIdentity identity) const noexcept {
  const auto handle = residency_.newestReady(identity);
  const auto *state = residency_.state(handle);
  if (state == nullptr || resources_.images[handle - 1].empty()) {
    return std::nullopt;
  }

  return WindowImage{.handle = handle, .generation = state->identity.generation, .bounds = {.width = static_cast<float>(state->size.width), .height = static_cast<float>(state->size.height)}};
}

void WindowImages::notifyReady(const GraphicsScene &scene, ImageTextureIdentity identity) noexcept {
  wakeWaitingScenes();
  for (auto *other = first_scene_; other != nullptr; other = other->next_) {
    if (other == &scene || other->graphics_lifetime_ != identity.catalog) {
      continue;
    }

    const auto needs_image = std::ranges::any_of(other->resolvedImages(), [&](const auto &resolved) {
      return resolved.image_id == identity.image_id;
    });
    if (needs_image) {
      other->invalidate();
    }
  }
}

void WindowImages::requestImage(GraphicsScene &scene, const GraphicsStore<ApplicationAllocator> &store, const Image &image) {
  const auto &description = image.description();
  const ImageTextureIdentity identity{.catalog = store.lifetime(), .image_id = description.key.image_id, .generation = description.key.generation};
  const auto admission = residency_.request({.identity = identity, .size = {.width = description.width, .height = description.height}, .retained_bytes = store.globalRetainedBytes(), .now_ns = now_ns_});
  if (admission.handle != 0) {
    retained_[admission.handle - 1] = !image.retired();
  }

  if (admission.upload) {
    const auto success = upload(admission.handle, image);
    residency_.complete(admission.handle, success, now_ns_);
    if (success) {
      notifyReady(scene, identity);
    } else {
      wakeWaitingScenes();
    }
  } else if (admission.handle == 0) {
    scene.waiting_ = true;
    if (canRetry(image, store.globalRetainedBytes())) {
      scene.retry_requested_ = true;
    }
  }
}

std::optional<WindowImage> WindowImages::resolve(GraphicsScene &scene, const GraphicsStore<ApplicationAllocator> &store, ImageKey key) {
  if (const auto *image = store.readyImage(key)) {
    requestImage(scene, store, *image);
  }

  return newest({.catalog = store.lifetime(), .image_id = key.image_id, .generation = key.generation});
}

void WindowImages::append(GraphicsScene &scene, QSGNode &parent, ImageTextureHandle handle, const ImageGeometry &geometry) {
  resources_.images[handle - 1].append(window_, parent, scene, handle, geometry);
}

}
