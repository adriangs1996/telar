#pragma once

#include "telar_config/callback_context.hpp"
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::cli {

struct PluginWorkerOptions {
  const char *entry = nullptr;
  const char *action = nullptr;
  config::BindingContext context;

  static PluginWorkerOptions parse(std::span<char *> arguments) {
    constexpr std::size_t argument_count = 7;
    if (arguments.size() != argument_count) {
      throw std::invalid_argument{"Expected plugin-worker ENTRY ACTION SIDEBAR TAB_COUNT ACTIVE_TAB_INDEX PANE_COUNT FOCUSED_PANE_ID"};
    }

    const std::string_view sidebar{arguments[2]};
    if (sidebar != "0" && sidebar != "1") {
      throw std::invalid_argument{"Invalid plugin worker sidebar flag"};
    }

    const std::string_view action{arguments[1]};
    if (action.empty()) {
      throw std::invalid_argument{"Empty plugin action"};
    }

    for (const char byte : action) {
      if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' || byte == '.')) {
        throw std::invalid_argument{"Invalid plugin action name"};
      }
    }

    const config::BindingContext context{
        .sidebar_visible = sidebar == "1",
        .tab_count = number<std::uint16_t>(arguments[3]),
        .active_tab_index = number<std::uint16_t>(arguments[4]),
        .pane_count = number<std::uint16_t>(arguments[5]),
        .focused_pane_id = number<std::uint64_t>(arguments[6]),
    };
    return {.entry = arguments[0], .action = arguments[1], .context = context};
  }

private:
  template <typename Integer>
  static Integer number(std::string_view text) {
    if (text.empty() || text.front() == '_' || text.back() == '_') {
      throw std::invalid_argument{"Invalid plugin worker integer"};
    }

    Integer result = 0;
    constexpr unsigned radix = 10;
    for (const char byte : text) {
      if (byte == '_') {
        continue;
      }

      if (byte < '0' || byte > '9') {
        throw std::invalid_argument{"Invalid plugin worker integer"};
      }

      const auto digit = static_cast<unsigned>(byte - '0');
      if (result > (std::numeric_limits<Integer>::max() - digit) / radix) {
        throw std::invalid_argument{"Plugin worker integer exceeds its bounds"};
      }

      result = static_cast<Integer>((result * radix) + digit);
    }

    return result;
  }
};

}
