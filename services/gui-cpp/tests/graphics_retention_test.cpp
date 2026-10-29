#include "assertions.hpp"
#include "core/memory.hpp"
#include "graphics/store.hpp"
#include "graphics/texture_cache.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <optional>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

constexpr std::uint32_t image_side = 2;
constexpr std::size_t image_bytes = std::size_t{image_side} * image_side * 4;
constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};
constexpr std::array<Byte, image_bytes> pixels{};

ImageDescription description(std::uint64_t generation) {
  return {.key = {.image_id = 1, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = image_bytes};
}

template <typename Store>
void complete(Store &store, const ImageDescription &image) {
  store.image({.header = header, .image = image});
  store.chunk({.header = header, .key = image.key, .bytes = pixels});
}

void supersededReferencedMetadataSurvivesCompletion() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  const auto previous = description(1);
  const auto current = description(2);
  complete(store, previous);
  store.placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1}});
  complete(store, current);
  const auto *retained = store.findImage(previous.key);
  require(retained != nullptr && retained->ready(), "a replacement must preserve the exact metadata and bytes of generations still referenced by placements");
  require(store.readyImage(previous.key)->description().key.generation == current.key.generation, "a referenced old placement must select the newest active completed generation for upload");
  require(budget.used == 2 * image_bytes && store.takeCredit() == 0, "retained generations must stay charged until their last placement is removed");
}

void deletingAVirtualPlacementReleasesItsRetiredGeneration() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  const auto previous = description(1);
  const auto current = description(2);
  complete(store, previous);
  store.placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1, .placement_id = 1}});
  complete(store, current);
  store.erase(GraphicsDeletePlacement{.header = header, .key = current.key, .virtual_id = 1, .placement_id = 0});
  require(store.placements().empty(), "the runtime virtual identity must remove a placement independently of its image generation and child-facing identity");
  require(store.findImage(previous.key) == nullptr && budget.used == image_bytes && store.takeCredit() == image_bytes, "removing a placement must collect its unreferenced retired generation exactly once");
}

void anUnreferencedReplacementReleasesPixelsAtItsHeader() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  const auto previous = description(1);
  const auto current = description(2);
  complete(store, previous);
  store.image({.header = header, .image = current});
  require(store.findImage(previous.key) == nullptr, "an unreferenced superseded generation must release CPU pixels when the next header arrives");
  require(store.readyImage(current.key) == nullptr, "a texture stand-in must belong to the presentation cache rather than the upload catalog");
  require(budget.used == image_bytes && store.takeCredit() == image_bytes, "a new transfer must not retain an unreferenced previous allocation");
}

void presentationKeepsAStandInAndMemoizesFailedUploads() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  ImageTextureCache<std::optional<std::uint64_t>, decltype(store)::image_capacity> cache;
  std::size_t uploads = 0;
  bool fail_upload = false;
  const auto upload = [&](const auto &image) -> std::optional<std::uint64_t> {
    ++uploads;

    return fail_upload ? std::nullopt : std::optional{image.description().key.generation};
  };
  const auto previous = description(1);
  const auto current = description(2);
  complete(store, previous);
  store.placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1}});
  cache.beginFrame(store);
  require(cache.resolve(store, previous.key, upload)->generation == 1, "a completed generation must upload when first presented");
  cache.endFrame();

  store.image({.header = header, .image = current});
  store.placement({.header = header, .placement = {.key = current.key, .virtual_id = 1}});
  cache.beginFrame(store);
  require(cache.resolve(store, current.key, upload)->generation == 1 && uploads == 1, "a new placement must retain the previous texture while its transfer is incomplete");
  cache.endFrame();
  store.chunk({.header = header, .key = current.key, .bytes = pixels});
  fail_upload = true;
  cache.beginFrame(store);
  require(cache.resolve(store, current.key, upload)->generation == 1 && uploads == 2, "a failed replacement upload must leave the previous texture drawable");
  require(cache.resolve(store, current.key, upload)->generation == 1 && uploads == 2, "a failed generation must not retry for each placement or repaint");
  cache.endFrame();

  fail_upload = false;
  const auto next = description(3);
  complete(store, next);
  cache.beginFrame(store);
  require(cache.resolve(store, current.key, upload)->generation == next.key.generation && uploads == 3, "a newer completed generation must clear a memoized upload failure");
  cache.endFrame();
}

