#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <type_traits>
#include <utility>

import telar.testing;
import telar.gui.features.terminal.graphics;
import telar.wire.graphics;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::graphics;

  constexpr std::uint32_t image_side = 2;
  constexpr std::size_t image_bytes = std::size_t{image_side} * image_side * 4;
  constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};
  constexpr ds::Array<Byte, image_bytes> pixels{};

  ImageDescription description(std::uint64_t generation) {
    return {.key = {.image_id = 1, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = image_bytes};
  }

  template <typename Store>
  void complete(Store& store, const ImageDescription& image) {
    store.image({.header = header, .image = image});
    store.chunk({.header = header, .key = image.key, .bytes = pixels});
  }

  void supersededReferencedMetadataSurvivesCompletion() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    const auto previous = description(1);
    const auto current = description(2);

    complete(store, previous);
    store.placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1}});
    complete(store, current);
    const auto* retained = store.findImage(previous.key);

    check(retained != nullptr && retained->ready(), "a replacement must preserve the exact metadata and bytes of generations still referenced by placements");
    check(store.readyImage(previous.key)->description().key.generation == current.key.generation, "a referenced old placement must select the newest active completed generation for upload");
    check(budget.used == 2 * image_bytes && store.takeCredit() == 0, "retained generations must stay charged until their last placement is removed");
  }

  void deletingAVirtualPlacementReleasesItsRetiredGeneration() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    const auto previous = description(1);
    const auto current = description(2);

    complete(store, previous);
    store.placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1, .placement_id = 1}});
    complete(store, current);
    store.erase(GraphicsDeletePlacement{.header = header, .key = current.key, .virtual_id = 1, .placement_id = 0});
    check(store.placements().empty(), "the runtime virtual identity must remove a placement independently of its image generation and child-facing identity");
    check(store.findImage(previous.key) == nullptr && budget.used == image_bytes && store.takeCredit() == image_bytes, "removing a placement must collect its unreferenced retired generation exactly once");
  }

  void anUnreferencedReplacementReleasesPixelsAtItsHeader() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    const auto previous = description(1);
    const auto current = description(2);

    complete(store, previous);
    store.image({.header = header, .image = current});
    check(store.findImage(previous.key) == nullptr, "an unreferenced superseded generation must release CPU pixels when the next header arrives");
    check(store.readyImage(current.key) == nullptr, "a texture stand-in must belong to the presentation cache rather than the upload catalog");
    check(budget.used == image_bytes && store.takeCredit() == image_bytes, "a new transfer must not retain an unreferenced previous allocation");
  }

  void invalidHeadersPreserveTheExistingGeneration() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;
    GraphicsStore store{memory, budget};
    const auto previous = description(1);

    complete(store, previous);
    ds::Array<ImageDescription, 4> invalid;

    invalid.fill(description(2));
    invalid.atMut(0).key.image_id = 0;
    invalid.atMut(1).key.generation = 0;
    invalid.atMut(2).width = 0;
    invalid.atMut(3).byte_len = 0;
    for (const auto& image : invalid) {
      bool rejected = false;

      try {
        store.image({.header = header, .image = image});
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected && store.readyImage(previous.key) != nullptr && budget.used == image_bytes, "the catalog API must validate every header before retiring existing pixels, even without a wire decoder");
    }
  }

  const telar::testing::Case case_superseded_referenced_metadata_survives_completion{"graphics_retention.superseded_referenced_metadata_survives_completion", supersededReferencedMetadataSurvivesCompletion};
  const telar::testing::Case case_deleting_a_virtual_placement_releases_its_retired_generation{"graphics_retention.deleting_a_virtual_placement_releases_its_retired_generation", deletingAVirtualPlacementReleasesItsRetiredGeneration};
  const telar::testing::Case case_an_unreferenced_replacement_releases_pixels_at_its_header{"graphics_retention.an_unreferenced_replacement_releases_pixels_at_its_header", anUnreferencedReplacementReleasesPixelsAtItsHeader};
  const telar::testing::Case case_invalid_headers_preserve_the_existing_generation{"graphics_retention.invalid_headers_preserve_the_existing_generation", invalidHeadersPreserveTheExistingGeneration};

}
