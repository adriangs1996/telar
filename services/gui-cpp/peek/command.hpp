#pragma once

#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class PeekCommand : std::uint8_t {
  open,
  stop,
  diff,
  message,
};

struct PeekInput {
  [[nodiscard]] static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - text.find_last_not_of(" \t") - 1);
    text.remove_prefix(first);

    return text;
  }

  [[nodiscard]] static PeekCommand command(std::string_view text) noexcept {
    text = trim(text);
    if (text.empty() || text == "/open") {
      return PeekCommand::open;
    }

    if (text == "/stop") {
      return PeekCommand::stop;
    }

    return text == "/diff" ? PeekCommand::diff : PeekCommand::message;
  }
};

}
