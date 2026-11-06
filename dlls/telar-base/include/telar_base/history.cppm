module;

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

export module telar.base.history;


// Interface: telar_base/history/search_policy.cppm
export {
namespace telar::runtime {

inline unsigned char asciiLower(unsigned char byte) noexcept {
  return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
}

inline std::optional<std::uint32_t> historyScore(std::string_view command, std::string_view query) noexcept {
  if (query.empty()) {
    return 1;
  }

  std::size_t matched = 0;
  std::size_t first = 0;
  for (std::size_t index = 0; index < command.size(); ++index) {
    if (asciiLower(command[index]) != asciiLower(query[matched])) {
      continue;
    }

    if (matched == 0) {
      first = index;
    }
    ++matched;
    if (matched == query.size()) {
      constexpr std::uint32_t base_score = 4096;
      constexpr std::uint32_t leading_penalty = 8;
      constexpr std::uint32_t inner_penalty = 16;
      const auto penalty = first * leading_penalty + (index - first + 1 - query.size()) * inner_penalty;
      return penalty >= base_score ? 0 : base_score - static_cast<std::uint32_t>(penalty);
    }
  }

  return std::nullopt;
}

inline std::string_view historyGroup(std::string_view command) noexcept {
  const auto trim = [](std::string_view text) {
    const auto start = text.find_first_not_of(' ');
    return start == std::string_view::npos ? std::string_view{} : text.substr(start);
  };
  command = trim(command);
  if (command.starts_with("sudo ")) {
    command = trim(command.substr(5));
  }

  const auto first_end = command.find(' ');
  if (first_end == std::string_view::npos) {
    return command;
  }

  constexpr std::array<std::string_view, 11> leaders{"git", "docker", "kubectl", "cargo", "zig", "npm", "pnpm", "yarn", "make", "brew", "systemctl"};
  const auto first = command.substr(0, first_end);
  for (const auto leader : leaders) {
    if (first != leader) {
      continue;
    }

    const auto remainder = trim(command.substr(first_end));
    if (!remainder.empty() && remainder.front() != '-') {
      const auto second_end = remainder.find(' ');
      return command.substr(0, static_cast<std::size_t>(remainder.data() - command.data()) + std::min(second_end, remainder.size()));
    }
    break;
  }

  return first;
}

}
}
