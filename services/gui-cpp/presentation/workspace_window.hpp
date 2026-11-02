#pragma once

#include <algorithm>
#include <cstddef>
#include <optional>

namespace telar::gui {

struct WorkspaceWindow {
  struct Selection {
    std::size_t count = 0;
    std::size_t active = 0;
  };

  std::size_t first = 0;
  std::size_t count = 0;
  std::size_t total = 0;

  [[nodiscard]] static WorkspaceWindow centered(Selection selection, std::size_t capacity) noexcept {
    const auto total = selection.count;
    const auto count = std::min(total, capacity);
    if (count == 0) {
      return {.total = total};
    }

    const auto active = std::min(selection.active, total - 1);
    const auto half = count / 2;
    const auto start = active > half ? active - half : 0;

    return {.first = std::min(start, total - count), .count = count, .total = total};
  }

  [[nodiscard]] std::optional<std::size_t> previous() const noexcept {
    return first == 0 ? std::nullopt : std::optional{first - 1};
  }

  [[nodiscard]] std::optional<std::size_t> next() const noexcept {
    const auto index = first + count;

    return index == total ? std::nullopt : std::optional{index};
  }
};

}
