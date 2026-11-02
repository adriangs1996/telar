#pragma once

#include "agent_card_labels.hpp"
#include "application/records.hpp"
#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::gui {

struct PeekLabels {
  static constexpr std::size_t facts_bytes = 256;
  using Facts = BoundedText<facts_bytes>;

  template <Allocator Memory>
  [[nodiscard]] static std::string_view title(const Agent<Memory> &agent, const Worktree<Memory> *task) noexcept {
    if (task == nullptr) {
      return AgentCardLabels::title({}, agent.display_name);
    }

    return task->title.empty() ? std::string_view{task->branch} : std::string_view{task->title};
  }

  template <Allocator Memory>
  [[nodiscard]] static Facts facts(const Agent<Memory> &agent, const Worktree<Memory> *task) {
    Facts result;
    append(result, AgentCardLabels::title({}, agent.display_name));
    append(result, " · ");
    constexpr std::array statuses{std::string_view{"unknown"}, std::string_view{"working"}, std::string_view{"blocked"}, std::string_view{"ready"}, std::string_view{"failed"}, std::string_view{"done"}};
    const auto status = static_cast<std::size_t>(agent.status);
    append(result, statuses[status < statuses.size() ? status : 0]);
    if (task != nullptr) {
      append(result, "  \u2387 ");
      append(result, task->handle());
    }

    if (agent.plan_total != 0) {
      append(result, "  ");
      decimal(result, agent.plan_done);
      append(result, "/");
      decimal(result, agent.plan_total);
      append(result, " ");
      append(result, agent.plan_step);
    } else if (!agent.detail.empty()) {
      append(result, "  ");
      append(result, agent.detail);
    }

    return result;
  }

private:
  static void append(Facts &storage, std::string_view text) {
    storage.append(text.substr(0, facts_bytes - storage.view().size()));
  }

  static void decimal(Facts &storage, std::uint16_t value) {
    constexpr auto capacity = std::numeric_limits<std::uint16_t>::digits10 + 1;
    std::array<char, capacity> digits{};
    const auto result = std::to_chars(digits.data(), digits.data() + digits.size(), value);
    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }
};

}
