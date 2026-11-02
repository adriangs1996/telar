#pragma once

#include "flow_key.hpp"
#include "../platform/process_inspector.hpp"
#if defined(__APPLE__)
#include <libproc.h>
#endif

namespace telar::runtime::redirect {

class SocketOwners {
public:
  static constexpr std::size_t maximum_processes = 16;
  static constexpr std::size_t maximum_descriptors = 4096;

  struct Result {
    std::optional<ProcessIdentity> process;
    bool complete = true;
  };

  explicit SocketOwners(uid_t uid, std::span<const ProcessIdentity> selected) : inspector_(builtin_manifests, uid) {
    if (selected.size() > maximum_processes) { throw std::invalid_argument{"Too many selected processes"}; }
    for (const auto &requested : selected) {
      const auto current = inspector_.identity(requested.pid);
      if (!current || (requested.started_seconds != 0 && !current->sameInstance(requested))) { throw std::invalid_argument{"Selected process is unavailable, replaced or belongs to another account"}; }
      if (std::ranges::any_of(std::span{processes_}.first(count_), [&](const auto &other) { return other.pid == current->pid; })) { throw std::invalid_argument{"Duplicate selected process"}; }
      processes_[count_++] = *current;
    }
  }

  bool enabled() const noexcept { return count_ != 0; }
  std::span<const ProcessIdentity> processes() const noexcept { return std::span{processes_}.first(count_); }

  Result find(const FlowKey &flow) noexcept;

private:


  ProcessInspector inspector_;
  std::array<ProcessIdentity, maximum_processes> processes_;
  std::size_t count_ = 0;
#if defined(__APPLE__)
  std::array<proc_fdinfo, maximum_descriptors> descriptors_;
#endif
};

}

#if defined(__APPLE__)
#include "macos/socket_owners.hpp"
#else
#include "linux/socket_owners.hpp"
#endif
