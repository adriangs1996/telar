module;
#include <cstddef>
#include <cstdio>

#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>

module telar.runtime.platform.process_probe;

import std;

import telar.base.diagnostics;
import telar.wire.vocabulary;

namespace telar::runtime {
  namespace {
    constexpr std::size_t maximum_process_argument_bytes = 16 * 1024;
  }

  std::string_view processBasename(std::string_view path) noexcept {
    const auto slash = path.find_last_of("/\\");

    return path.substr(slash == std::string_view::npos ? 0 : slash + 1);
  }

  ProcessArguments::ProcessArguments(std::string_view arguments) noexcept
      : arguments_(arguments) {}

  ProcessArguments ProcessArguments::fromMacos(std::span<const char> buffer) noexcept {
    if (buffer.size() <= sizeof(int)) {
      return ProcessArguments{{}};
    }

    int count = 0;

    std::memcpy(&count, buffer.data(), sizeof(count));
    std::string_view remaining{buffer.data() + sizeof(count), buffer.size() - sizeof(count)};
    const auto executable_end = remaining.find('\0');
    if (count <= 0 || executable_end == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    const auto first_argument = remaining.find_first_not_of('\0', executable_end);
    if (first_argument == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    remaining.remove_prefix(first_argument);
    std::size_t length = 0;

    for (int index = 0; index < count; ++index) {
      const auto end = remaining.find('\0', length);
      if (end == std::string_view::npos) {
        return ProcessArguments{{}};
      }

      length = end + 1;
    }

    return ProcessArguments{remaining.substr(0, length)};
  }

  AgentProvider ProcessArguments::provider(const AgentManifests& manifests, std::string_view command) const noexcept {
    auto detected = manifests.fromExecutable(processBasename(command));
    if (detected != AgentProvider::unknown) {
      return detected;
    }

    auto remaining = arguments_;
    const auto first = next(remaining);
    if (!first) {
      return AgentProvider::unknown;
    }

    detected = manifests.fromExecutable(processBasename(*first));
    if (detected != AgentProvider::unknown) {
      return detected;
    }

    if (!genericRuntime(command) && !genericRuntime(*first)) {
      return AgentProvider::unknown;
    }

    while (const auto argument = next(remaining)) {
      if (argument->starts_with('-')) {
        continue;
      }

      detected = manifests.fromExecutable(processBasename(*argument));
      return detected == AgentProvider::unknown ? manifests.fromPath(*argument) : detected;
    }

    return AgentProvider::unknown;
  }

  SessionHost ProcessArguments::sessionHost(AgentProvider provider) const noexcept {
    if (provider != AgentProvider::codex || arguments_.empty()) {
      return SessionHost::unknown;
    }

    auto host = SessionHost::shared_server;
    auto remaining = arguments_;

    while (const auto argument = next(remaining)) {
      if (isCodexBatchArgument(*argument)) {
        return SessionHost::unknown;
      }

      if (*argument == codex_pane_argument) {
        host = SessionHost::pane;
      }
    }

    return host;
  }

  std::optional<std::string_view> ProcessArguments::next(std::string_view& remaining) noexcept {
    const auto first = remaining.find_first_not_of('\0');
    if (first == std::string_view::npos) {
      return std::nullopt;
    }

    remaining.remove_prefix(first);
    const auto end = remaining.find('\0');
    const auto argument = remaining.substr(0, end);

    remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
    return argument;
  }

  bool ProcessArguments::genericRuntime(std::string_view command) noexcept {
    auto name = processBasename(command);
    if (name.size() >= 4 && containsInsensitive(name.substr(name.size() - 4), ".exe")) {
      name.remove_suffix(4);
    }

    for (const std::string_view candidate : {"node", "bun", "deno"}) {
      if (name.size() == candidate.size() && containsInsensitive(name, candidate)) {
        return true;
      }
    }

    return false;
  }

  std::span<const pid_t> ProcessLineage::ancestors() const noexcept {
    return std::span{processes}.first(count);
  }

  bool ProcessIdentity::sameInstance(const ProcessIdentity& other) const noexcept {
    return pid == other.pid && started_seconds == other.started_seconds && started_microseconds == other.started_microseconds;
  }

  void ListeningPorts::add(std::uint16_t port) noexcept {
    const auto end = values.begin() + count;
    const auto at = std::lower_bound(values.begin(), end, port);
    if (port == 0 || (at != end && *at == port) || (count == values.size() && at == end)) {
      return;
    }

    if (count == values.size()) {
      std::move_backward(at, end - 1, end);
    } else {
      std::move_backward(at, end, end + 1);
      ++count;
    }

    *at = port;
  }

  std::span<const std::uint16_t> ListeningPorts::view() const noexcept {
    return std::span{values}.first(count);
  }

  bool ListeningPorts::operator==(const ListeningPorts& other) const noexcept {
    return std::ranges::equal(view(), other.view());
  }

  ProcessInspector::ProcessInspector(const AgentManifests& manifests, uid_t uid) noexcept
      : manifests_(manifests),
        uid_(uid) {}

  std::optional<ProcessIdentity> ProcessInspector::identity(pid_t process) const noexcept {
    const auto observed = snapshot(process);

    return observed ? std::optional{observed->identity} : std::nullopt;
  }

  bool ProcessInspector::descendsFrom(const ProcessIdentity& process, pid_t root) const noexcept {
    return lineage(process, root).descends;
  }

  ProcessLineage ProcessInspector::lineage(const ProcessIdentity& process, pid_t root) const noexcept {
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
    if (const auto* manifest = manifests_.find(identified.provider)) {
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

  bool ProcessCache::needsIdentification(pid_t foreground, bool recheck) const noexcept {
    return foreground > 0 && (recheck || foreground != group || (identified.provider == AgentProvider::unknown && attempts < acquisition_attempts));
  }

  AgentProvider ProcessCache::preferred(pid_t foreground) const noexcept {
    return foreground == group ? identified.provider : AgentProvider::unknown;
  }

  void ProcessCache::update(pid_t foreground, const IdentifiedProcess& process, bool installed) noexcept {
    attempts = process.provider != AgentProvider::unknown ? 0 : foreground == group ? std::min(attempts + 1, acquisition_attempts)
                                                                                    : 1;
    group = foreground;
    identified = process;
    if (identified.name.view().empty()) {
      identified.name.assign("process");
    }

    hooks_installed = installed;
  }

}
