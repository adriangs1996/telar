#pragma once

#include "probe_io.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>

namespace telar::gui::probe {

inline ImageKey readImageKey() {
  const auto image_id = probe::read<std::uint32_t>();

  return {.image_id = image_id, .generation = probe::read<std::uint64_t>()};
}

inline void writeImageKey(ImageKey key) {
  probe::write(key.image_id);
  probe::write(key.generation);
}

inline ImageDescription readImage() {
  const auto key = readImageKey();
  const auto format = static_cast<ImageFormat>(probe::read<std::uint8_t>());
  const auto width = probe::read<std::uint32_t>();
  const auto height = probe::read<std::uint32_t>();

  return {.key = key, .format = format, .width = width, .height = height, .byte_len = probe::read<std::uint64_t>()};
}

inline void writeImage(const ImageDescription &image) {
  writeImageKey(image.key);
  probe::write(static_cast<std::uint8_t>(image.format));
  probe::write(image.width);
  probe::write(image.height);
  probe::write(image.byte_len);
}

inline GraphicsPlacement readPlacement() {
  GraphicsPlacement placement;
  placement.key = readImageKey();
  placement.virtual_id = probe::read<std::uint64_t>();
  placement.placement_id = probe::read<std::uint32_t>();
  placement.x = probe::read<std::int32_t>();
  placement.y = probe::read<std::int32_t>();
  placement.source_x = probe::read<std::uint32_t>();
  placement.source_y = probe::read<std::uint32_t>();
  placement.source_width = probe::read<std::uint32_t>();
  placement.source_height = probe::read<std::uint32_t>();
  placement.columns = probe::read<std::uint32_t>();
  placement.rows = probe::read<std::uint32_t>();
  placement.offset_x = probe::read<std::uint32_t>();
  placement.offset_y = probe::read<std::uint32_t>();
  placement.z_index = probe::read<std::int32_t>();
  placement.location = static_cast<PlacementLocation>(probe::read<std::uint8_t>());

  return placement;
}

inline void writePlacement(const GraphicsPlacement &placement) {
  writeImageKey(placement.key);
  probe::write(placement.virtual_id);
  probe::write(placement.placement_id);
  probe::write(placement.x);
  probe::write(placement.y);
  probe::write(placement.source_x);
  probe::write(placement.source_y);
  probe::write(placement.source_width);
  probe::write(placement.source_height);
  probe::write(placement.columns);
  probe::write(placement.rows);
  probe::write(placement.offset_x);
  probe::write(placement.offset_y);
  probe::write(placement.z_index);
  probe::write(static_cast<std::uint8_t>(placement.location));
}

}
