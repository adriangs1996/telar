#pragma once

#include <algorithm>
#include <cstdint>

namespace telar::runtime {

struct DisplayCells {
  std::uint32_t columns = 0;
  std::uint32_t rows = 0;
  bool operator==(const DisplayCells &) const = default;
};

struct ImageDisplayRequest {
  std::uint32_t width;
  std::uint32_t height;
  DisplayCells requested;
  std::uint32_t offset_x;
  std::uint32_t offset_y;
  std::uint32_t cell_width;
  std::uint32_t cell_height;
};

inline std::uint32_t saturatedDimension(std::uint64_t value) noexcept {
  return static_cast<std::uint32_t>(std::min<std::uint64_t>(value, UINT32_MAX));
}

inline std::uint32_t scaledDimension(std::uint32_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept {
  return denominator == 0 ? 0 : saturatedDimension((static_cast<std::uint64_t>(value) * numerator + denominator / 2) / denominator);
}

inline DisplayCells displayCells(const ImageDisplayRequest &request) noexcept {
  if (request.requested.columns != 0 && request.requested.rows != 0) {
    return request.requested;
  }
  if (request.cell_width == 0 || request.cell_height == 0) {
    return {};
  }

  const auto offset_x = std::min(request.offset_x, request.cell_width - 1);
  const auto offset_y = std::min(request.offset_y, request.cell_height - 1);
  auto width = request.width;
  auto height = request.height;
  if (request.requested.columns != 0) {
    width = saturatedDimension(static_cast<std::uint64_t>(request.cell_width) * request.requested.columns) - offset_x;
    height = scaledDimension(width, request.height, request.width);
  } else if (request.requested.rows != 0) {
    height = saturatedDimension(static_cast<std::uint64_t>(request.cell_height) * request.requested.rows) - offset_y;
    width = scaledDimension(height, request.width, request.height);
  }

  const auto occupied_width = saturatedDimension(static_cast<std::uint64_t>(width) + offset_x);
  const auto occupied_height = saturatedDimension(static_cast<std::uint64_t>(height) + offset_y);
  return {occupied_width / request.cell_width + (occupied_width % request.cell_width != 0), occupied_height / request.cell_height + (occupied_height % request.cell_height != 0)};
}

}
