#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdio>

import std;
import telar.base.memory;
import telar.gui.core.primitives;
import telar.gui.tools.probe_io;
import telar.gui.tools.probe_text;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;

enum class Operation : std::uint8_t {
  reset = 1,
  add,
  update,
  remove,
  live,
  select,
  pin,
  unpin,
  summarize,
  collect,
  contains,
};

void writeRows(const Machines &machines) {
  constexpr std::uint16_t missing_cpu = 256;
  write(machines.revision());
  write(machines.active());
  write(static_cast<std::uint8_t>(machines.count()));
  write(static_cast<std::uint8_t>(machines.attentionElsewhere()));
  for (const auto &row : machines.rows()) {
    write(static_cast<std::uint8_t>(row.used));
    write(row.generation);
    write(row.id.value());
    writeText(row.label.view());
    writeText(row.destination.view());
    writeText(row.color.view());
    writeText(row.program.view());
    write(static_cast<std::uint8_t>(row.enabled));
    write(static_cast<std::uint8_t>(row.pinned));
    write(static_cast<std::uint8_t>(row.live));
    write(static_cast<std::uint8_t>(row.phase));
    write(static_cast<std::uint8_t>(row.needs_setup));
    write(static_cast<std::uint8_t>(row.attention));
    write(static_cast<std::uint16_t>(row.cpu_percent ? *row.cpu_percent : missing_cpu));
    write(row.cpu_count);
    write(row.memory_used_decigib);
    write(row.memory_total_decigib);
    write(row.sampled_ns);
    write(row.metrics_revision);
    write(row.agent_revision);
    write(row.workspace_revision);
  }
}

void writeFields(SystemAllocator &memory, Machines &machines, std::optional<Machines::Slot> slot) {
  const auto raw_id = read<std::uint64_t>();
  const auto label = readText(memory);
  const auto destination = readText(memory);
  const auto color = readText(memory);
  const auto enabled = read<std::uint8_t>() != 0;
  const auto program = readText(memory);
  const MachineFields fields{
      .id = raw_id == 0 ? MachineId{} : MachineId::fromRaw(raw_id),
      .label = label,
      .destination = destination,
      .color = color,
      .enabled = enabled,
      .program = program,
  };
  if (slot) {
    machines.update(*slot, fields);
    write(*slot);
  } else {
    const auto wanted = read<std::uint8_t>();
    constexpr auto automatic_slot = std::uint8_t{255};
    const auto added = machines.add(fields, wanted == automatic_slot ? std::nullopt : std::optional{wanted});
    write(added);
  }
}

void summarize(Machines &machines) {
  const auto slot = read<Machines::Slot>();
  MachineObservation observation;
  observation.phase = static_cast<MachinePhase>(read<std::uint8_t>());
  observation.needs_setup = read<std::uint8_t>() != 0;
  observation.attention = read<std::uint8_t>() != 0;
  const auto has_metrics = read<std::uint8_t>() != 0;
  const MachineMetrics metrics{
      .cpu_percent = read<std::uint8_t>(),
      .cpu_count = read<std::uint16_t>(),
      .memory_used_decigib = read<std::uint16_t>(),
      .memory_total_decigib = read<std::uint16_t>(),
  };
  observation.metrics = has_metrics ? std::optional{metrics} : std::nullopt;
  observation.metrics_revision = read<std::uint64_t>();
  observation.agent_revision = read<std::uint64_t>();
  observation.workspace_revision = read<std::uint64_t>();
  observation.now_ns = read<std::uint64_t>();
  write(static_cast<std::uint8_t>(machines.summarize(slot, observation)));
}

void operate(Operation operation, SystemAllocator &memory, Machines &machines) {
  switch (operation) {
  case Operation::reset:
    machines = {};
    break;
  case Operation::add:
    writeFields(memory, machines, std::nullopt);
    break;
  case Operation::update:
    writeFields(memory, machines, read<Machines::Slot>());
    break;
  case Operation::remove:
    machines.remove(read<Machines::Slot>());
    break;
  case Operation::live: {
    const auto slot = read<Machines::Slot>();
    machines.setLive(slot, read<std::uint8_t>() != 0);
    break;
  }
  case Operation::select:
    write(static_cast<std::uint8_t>(machines.select(read<Machines::Slot>())));
    break;
  case Operation::pin:
    machines.pin(read<Machines::Slot>());
    break;
  case Operation::unpin:
    machines.unpin(read<Machines::Slot>());
    break;
  case Operation::summarize:
    summarize(machines);
    break;
  case Operation::collect: {
    const auto query = readText(memory);
    const auto results = MachinePicker::collect(machines, query);
    write(static_cast<std::uint8_t>(results.rows().size()));
    for (const auto &match : results.rows()) {
      write(match.target.slot);
      write(match.score);
    }
    break;
  }
  case Operation::contains: {
    const MachineToken token{.slot = read<std::uint8_t>(), .generation = read<std::uint64_t>()};
    write(static_cast<std::uint8_t>(machines.contains(token)));
    break;
  }
  default:
    throw std::runtime_error{"UnknownMachineOperation"};
  }
}

}

int main() {
  try {
    SystemAllocator memory;
    Machines machines;
    int operation = 0;
    while ((operation = std::getchar()) != EOF) {
      try {
        operate(static_cast<Operation>(operation), memory, machines);
        write(std::uint8_t{1});
      } catch (const MachineFailure &failure) {
        write(std::uint8_t{0});
        writeText(failure.what());
      }

      writeRows(machines);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
