#pragma once

#include "core/cell_rectangle.hpp"
#include "presentation/name_prompt_geometry.hpp"
#include <cstdint>

namespace telar::gui {

struct AttachmentModalGeometry {
  static constexpr std::uint16_t margin_columns = 8;
  static constexpr std::uint16_t margin_rows = 4;
  static constexpr std::uint16_t minimum_content_rows = 3;

  CellRectangle bounds{};
  CellRectangle title{};
  CellRectangle close{};
  CellRectangle image{};
  CellRectangle footer{};

  [[nodiscard]] static AttachmentModalGeometry measure(CellRectangle host) noexcept {
    const CellRectangle wanted{
        .width = host.width > margin_columns ? static_cast<std::uint16_t>(host.width - margin_columns) : std::uint16_t{},
        .height = host.height > margin_rows ? static_cast<std::uint16_t>(host.height - margin_rows) : std::uint16_t{},
    };
    const auto modal = NamePromptGeometry::measure(host, wanted);
    AttachmentModalGeometry result{.bounds = modal.bounds, .title = modal.title};
    if (result.bounds.width > 4) {
      result.close = {.x = static_cast<std::uint16_t>(result.bounds.x + result.bounds.width - 3), .y = result.bounds.y, .width = 2, .height = 1};
    }

    const auto content = result.bounds.width > 2 && result.bounds.height > 2 ? result.bounds.inner(1) : result.bounds;
    if (content.height >= minimum_content_rows) {
      result.image = content;
      --result.image.height;
      result.footer = content.row(content.height - 1);
    }

    return result;
  }
};

}
