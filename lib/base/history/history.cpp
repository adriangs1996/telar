module telar.base.history;

import std;
import telar.base.ds;

namespace telar::runtime {

  ds::Option<std::uint32_t> historyScore(std::string_view command, std::string_view query) noexcept {
    if (query.empty()) {
      return 1;
    }

    std::size_t matched = 0;
    std::size_t first = 0;

    for (std::size_t index = 0; index < command.size(); ++index) {
      if (asciiLower(static_cast<unsigned char>(command[index])) != asciiLower(static_cast<unsigned char>(query[matched]))) {
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
        const auto penalty = (first * leading_penalty) + ((index - first + 1 - query.size()) * inner_penalty);

        return penalty >= base_score ? 0 : base_score - static_cast<std::uint32_t>(penalty);
      }
    }

    return ds::none;
  }

  std::string_view historyGroup(std::string_view command) noexcept {
    constexpr std::string_view sudo = "sudo ";
    const auto trim = [](std::string_view text) {
      text.remove_prefix(std::min(text.find_first_not_of(' '), text.size()));
      return text;
    };

    // The first `count` bytes of the command, which holds them.
    const auto head = [](std::string_view text, std::size_t count) {
      text.remove_suffix(text.size() - count);
      return text;
    };

    command = trim(command);
    if (command.starts_with(sudo)) {
      command.remove_prefix(sudo.size());
      command = trim(command);
    }

    const auto first_end = command.find(' ');
    if (first_end == std::string_view::npos) {
      return command;
    }

    constexpr ds::Array<std::string_view, 11> leaders{"git", "docker", "kubectl", "cargo", "zig", "npm", "pnpm", "yarn", "make", "brew", "systemctl"};
    const auto first = head(command, first_end);

    if (std::ranges::find(leaders, first) == leaders.end()) {
      return head(command, first_end);
    }

    auto remainder = command;

    remainder.remove_prefix(first_end);
    remainder = trim(remainder);
    if (remainder.empty() || remainder.front() == '-') {
      return head(command, first_end);
    }

    const auto second_end = remainder.find(' ');

    return head(command, static_cast<std::size_t>(remainder.data() - command.data()) + std::min(second_end, remainder.size()));
  }

}
