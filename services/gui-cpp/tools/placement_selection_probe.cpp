#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.tools.probe_io;
import telar.gui.graphics.texture_cache;

namespace {

using namespace telar;
using namespace telar::gui;

ImagePlacementSelection::Candidate readCandidate() {
  const GraphicsLifetime catalog{.value = probe::read<std::uint64_t>()};
  const auto virtual_id = probe::read<std::uint64_t>();
  const auto image_id = probe::read<std::uint32_t>();
  const auto placeholder = probe::read<std::uint8_t>() != 0;
  const GraphicsPlacement placement{.z_index = probe::read<std::int32_t>(), .location = placeholder ? PlacementLocation::placeholders : PlacementLocation::cell};

  return {.identity = {.catalog = catalog, .virtual_id = virtual_id, .image_id = image_id}, .layer = ImagePlacementSelection::layer(placement), .z_index = placement.z_index};
}

}

int main() {
  try {
    ImagePlacementSelection selection;
    for (auto value = std::getchar(); value != EOF; value = std::getchar()) {
      const auto count = probe::read<std::uint32_t>();
      selection.begin();
      for (std::uint32_t index = 0; index < count; ++index) {
        selection.keep(readCandidate());
      }

      probe::write(static_cast<std::uint8_t>(selection.finish()));
      probe::write(static_cast<std::uint32_t>(selection.selected().size()));
      probe::write(static_cast<std::uint32_t>(selection.dropped()));
      for (const auto &identity : selection.selected()) {
        probe::write(identity.catalog.value);
        probe::write(identity.virtual_id);
        probe::write(identity.image_id);
        probe::write(static_cast<std::uint8_t>(selection.contains(identity.catalog, identity.virtual_id)));
        probe::write(static_cast<std::uint8_t>(selection.containsImage(identity.catalog, identity.image_id)));
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
