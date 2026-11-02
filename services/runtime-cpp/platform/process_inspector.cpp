#include "process_inspector.hpp"
#include "../text/utf8.hpp"
#include "process_arguments.hpp"
#include <cstring>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>

namespace telar::runtime {
namespace {

constexpr std::size_t maximum_process_argument_bytes = 16 * 1024;

ProcessArguments readArguments(pid_t process, std::span<char> buffer) noexcept {
  std::size_t length = buffer.size();
  int selector[]{CTL_KERN, KERN_PROCARGS2, process};
  if (::sysctl(selector, 3, buffer.data(), &length, nullptr, 0) != 0 || length > buffer.size()) {
    return ProcessArguments{{}};
  }

  return ProcessArguments::fromMacos(buffer.first(length));
}

}

std::optional<ProcessIdentity> ProcessInspector::identity(pid_t process) const noexcept {
  const auto observed = snapshot(process);
  return observed ? std::optional{observed->identity} : std::nullopt;
}

std::optional<ProcessSnapshot> ProcessInspector::snapshot(pid_t process) const noexcept {
  if (process <= 0) {
    return std::nullopt;
  }

  proc_bsdinfo information{};
  if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information) || information.pbi_uid != uid_) {
    return std::nullopt;
  }

  return ProcessSnapshot{
      .identity = {process, static_cast<pid_t>(information.pbi_ppid), information.pbi_start_tvsec, information.pbi_start_tvusec, static_cast<pid_t>(information.pbi_pgid)},
      .terminal_foreground = static_cast<pid_t>(information.e_tpgid),
  };
}

std::optional<ProcessIdentity> ProcessInspector::peer(int socket) const noexcept {
  pid_t process = 0;
  socklen_t length = sizeof(process);
  if (::getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &process, &length) != 0 || length != sizeof(process)) {
    return std::nullopt;
  }

  return identity(process);
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
  std::array<char, PROC_PIDPATHINFO_MAXSIZE> executable{};
  if (::proc_pidpath(process, executable.data(), executable.size()) <= 0) {
    return AgentProvider::unknown;
  }

  const auto identified = manifests_.fromExecutable(processBasename(executable.data()));
  if (identified != AgentProvider::unknown) {
    return identified;
  }

  std::array<char, maximum_process_argument_bytes> arguments;
  return readArguments(process, arguments).provider(manifests_, executable.data());
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
  const int bytes = ::proc_listpids(PROC_PGRP_ONLY, static_cast<std::uint32_t>(group), members.data(), sizeof(members));
  if (bytes <= 0) {
    return leader;
  }

  std::optional<IdentifiedProcess> selected;
  const auto count = std::min(members.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t));
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

FixedText<48> ProcessInspector::name(pid_t process) const noexcept {
  FixedText<48> result;
  proc_bsdinfo information{};
  if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information)) {
    const std::string_view candidate{information.pbi_comm, ::strnlen(information.pbi_comm, sizeof(information.pbi_comm))};
    try {
      DisplayText16<48, false>::validate(candidate);
      result.assign(candidate);
    } catch (...) {
    }
  }

  return result;
}

FixedText<4096> ProcessInspector::directory(pid_t process) const noexcept {
  FixedText<4096> result;
  proc_vnodepathinfo information{};
  if (::proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &information, sizeof(information)) == sizeof(information)) {
    const auto &path = information.pvi_cdir.vip_path;
    const auto length = ::strnlen(path, sizeof(path));
    if (length != 0 && length < sizeof(path) && path[0] == '/') {
      result.assign({path, length});
    }
  }

  return result;
}

}
