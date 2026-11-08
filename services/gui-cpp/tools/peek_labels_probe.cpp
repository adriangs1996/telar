#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.config;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.gui.tools.probe_io;
import telar.gui.application.workspace_replica;
import telar.gui.presentation.notification_stack;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::probe;
constexpr std::size_t maximum_input = 512;

String<SystemAllocator> text(SystemAllocator &memory) {
  const auto size = read<std::uint32_t>();
  if (size > maximum_input) {
    throw std::length_error{"ProbeTextTooLong"};
  }

  String<SystemAllocator> result{AllocatorRef<char, SystemAllocator>{memory}};
  result.resize(size);
  if (std::fread(result.data(), 1, size, stdin) != size) {
    throw std::runtime_error{"IncompleteProbeText"};
  }

  return result;
}

void writeText(std::string_view value) {
  write(static_cast<std::uint32_t>(value.size()));
  if (std::fwrite(value.data(), 1, value.size(), stdout) != value.size()) {
    throw std::runtime_error{"ProbeTextWriteFailed"};
  }
}

void sample(SystemAllocator &memory) {
  const auto has_task = read<std::uint8_t>() != 0;
  Agent<SystemAllocator> agent{memory};
  agent.status = read<AgentStatus>();
  agent.plan_done = read<std::uint16_t>();
  agent.plan_total = read<std::uint16_t>();
  agent.display_name = text(memory);
  agent.plan_step = text(memory);
  agent.detail = text(memory);
  Worktree<SystemAllocator> task{memory};
  task.branch = text(memory);
  task.title = text(memory);
  const auto *row = has_task ? &task : nullptr;
  writeText(PeekLabels::title(agent, row));
  writeText(PeekLabels::facts(agent, row).view());
}

}

int main() {
  try {
    SystemAllocator memory;
    while (std::getchar() != EOF) {
      sample(memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
