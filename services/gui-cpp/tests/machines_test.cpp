#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include <algorithm>
#include <utility>
#include <exception>
#include <iostream>
#include <string>



import telar.gui.machines.discovery;
import telar.gui.machines.picker;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

void identitySurvivesRenameAndRejectsRetiredDestinations() {
  Machines machines;
  const auto local = machines.add({.label = "Personal", .destination = {}}, Machines::local_slot);
  machines.setLive(local, true);
  const auto remote = machines.add({.id = MachineId::fromRaw(1), .label = "Work", .destination = "dev@work"});
  machines.setLive(remote, true);
  const auto before = machines.token(remote);
  machines.update(remote, {.id = MachineId::fromRaw(1), .label = "Build", .destination = "dev@work", .color = "red"});
  require(machines.contains(before) && machines.find(MachineId::fromRaw(1)) == remote, "a profile rename must preserve the machine admission and its slot");
  require(machines.select(remote), "an enabled live machine must be selectable");
  machines.update(remote, {.id = MachineId::fromRaw(1), .label = "Build", .destination = "dev@new"});
  require(!machines.contains(before) && machines.active() == remote, "changing a destination must invalidate pending targets without changing the active slot");
  const auto moved = machines.token(remote);
  machines.remove(remote);
  require(!machines.contains(moved), "a removed machine must reject delayed work");
  const auto other = machines.add({.label = "Other", .destination = "other"});
  require(other != remote, "a removed active slot cannot be reused while its old view is still presented");
  require(machines.select(local), "the local client must remain selectable after a remote is removed");
  const auto replacement = machines.add({.label = "Replacement", .destination = "replacement"});
  require(replacement == remote && machines.row(replacement).live, "slot reuse must preserve client initialization independently of profile membership");
  require(!machines.contains(moved) && machines.token(replacement).generation > moved.generation, "slot reuse must never revive the previous destination's identity");
}

void summariesRefreshOnRevisionsAndRetainPlacementSamples() {
  constexpr std::uint8_t sampled_cpu = 12;
  constexpr std::uint8_t uncommitted_cpu = 99;
  constexpr std::uint16_t initial_cpu_count = 8;
  constexpr std::uint16_t updated_cpu_count = 16;
  constexpr std::uint16_t memory_used = 21;
  constexpr std::uint16_t memory_total = 160;
  constexpr std::uint64_t initial_time = 100;
  constexpr std::uint64_t updated_time = 200;
  Machines machines;
  const auto local = machines.add({.label = "Personal", .destination = {}}, Machines::local_slot);
  const auto remote = machines.add({.label = "Build", .destination = "build"});
  MachineObservation observation{
      .phase = MachinePhase::connected,
      .attention = true,
      .metrics = MachineMetrics{.cpu_percent = sampled_cpu, .cpu_count = initial_cpu_count, .memory_used_decigib = memory_used, .memory_total_decigib = memory_total},
      .metrics_revision = 1,
      .agent_revision = 1,
      .workspace_revision = 1,
      .now_ns = initial_time,
  };
  require(machines.summarize(remote, observation), "new runtime metadata must refresh a cached machine summary");
  const auto revision = machines.revision();
  observation.now_ns = updated_time;
  observation.attention = false;
  observation.metrics->cpu_percent = uncommitted_cpu;
  require(!machines.summarize(remote, observation) && machines.revision() == revision, "unrelated pane events must not rescan or rewrite cached summaries");
  require(machines.row(remote).cpu_percent == sampled_cpu && machines.row(remote).sampled_ns == initial_time && machines.attentionElsewhere(), "unchanged revisions must preserve attention and the original metrics timestamp");
  observation.metrics->cpu_percent = sampled_cpu;
  observation.metrics->cpu_count = updated_cpu_count;
  observation.metrics_revision = 2;
  require(!machines.summarize(remote, observation), "a metrics sample with equal displayed CPU must not invalidate drawn surfaces");
  require(machines.row(remote).cpu_count == updated_cpu_count && machines.row(remote).sampled_ns == updated_time, "equal CPU samples must still refresh placement capacity and freshness");
  ++observation.agent_revision;
  require(machines.summarize(remote, observation) && !machines.attentionElsewhere(), "a new agent snapshot must clear obsolete attention");
  observation.phase = MachinePhase::failed;
  observation.needs_setup = true;
  require(machines.summarize(remote, observation) && machines.row(remote).needs_setup, "setup repair belongs only to a permanent failed link");
  observation.phase = MachinePhase::lost;
  require(machines.summarize(remote, observation) && !machines.row(remote).needs_setup, "a retryable link must not retain a previous setup verdict");
  require(machines.active() == local, "hidden metadata must not select its source machine");
}

