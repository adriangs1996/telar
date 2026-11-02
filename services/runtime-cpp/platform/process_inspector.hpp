#pragma once

#include "../agents/builtin_manifests.hpp"
#include "../agents/session_host.hpp"
#include "../memory/fixed_text.hpp"
#include "process_lineage.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <sys/types.h>
#include <unistd.h>

namespace telar::runtime {

struct ProcessIdentity {
  pid_t pid = 0;
  pid_t parent = 0;
  std::uint64_t started_seconds = 0;
  std::uint64_t started_microseconds = 0;
  pid_t process_group = 0;
  bool operator==(const ProcessIdentity &) const = default;
  bool sameInstance(const ProcessIdentity &other) const noexcept { return pid == other.pid && started_seconds == other.started_seconds && started_microseconds == other.started_microseconds; }
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
  explicit ProcessInspector(const AgentManifests &manifests = builtin_manifests, uid_t uid = ::geteuid()) noexcept
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
  IdentifiedProcess identifyGroup(pid_t group, AgentProvider preferred) const noexcept;

private:
  IdentifiedProcess identifyProcess(pid_t process) const noexcept;
  const AgentManifests &manifests_;
  uid_t uid_;
};

}
