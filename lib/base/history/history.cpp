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

  void IntegrationMarkFilter::reset() noexcept {
    state_ = State::ground;
    held_count_ = 0;
    number_ = 0;
  }

  IntegrationMarkFilter::Step IntegrationMarkFilter::step(std::uint8_t byte) noexcept {
    constexpr std::uint8_t bell = 0x07;
    constexpr std::uint8_t cancel = 0x18;
    constexpr std::uint8_t substitute = 0x1a;
    constexpr std::uint32_t prompt_mark = 133;
    constexpr std::uint32_t private_mark = 6973;
    constexpr std::uint32_t decimal = 10;

    switch (state_) {
    case State::ground:
      held_.atMut(0) = byte;
      held_count_ = 1;
      state_ = State::escape;
      return Step::consumed;
    case State::escape:
      if (byte != ']') {
        state_ = State::ground;
        return Step::release;
      }

      held_.atMut(held_count_++) = byte;
      number_ = 0;
      state_ = State::number;
      return Step::consumed;
    case State::number: {
      const bool digit = byte >= '0' && byte <= '9';
      if (digit && held_count_ < held_.size()) {
        held_.atMut(held_count_++) = byte;
        number_ = (number_ * decimal) + (byte - '0');
        return Step::consumed;
      }

      const bool ends = byte == ';' || byte == bell || byte == escape;
      if (digit || !ends || (number_ != prompt_mark && number_ != private_mark)) {
        state_ = State::ground;
        return Step::release;
      }

      held_count_ = 0;
      state_ = byte == ';' ? State::mark : (byte == bell ? State::ground : State::mark_escape);
      return Step::consumed;
    }
    case State::mark:
      if (byte == bell || byte == cancel || byte == substitute) {
        state_ = State::ground;
      } else if (byte == escape) {
        state_ = State::mark_escape;
      }

      return Step::consumed;
    case State::mark_escape:
      // ESC \ ends the mark; ESC before anything else ends it too, and that byte is read anew.
      state_ = State::ground;
      return byte == '\\' ? Step::consumed : Step::release;
    }

    return Step::consumed;
  }

}
