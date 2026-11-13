#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cmath>
#include "telar_client/serializers/telar_messages.hpp"
#include <cstddef>
#include <optional>
#include <type_traits>
#include "telar_client/codecs/telar_wire.hpp"
#include <iostream>

#include "core/memory.hpp"


import telar.gui.graphics.texture_cache;

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

}

int main() {
  try {
    supersededReferencedMetadataSurvivesCompletion();
    deletingAVirtualPlacementReleasesItsRetiredGeneration();
    anUnreferencedReplacementReleasesPixelsAtItsHeader();
    invalidHeadersPreserveTheExistingGeneration();
    std::cout << "gui-graphics-retention: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-graphics-retention: " << error.what() << '\n';

    return 1;
  }
}
