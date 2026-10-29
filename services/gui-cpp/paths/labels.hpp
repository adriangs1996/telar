#pragma once

#include "page.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct PathPickerLabels {
  static constexpr std::size_t count_bytes = 32;
  using Status = BoundedText<PathPickerLimits::error_bytes>;
  using Count = BoundedText<count_bytes>;

  [[nodiscard]] static std::string_view root(std::string_view path) noexcept {
    if (path.size() <= 1) {
      return "/";
    }

    const auto split = path.rfind('/');
    if (split != std::string_view::npos) {
      path.remove_prefix(split + 1);
    }

    return path;
  }

  [[nodiscard]] static Count count(const PathPickerPage &page) {
    Count result;
    result.appendDecimal(page.matches().size());
    result.append(" of ");
    result.appendDecimal(page.scanned());

    return result;
  }

  [[nodiscard]] static Status status(const PathPickerPage &page) {
    Status result;
    if (page.phase() == PathPickerPhase::failed) {
      result.append(page.error());

      return result;
    }

    if (!page.complete()) {
      result.append("indexing · ");
      result.appendDecimal(page.scanned());
    } else {
      result.appendDecimal(page.scanned());
      result.append(page.truncated() ? "+ paths" : " paths");
    }

    return result;
  }

  [[nodiscard]] static std::string_view empty(const PathPickerPage &page) noexcept {
    if (page.phase() == PathPickerPhase::failed) {
      return "No paths";
    }

    return page.phase() == PathPickerPhase::ready && page.complete() ? "No paths match" : "Searching…";
  }
};

}
