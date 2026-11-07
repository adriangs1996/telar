module;
#include "telar_platform/trace_macro.hpp"
#include <cstddef>
#include <new>

#include <cstdint>
#include <cstring>

#include <sys/types.h>

#include <unistd.h>


#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

export module telar.runtime.platform.process_probe;

import std;

export import telar.runtime.agents.session_host;
export import telar.config;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: platform/process_arguments.cppm
export {
namespace telar::runtime {

inline std::string_view processBasename(std::string_view path) noexcept {
  const auto slash = path.find_last_of("/\\");
  return path.substr(slash == std::string_view::npos ? 0 : slash + 1);
}

class ProcessArguments {
public:
  inline explicit ProcessArguments(std::string_view arguments) noexcept
      : arguments_(arguments) {}

  inline static ProcessArguments fromMacos(std::span<const char> buffer) noexcept {
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

  inline AgentProvider provider(const AgentManifests &manifests, std::string_view command) const noexcept {
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

  inline SessionHost sessionHost(AgentProvider provider) const noexcept {
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

private:
  inline static std::optional<std::string_view> next(std::string_view &remaining) noexcept {
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

  inline static bool genericRuntime(std::string_view command) noexcept {
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

  std::string_view arguments_;
};

}
}

// Interface: platform/process_lineage.cppm
export {
namespace telar::runtime {

struct ProcessLineage {
  inline std::span<const pid_t> ancestors() const noexcept {
    return std::span{processes}.first(count);
  }

  std::array<pid_t, 64> processes{};
  unsigned count = 0;
  bool descends = false;
};

}
}

// Interface: platform/process_inspector.cppm
export {
namespace telar::runtime {

struct ProcessIdentity {
  pid_t pid = 0;
  pid_t parent = 0;
  std::uint64_t started_seconds = 0;
  std::uint64_t started_microseconds = 0;
  pid_t process_group = 0;
  bool operator==(const ProcessIdentity &) const = default;
  inline bool sameInstance(const ProcessIdentity &other) const noexcept { return pid == other.pid && started_seconds == other.started_seconds && started_microseconds == other.started_microseconds; }
};

struct IdentifiedProcess {
  std::optional<ProcessIdentity> identity{};
  AgentProvider provider = AgentProvider::unknown;
  SessionHost session_host = SessionHost::unknown;
  FixedText<48> name{};
};

struct ProcessSnapshot {
  ProcessIdentity identity;
  pid_t terminal_foreground = 0;
};

class ProcessInspector {
public:
  inline explicit ProcessInspector(const AgentManifests &manifests = builtin_manifests, uid_t uid = ::geteuid()) noexcept
      : manifests_(manifests), uid_(uid) {}

  std::optional<ProcessIdentity> identity(pid_t process) const noexcept;
  std::optional<ProcessSnapshot> snapshot(pid_t process) const noexcept;
  std::optional<ProcessIdentity> peer(int socket) const noexcept;
  bool descendsFrom(const ProcessIdentity &process, pid_t root) const noexcept;
  ProcessLineage lineage(const ProcessIdentity &process, pid_t root) const noexcept;
  AgentProvider provider(pid_t process) const noexcept;
  AgentProvider ancestorProvider(const ProcessIdentity &process, pid_t root) const noexcept;
  FixedText<48> name(pid_t process) const noexcept;
  FixedText<4096> directory(pid_t process) const noexcept;
  FixedText<4096> terminal(pid_t process) const noexcept;
  IdentifiedProcess identifyGroup(pid_t group, AgentProvider preferred) const noexcept;

private:
  static ProcessArguments readArguments(pid_t process, std::span<char> buffer) noexcept;
  static FixedText<4096> executable(pid_t process) noexcept;
  static std::size_t groupMembers(pid_t group, std::span<pid_t> members) noexcept;
  IdentifiedProcess identifyProcess(pid_t process) const noexcept;
  const AgentManifests &manifests_;
  uid_t uid_;
};

}
}

// Interface: platform/descent_probe.cppm
export {
namespace telar::runtime {

struct DescentCheck {
  std::uint64_t client = 0;
  std::uint64_t client_generation = 0;
  std::uint64_t pane = 0;
  std::uint64_t pane_generation = 0;
  std::uint64_t request_id = 0;
  ProcessIdentity peer;
  pid_t root = 0;
};

template <typename Inspector>
concept LineageInspector = requires(const Inspector &inspector, ProcessIdentity process, pid_t root) {
  { inspector.lineage(process, root) } noexcept -> std::same_as<ProcessLineage>;
};

template <LineageInspector Inspector>
class DescentProbe {
public:
  struct Request {
    std::array<DescentCheck, 32> checks;
    std::size_t count = 0;
  };

  struct Completion {
    DescentCheck check;
    ProcessLineage lineage;
  };

  struct Result {
    std::array<Completion, 32> checks;
    std::size_t count = 0;
  };

  inline explicit DescentProbe(const Inspector &inspector) noexcept
      : inspector_(inspector) {}

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("agents.verifyDescent");
    Result result;
    for (const auto &check : std::span{request.checks}.first(request.count)) {
      result.checks[result.count++] = {check, inspector_.lineage(check.peer, check.root)};
    }
    return result;
  }

  inline void stop() noexcept {}

private:
  const Inspector &inspector_;
};

}
}

// Interface: platform/process_cache.cppm
export {
namespace telar::runtime {

struct ProcessCache {
  static constexpr unsigned acquisition_attempts = 6;

  inline bool needsIdentification(pid_t foreground, bool recheck) const noexcept {
    return foreground > 0 && (recheck || foreground != group || (identified.provider == AgentProvider::unknown && attempts < acquisition_attempts));
  }

  inline AgentProvider preferred(pid_t foreground) const noexcept {
    return foreground == group ? identified.provider : AgentProvider::unknown;
  }

  inline void update(pid_t foreground, const IdentifiedProcess &process, bool installed) noexcept {
    attempts = process.provider != AgentProvider::unknown ? 0 : foreground == group ? std::min(attempts + 1, acquisition_attempts)
                                                                                    : 1;
    group = foreground;
    identified = process;
    if (identified.name.view().empty()) {
      identified.name.assign("process");
    }
    hooks_installed = installed;
  }

  pid_t group = 0;
  IdentifiedProcess identified;
  unsigned attempts = 0;
  bool hooks_installed = false;
};

}
}

// Interface: platform/process_probe.cppm
export {
namespace telar::runtime {

struct ProcessProbeRequest {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  std::uint64_t cwd_revision = 0;
  pid_t root = 0;
  pid_t foreground = 0;
  ProcessCache cache{};
  bool recheck = false;
  bool discover_foreground = false;
};

struct ProcessProbeResult {
  ProcessProbeRequest request;
  std::optional<ProcessIdentity> identity;
  AgentProvider provider = AgentProvider::unknown;
  FixedText<48> name;
  FixedText<4096> cwd;
  bool shell_foreground = false;
  std::optional<ProcessIdentity> agent_identity;
  SessionHost session_host = SessionHost::unknown;
  bool hooks_installed = false;
  ProcessCache cache{};
  bool inspected = false;
};

template <typename Inspector>
concept ProcessProbeInspector = requires(const Inspector &inspector, pid_t process) {
  { inspector.identity(process) } noexcept -> std::same_as<std::optional<ProcessIdentity>>;
  { inspector.snapshot(process) } noexcept -> std::same_as<std::optional<ProcessSnapshot>>;
  { inspector.directory(process) } noexcept -> std::same_as<FixedText<4096>>;
  { inspector.identifyGroup(process, AgentProvider::unknown) } noexcept -> std::same_as<IdentifiedProcess>;
};

template <ProcessProbeInspector Inspector>
class ProcessProbe {
public:
  static constexpr std::size_t batch_capacity = 16;

  struct Request {
    std::array<ProcessProbeRequest, batch_capacity> panes{};
    std::size_t count = 0;
  };

  struct Result {
    std::array<ProcessProbeResult, batch_capacity> panes;
    std::size_t count = 0;
  };

  inline explicit ProcessProbe(const Inspector &inspector) noexcept
      : inspector_(inspector) {}

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("process.observe");
    Result result;
    for (const auto &pane : std::span{request.panes}.first(request.count)) {
      const auto root = inspector_.snapshot(pane.root);
      const auto foreground_group = pane.discover_foreground && root ? root->terminal_foreground : pane.foreground;
      if (!root || foreground_group <= 0) {
        continue;
      }

      const auto foreground = foreground_group == pane.root ? std::optional{root->identity} : inspector_.identity(foreground_group);
      auto &observation = result.panes[result.count];
      observation.request = pane;
      observation.request.foreground = foreground_group;
      observation.identity = foreground.value_or(ProcessIdentity{.pid = foreground_group, .process_group = foreground_group});
      observation.cache = pane.cache;
      observation.inspected = pane.cache.needsIdentification(foreground_group, pane.recheck);
      if (observation.inspected) {
        const auto preferred = pane.cache.preferred(foreground_group);
        const auto identified = inspector_.identifyGroup(foreground_group, preferred);
        observation.cache.update(foreground_group, identified, hooksInstalled(identified.provider, identified.session_host));
      }

      const auto &identified = observation.cache.identified;
      observation.provider = identified.provider;
      observation.agent_identity = identified.identity;
      observation.session_host = identified.session_host;
      observation.hooks_installed = observation.cache.hooks_installed;
      observation.name = identified.name;
      observation.cwd = inspector_.directory(pane.root);
      observation.shell_foreground = pane.root == foreground_group && observation.provider == AgentProvider::unknown;
      if (inspector_.identity(pane.root) == root->identity && (foreground_group == pane.root || inspector_.identity(foreground_group) == foreground)) {
        ++result.count;
      }
    }

    return result;
  }

  inline void stop() noexcept {}

  inline FixedText<4096> directory(pid_t process) const noexcept {
    return inspector_.directory(process);
  }

private:
  const Inspector &inspector_;
};

}
}
