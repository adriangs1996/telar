#pragma once

#include "agent_status.hpp"
#include "application/records.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include "text/label_text.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct TaskCardLabels {
  static constexpr std::size_t text_capacity = label_text_capacity;
  static constexpr std::size_t maximum_plan_cells = 8;
  static constexpr std::size_t plan_count_capacity = 16;
  static constexpr float plan_cell_width = 8;
  static constexpr float plan_cell_gap = 2;
  static constexpr float plan_cell_height = 4;
  using Text = LabelText;

  struct Activity {
    std::string_view text;
    PaletteRole color = PaletteRole::overlay1;
    bool plan = false;
  };

  struct Plan {
    std::size_t cells = 0;
    std::size_t filled = 0;
    BoundedText<plan_count_capacity> count;
  };

  template <Allocator Memory>
  [[nodiscard]] static Text facts(std::string_view machine, const Worktree<Memory> &task) {
    Text result;
    if (!machine.empty()) {
      append(result, machine);
      append(result, " · ");
    }

    append(result, "\u2387 ");
    append(result, task.handle());
    if (task.diff_files != 0) {
      append(result, "  +");
      decimal(result, task.diff_added);
      append(result, " \u2212");
      decimal(result, task.diff_removed);
      append(result, " · ");
      decimal(result, task.diff_files);
    }

    if (task.commits_ahead != 0) {
      append(result, "  \u2191");
      decimal(result, task.commits_ahead);
    }

    if (task.command_state == CommandState::exited) {
      append(result, task.command_exit == 0 ? "  \u2713 " : "  \u2715 ");
      append(result, task.command_label);
    }

    return result;
  }

  template <Allocator Memory>
  [[nodiscard]] static Activity activity(const Agent<Memory> &agent) noexcept {
    switch (agent.status) {
    case AgentStatus::blocked:
      return {.text = agent.detail, .color = PaletteRole::yellow};
    case AgentStatus::failed:
      return {.text = agent.detail, .color = PaletteRole::red};
    case AgentStatus::done:
    case AgentStatus::ready: {
      const auto final = agent.finalLine();

      return {.text = final.empty() ? std::string_view{agent.detail} : final, .color = PaletteRole::subtext0};
    }
    default:
      return agent.plan_total == 0 ? Activity{.text = agent.detail} : Activity{.text = agent.plan_step, .color = PaletteRole::subtext0, .plan = true};
    }
  }

  [[nodiscard]] static Plan plan(std::uint16_t done, std::uint16_t total) {
    Plan result;
    result.cells = std::min<std::size_t>(total, maximum_plan_cells);
    result.filled = total == 0 ? 0 : ((static_cast<std::size_t>(done) * result.cells) + total - 1) / total;
    result.count.appendDecimal(done);
    result.count.append("/");
    result.count.appendDecimal(total);

    return result;
  }

  template <Allocator Memory>
  [[nodiscard]] static std::string_view commandState(const Worktree<Memory> &task, bool connected) noexcept {
    if (!connected) {
      return "offline · last known";
    }

    switch (task.command_state) {
    case CommandState::running:
      return "running";
    case CommandState::exited:
      return task.command_exit == 0 ? "exited successfully" : "failed";
    default:
      return {};
    }
  }

  template <Allocator Memory>
  [[nodiscard]] static std::string_view commandFacts(std::string_view machine, const Worktree<Memory> &task, bool connected, Text &storage) {
    const auto status = commandState(task, connected);
    storage.truncate(0);
    try {
      storage.append(machine);
      storage.append(" · ");
      storage.append(task.handle());
      storage.append(" · ");
      storage.append(status);

      return storage.view();
    } catch (const std::length_error &) {
      return status;
    }
  }

private:
  static void append(Text &storage, std::string_view text) {
    storage.append(text.substr(0, text_capacity - storage.view().size()));
  }

  static void decimal(Text &storage, std::uint32_t value) {
    constexpr auto decimal_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
    std::array<char, decimal_digits> digits{};
    const auto result = std::to_chars(digits.data(), digits.data() + digits.size(), value);
    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }
};

}