void pickerKeepsDisabledRowsStableTiesAndLabelPrecedence() {
  Machines machines;
  const auto local = machines.add({.label = "Personal", .destination = {}}, Machines::local_slot);
  const auto first = machines.add({.label = "xbox", .destination = "box", .enabled = false});
  const auto second = machines.add({.label = "box", .destination = "another"});
  const auto third = machines.add({.label = "Other", .destination = "box-fallback"});
  const auto empty = MachinePicker::collect(machines, "");
  require(empty.rows().size() == 4 && empty.rows()[0].target.slot == local && empty.rows()[1].target.slot == first, "empty queries must include disabled machines in slot order");
  const auto matches = MachinePicker::collect(machines, "box");
  require(matches.rows().size() == 3 && matches.rows()[0].target.slot == second && matches.rows()[1].target.slot == third && matches.rows()[2].target.slot == first, "destination scoring is a fallback only when the label has no match, with ties preserved by slot");
  require(MachinePicker::collect(machines, "missing").rows().empty(), "unmatched machines must leave only the adapter's Add row");
  using Intent = MachinePicker::Intent;
  require(MachinePicker::choose(machines, std::nullopt, false) == Intent::add, "the final Add row must remain actionable even with no machine matches");
  require(MachinePicker::choose(machines, machines.token(local), true) == Intent::none, "Shift-Enter must not disable the local machine");
  require(MachinePicker::choose(machines, machines.token(first), false) == Intent::enable, "Enter on a disabled remote must enable it before navigation");
  require(MachinePicker::choose(machines, machines.token(second), true) == Intent::disable, "Shift-Enter must disable an enabled remote");
  require(machines.summarize(second, {.phase = MachinePhase::failed, .needs_setup = true}), "the setup fixture must publish its failure");
  require(MachinePicker::choose(machines, machines.token(second), false) == Intent::setup && MachinePicker::choose(machines, machines.token(second), true) == Intent::disable, "setup must take priority on Enter while alternate submission keeps toggling");
  const auto stale = machines.token(first);
  machines.remove(first);
  require(MachinePicker::choose(machines, stale, false) == Intent::none, "a queued picker submission must reject a removed or replaced machine");
}

void fixedCapacityOwnsFieldsAndKeepsPinDecisions() {
  Machines machines;
  static_cast<void>(machines.add({.label = "Personal", .destination = {}}, Machines::local_slot));
  std::string destination = "dev@build";
  const auto slot = machines.add({.label = "Build", .destination = destination, .enabled = false});
  destination.assign("overwritten");
  require(machines.row(slot).destination.view() == "dev@build", "machine rows must own worker or decoder strings");
  machines.pin(slot);
  require(machines.shown(slot) && machines.row(slot).pinned, "an explicit remote launch must pin a disabled profile");
  machines.unpin(slot);
  require(!machines.row(slot).pinned && machines.shown(slot), "unpinning must leave retirement to committed profile reconciliation");
  for (std::size_t index = 1; index < MachineLimits::profiles; ++index) {
    static_cast<void>(machines.add({.label = "Temporary", .destination = "temporary"}));
  }

  require(machines.count() == Machines::capacity, "one local plus sixteen saved machines must fit without allocation");
  try {
    static_cast<void>(machines.add({.label = "Overflow", .destination = {}}));
  } catch (const MachineFailure &failure) {
    require(failure.code() == MachineError::too_many, "capacity failure must retain the profile error category");

    return;
  }

  throw std::runtime_error{"Full machine table accepted another row"};
}

}

int main() {
  try {
    identitySurvivesRenameAndRejectsRetiredDestinations();
    summariesRefreshOnRevisionsAndRetainPlacementSamples();
    pickerKeepsDisabledRowsStableTiesAndLabelPrecedence();
    fixedCapacityOwnsFieldsAndKeepsPinDecisions();
    std::cout << "4 machine registry and picker cases passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