void aNewStoreLifetimeCannotReuseAnOldTexture() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  ImageTextureCache<std::optional<std::size_t>, decltype(store)::image_capacity> cache;
  std::size_t uploads = 0;
  const auto upload = [&](const auto &) -> std::optional<std::size_t> {
    return ++uploads;
  };
  const auto image = description(1);
  for (std::size_t lifetime = 0; lifetime < 2; ++lifetime) {
    complete(store, image);
    store.placement({.header = header, .placement = {.key = image.key, .virtual_id = 1}});
    cache.beginFrame(store);
    require(cache.resolve(store, image.key, upload)->resource == lifetime + 1, "reattaching a pane must upload its pixels even when the runtime reuses an image key");
    cache.endFrame();
    store.detach();
  }
}

void invalidHeadersPreserveTheExistingGeneration() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  const auto previous = description(1);
  complete(store, previous);
  std::array<ImageDescription, 4> invalid;
  invalid.fill(description(2));
  invalid[0].key.image_id = 0;
  invalid[1].key.generation = 0;
  invalid[2].width = 0;
  invalid[3].byte_len = 0;
  for (const auto &image : invalid) {
    bool rejected = false;
    try {
      store.image({.header = header, .image = image});
    } catch (const EncodingError &) {
      rejected = true;
    }

    require(rejected && store.readyImage(previous.key) != nullptr && budget.used == image_bytes, "the catalog API must validate every header before retiring existing pixels, even without a wire decoder");
  }
}

void aFullTextureCacheCanReplaceADisplayedGeneration() {
  SystemAllocator memory;
  GraphicsBudget budget;
  GraphicsStore store{memory, budget};
  constexpr std::size_t cache_capacity = 2;
  ImageTextureCache<std::optional<std::uint64_t>, cache_capacity> cache;
  std::size_t uploads = 0;
  const auto upload = [&](const auto &image) -> std::optional<std::uint64_t> {
    ++uploads;

    return image.description().key.generation;
  };
  const auto first = description(1);
  auto second = description(1);
  second.key.image_id = 2;
  complete(store, first);
  complete(store, second);
  store.placement({.header = header, .placement = {.key = first.key, .virtual_id = 1}});
  store.placement({.header = header, .placement = {.key = second.key, .virtual_id = 2}});
  cache.beginFrame(store);
  require(cache.resolve(store, first.key, upload) != nullptr && cache.resolve(store, second.key, upload) != nullptr, "each displayed image must occupy one cache slot");
  cache.endFrame();
  complete(store, description(2));
  cache.beginFrame(store);
  require(cache.resolve(store, first.key, upload)->generation == 2, "a full cache must replace a generation without needing an additional free slot");
  require(cache.resolve(store, second.key, upload)->generation == 1 && uploads == 3, "replacing one image must preserve other textures without uploading them again");
  cache.endFrame();
}

void aReconstructedStoreAtTheSameAddressCannotReuseAnOldTexture() {
  SystemAllocator memory;
  GraphicsBudget budget;
  using Store = GraphicsStore<SystemAllocator>;
  std::optional<Store> catalog;
  ImageTextureCache<std::optional<std::size_t>, Store::image_capacity> cache;
  std::size_t uploads = 0;
  const auto upload = [&](const auto &) -> std::optional<std::size_t> {
    return ++uploads;
  };
  const auto image = description(1);
  for (std::size_t lifetime = 0; lifetime < 2; ++lifetime) {
    auto &store = catalog.emplace(memory, budget);
    complete(store, image);
    store.placement({.header = header, .placement = {.key = image.key, .virtual_id = 1}});
    cache.beginFrame(store);
    require(cache.resolve(store, image.key, upload)->resource == lifetime + 1, "reconstructing a catalog in the same storage must not reuse a texture from the destroyed catalog");
    cache.endFrame();
    catalog.reset();
  }
}

}

int main() {
  try {
    supersededReferencedMetadataSurvivesCompletion();
    deletingAVirtualPlacementReleasesItsRetiredGeneration();
    anUnreferencedReplacementReleasesPixelsAtItsHeader();
    presentationKeepsAStandInAndMemoizesFailedUploads();
    aNewStoreLifetimeCannotReuseAnOldTexture();
    invalidHeadersPreserveTheExistingGeneration();
    aFullTextureCacheCanReplaceADisplayedGeneration();
    aReconstructedStoreAtTheSameAddressCannotReuseAnOldTexture();
    std::cout << "gui-graphics-retention: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-graphics-retention: " << error.what() << '\n';

    return 1;
  }
}
