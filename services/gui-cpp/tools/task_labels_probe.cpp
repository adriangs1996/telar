#include "application/records.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "presentation/task_card_labels.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar;
using namespace telar::gui;
using probe::readText;
using probe::writeText;

enum class Operation : std::uint8_t {
  facts,
  activity,
};

template <Allocator Memory>
void facts(Memory &memory) {
  const auto machine = readText(memory);
  Worktree task{memory};
  task.branch = readText(memory);
  task.command_label = readText(memory);
  task.diff_added = probe::read<std::uint32_t>();
  task.diff_removed = probe::read<std::uint32_t>();
  task.diff_files = probe::read<std::uint32_t>();
  task.commits_ahead = probe::read<std::uint32_t>();
  task.command_state = static_cast<CommandState>(probe::read<std::uint8_t>());
  task.command_exit = probe::read<std::int32_t>();
  const auto result = TaskCardLabels::facts(machine, task);
  writeText(result.view());
}

template <Allocator Memory>
void activity(Memory &memory) {
  Agent agent{memory};
  agent.status = static_cast<AgentStatus>(probe::read<std::uint8_t>());
  agent.plan_done = probe::read<std::uint16_t>();
  agent.plan_total = probe::read<std::uint16_t>();
  agent.detail = readText(memory);
  agent.final_message = readText(memory);
  agent.plan_step = readText(memory);
  const auto result = TaskCardLabels::activity(agent);
  const auto plan = result.plan ? TaskCardLabels::plan(agent.plan_done, agent.plan_total) : TaskCardLabels::Plan{};
  probe::write(static_cast<std::uint16_t>(plan.cells));
  probe::write(static_cast<std::uint16_t>(plan.filled));
  writeText(plan.count.view());
  writeText(result.text);
  writeText(palette_names[static_cast<std::size_t>(result.color)]);
}

}

int main() try {
  SystemAllocator memory;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return std::ferror(stdin) == 0 ? 0 : 1;
    }

    probe::write(static_cast<std::uint8_t>(operation));
    switch (static_cast<Operation>(operation)) {
    case Operation::facts:
      facts(memory);
      break;
    case Operation::activity:
      activity(memory);
      break;
    default:
      throw std::invalid_argument{"UnknownTaskLabelOperation"};
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
