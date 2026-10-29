#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct EditorColumns {
  std::uint16_t first = 0;
  std::uint16_t last = 0;
};

struct EditorView {
  std::string_view text;
  std::uint16_t cursor = 0;
  std::optional<EditorColumns> selection;
  bool clipped_left = false;
  bool clipped_right = false;
};

}
