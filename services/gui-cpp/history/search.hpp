#pragma once

#include <cstddef>
#include <string_view>

namespace telar::gui {

struct HistorySearch {
  static constexpr std::size_t maximum_query_bytes = 128;

  std::string_view query;
  bool failed_only = false;

  [[nodiscard]] static HistorySearch parse(std::string_view text, bool failed_only) noexcept {
    if (text.starts_with('!')) {
      failed_only = true;
      text.remove_prefix(1);
      while (text.starts_with(' ')) {
        text.remove_prefix(1);
      }
    }

    return {.query = text, .failed_only = failed_only};
  }
};

}
