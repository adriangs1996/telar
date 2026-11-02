#include "graphics_scene.hpp"
#include "application/dependencies.hpp"
#include "core/geometry.hpp"
#include "graphics/image_draw_budget.hpp"
#include "graphics/image_residency.hpp"
#include "graphics/placeholder.hpp"
#include "graphics/placement.hpp"
#include "graphics/store.hpp"
#include "scene_nodes.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "terminal/screen.hpp"
#include "window_images.hpp"
#include <QQuickWindow>
#include <QSGTransformNode>
#include <QtCore/qsize.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qsgnode.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>

namespace telar::gui::qt {

GraphicsScene::GraphicsScene(ImageLayers layers) noexcept
    : layers_(layers) {}

GraphicsScene::~GraphicsScene() {
  clearNodes();
  if (images_) {
    images_->detach(*this);
  }
}

void GraphicsScene::clearNodes() noexcept {
  clearSceneChildren(*layers_.below_background);
  clearSceneChildren(*layers_.below_text);
  clearSceneChildren(*layers_.above_text);
  resolved_count_ = 0;
  draw_count_ = 0;
  invalidated_ = true;
}

void GraphicsScene::invalidate() noexcept {
  invalidated_ = true;
}

std::span<const GraphicsScene::ResolvedImage> GraphicsScene::resolvedImages() const noexcept {
  return {resolved_.data(), resolved_count_};
}

const WindowImage *GraphicsScene::texture(const GraphicsStore<ApplicationAllocator> &store, ImageKey key) {
  for (auto &entry : std::span{resolved_}.first(resolved_count_)) {
    if (entry.image_id == key.image_id) {
      return entry.texture ? &*entry.texture : nullptr;
    }
  }

  if (resolved_count_ == resolved_.size()) {
    return nullptr;
  }

  auto &entry = resolved_[resolved_count_++];
  entry = {.image_id = key.image_id, .texture = std::nullopt};
  entry.texture = images_->resolve(*this, store, key);
  return entry.texture ? &*entry.texture : nullptr;
}

QSGTransformNode &GraphicsScene::layer(std::int32_t z_index) const noexcept {
  if (z_index < below_background_limit) {
    return *layers_.below_background;
  }

  return z_index < 0 ? *layers_.below_text : *layers_.above_text;
}

void GraphicsScene::synchronize(QQuickItem &owner, const GraphicsStore<ApplicationAllocator> &store, const Screen<ApplicationAllocator> &screen, QSizeF cell, qreal scale) {
  auto *images = WindowImages::findWindow(*owner.window());
  if (images == nullptr) {
    throw std::logic_error{"Window image resources must be installed before synchronization"};
  }

  if (images_ != images) {
    if (images_) {
      images_->detach(*this);
    }

    images_ = images;
    images_->attach(*this);
    invalidated_ = true;
  }

  owner_ = &owner;
  images_->observeCatalog(store);
  const auto lifetime = store.lifetime();
  const Rect viewport{.width = static_cast<float>(owner.width()), .height = static_cast<float>(owner.height())};
  if (!invalidated_ && lifetime.cacheable() && graphics_lifetime_ == lifetime && graphics_revision_ == store.revision() && placement_revision_ == images_->placements().revision() && screen_revision_ == screen.revision() && cell_ == cell && scale_ == scale && viewport_ == viewport) {
    return;
  }

  clearNodes();
  graphics_lifetime_ = lifetime;
  waiting_ = false;
  retry_requested_ = false;

  std::array<GraphicsPlacement, GraphicsStore<ApplicationAllocator>::placement_capacity> placements;
  const auto count = store.placements().size();
  std::copy(store.placements().begin(), store.placements().end(), placements.begin());
  std::sort(placements.begin(), placements.begin() + count, placementOrder);
  const auto back = static_cast<std::int64_t>(screen.scroll().total_rows) - screen.rows() - screen.scroll().offset;
  cell_ = cell;
  scale_ = scale;
  viewport_ = viewport;
  draw_count_ = 0;
  const auto sorted = std::span{placements}.first(count);
  const auto below_text = std::ranges::lower_bound(sorted, below_background_limit, {}, &GraphicsPlacement::z_index);
  const auto above_text = std::ranges::lower_bound(sorted, 0, {}, &GraphicsPlacement::z_index);
  drawPlacements(store, {sorted.begin(), below_text}, back);
  drawPlacements(store, {below_text, above_text}, back);
  placeholders(store, screen);
  drawPlacements(store, {above_text, sorted.end()}, back);

  invalidated_ = retry_requested_;
  graphics_revision_ = store.revision();
  placement_revision_ = images_->placements().revision();
  screen_revision_ = screen.revision();
}

void GraphicsScene::append(QSGNode &parent, ImageTextureHandle handle, const ImageGeometry &geometry) {
  if (draw_count_ == ImageDrawBudget::capacity) {
    return;
  }

  const auto visible = geometry.clipped(viewport_);
  if (visible.destination.empty()) {
    return;
  }

  images_->append(*this, parent, handle, visible);
  ++draw_count_;
}

void GraphicsScene::drawPlacements(const GraphicsStore<ApplicationAllocator> &store, std::span<const GraphicsPlacement> placements, std::int64_t back) {
  for (const auto &placement : placements) {
    if (!images_->placements().contains(store.lifetime(), placement.virtual_id)) {
      continue;
    }

    const auto *image = store.findImage(placement.key);
    if (image == nullptr || placement.location != PlacementLocation::cell) {
      continue;
    }

    const auto *image_texture = texture(store, placement.key);
    if (image_texture == nullptr) {
      continue;
    }

    auto geometry = ImageGeometry::resolve(placement, image->description(), {.x = static_cast<float>(cell_.width()), .y = static_cast<float>(cell_.height())}, static_cast<float>(scale_));
    geometry.destination.y += static_cast<float>(static_cast<qreal>(back) * cell_.height());
    if (geometry.source.empty() || geometry.destination.empty()) {
      continue;
    }

    geometry.source = ImageGeometry::textureSource(geometry.source, image_texture->bounds);
    append(layer(placement.z_index), image_texture->handle, geometry);
  }
}

void GraphicsScene::drawPlaceholder(const GraphicsStore<ApplicationAllocator> &store, const PlaceholderRun &run, std::uint16_t row) {
  if (draw_count_ == ImageDrawBudget::capacity) {
    return;
  }

  for (const auto &placement : store.placements()) {
    if (placement.location != PlacementLocation::placeholders || placement.key.image_id != run.image_id || (run.placement_id != 0 && placement.placement_id != run.placement_id)) {
      continue;
    }

    if (!images_->placements().contains(store.lifetime(), placement.virtual_id)) {
      continue;
    }

    const auto *image = store.findImage(placement.key);
    if (image == nullptr) {
      continue;
    }

    const Point cell{.x = static_cast<float>(cell_.width()), .y = static_cast<float>(cell_.height())};
    const auto base = ImageGeometry::resolve(placement, image->description(), cell, static_cast<float>(scale_));
    auto geometry = placeholderGeometry(run, placement, base, cell, static_cast<float>(scale_));
    geometry.destination.y += static_cast<float>(row * cell_.height());
    if (geometry.source.empty() || geometry.destination.empty()) {
      return;
    }

    if (const auto *image_texture = texture(store, placement.key)) {
      geometry.source = ImageGeometry::remapSource(geometry.source, base.source, ImageGeometry::textureSource(base.source, image_texture->bounds));
      append(*layers_.below_text, image_texture->handle, geometry);
    }

    return;
  }
}

void GraphicsScene::placeholders(const GraphicsStore<ApplicationAllocator> &store, const Screen<ApplicationAllocator> &screen) {
  const auto has_placeholders = std::any_of(store.placements().begin(), store.placements().end(), [](const auto &placement) {
    return placement.location == PlacementLocation::placeholders;
  });
  if (!has_placeholders) {
    return;
  }

  for (std::uint16_t row_index = 0; row_index < screen.rows(); ++row_index) {
    placeholderRow(store, screen.row(row_index), row_index);
  }
}

void GraphicsScene::placeholderRow(const GraphicsStore<ApplicationAllocator> &store, std::span<const CellValue> row, std::uint16_t row_index) {
  std::optional<PlaceholderRun> run;
  for (std::size_t column = 0; column < row.size(); ++column) {
    const auto placeholder = parsePlaceholder(row[column]);
    if (!placeholder) {
      if (run) {
        drawPlaceholder(store, *run, row_index);
        run.reset();
      }

      continue;
    }

    if (run && run->extend(*placeholder)) {
      continue;
    }

    if (run) {
      drawPlaceholder(store, *run, row_index);
    }

    run = PlaceholderRun::begin(*placeholder, static_cast<std::uint32_t>(column));
  }

  if (run) {
    drawPlaceholder(store, *run, row_index);
  }
}

}
