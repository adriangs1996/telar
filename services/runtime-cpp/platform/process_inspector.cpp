module;

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>

module telar.runtime.platform.process_probe;



namespace telar::runtime {
namespace {
constexpr std::size_t maximum_process_argument_bytes = 16 * 1024;
}

std::optional<ProcessIdentity> ProcessInspector::identity(pid_t process) const noexcept {
  const auto observed = snapshot(process);
  return observed ? std::optional{observed->identity} : std::nullopt;
}

bool ProcessInspector::descendsFrom(const ProcessIdentity &process, pid_t root) const noexcept {
  return lineage(process, root).descends;
}

ProcessLineage ProcessInspector::lineage(const ProcessIdentity &process, pid_t root) const noexcept {
  ProcessLineage result;
  auto current = identity(process.pid);
  if (current != process) {
    return result;
  }

  result.descends = process.pid == root;
  while (current && result.count < result.processes.size() && current->parent > 0) {
    result.processes[result.count++] = current->parent;
    result.descends |= current->parent == root;
    if (current->parent == 1 || current->parent == current->pid) {
      break;
    }

    current = identity(current->parent);
  }

  return result;
}

AgentProvider ProcessInspector::provider(pid_t process) const noexcept {
  const auto path = executable(process);
  if (path.view().empty()) {
    return AgentProvider::unknown;
  }

  const auto identified = manifests_.fromExecutable(processBasename(path.view()));
  if (identified != AgentProvider::unknown) {
    return identified;
  }

  std::array<char, maximum_process_argument_bytes> arguments;
  return readArguments(process, arguments).provider(manifests_, path.view());
}

IdentifiedProcess ProcessInspector::identifyProcess(pid_t process) const noexcept {
  IdentifiedProcess identified;
  identified.identity = identity(process);
  if (!identified.identity) {
    return identified;
  }

  identified.name = name(process);
  std::array<char, maximum_process_argument_bytes> storage;
  const auto arguments = readArguments(process, storage);
  identified.provider = arguments.provider(manifests_, identified.name.view());
  identified.session_host = arguments.sessionHost(identified.provider);
  if (const auto *manifest = manifests_.find(identified.provider)) {
    identified.name.assign(manifest->displayName());
  }

  return identity(process) == identified.identity ? identified : IdentifiedProcess{};
}

IdentifiedProcess ProcessInspector::identifyGroup(pid_t group, AgentProvider preferred) const noexcept {
  constexpr std::size_t maximum_group_processes = 64;
  auto leader = identifyProcess(group);
  if (group <= 0 || leader.provider != AgentProvider::unknown) {
    return leader;
  }

  std::array<pid_t, maximum_group_processes> members;
  const auto count = groupMembers(group, members);
  if (count == 0) {
    return leader;
  }

  std::optional<IdentifiedProcess> selected;
  for (const auto member : std::span{members}.first(count)) {
    if (member <= 0 || member == group) {
      continue;
    }

    auto candidate = identifyProcess(member);
    if (!candidate.identity || candidate.identity->process_group != group) {
      continue;
    }
    if (candidate.provider == AgentProvider::unknown) {
      if (leader.name.view().empty()) {
        leader = candidate;
      }
      continue;
    }
    if (preferred == AgentProvider::unknown || candidate.provider == preferred) {
      return candidate;
    }
    if (!selected) {
      selected = candidate;
    }
  }

  return selected.value_or(leader);
}

AgentProvider ProcessInspector::ancestorProvider(const ProcessIdentity &process, pid_t root) const noexcept {
  auto current = identity(process.pid);
  if (current != process) {
    return AgentProvider::unknown;
  }

  auto identified = AgentProvider::unknown;
  constexpr unsigned maximum_ancestors = 64;
  for (unsigned count = 0; current && count < maximum_ancestors; ++count) {
    if (identified == AgentProvider::unknown) {
      identified = provider(current->pid);
    }

    if (current->pid == root) {
      return identified;
    }
    if (current->parent <= 1 || current->parent == current->pid) {
      return AgentProvider::unknown;
    }

    current = identity(current->parent);
  }

  return AgentProvider::unknown;
}

}
