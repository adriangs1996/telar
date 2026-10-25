#pragma once

#include "../agents/hook_settings.hpp"
#include "../agents/provider.hpp"
#include "../diagnostics/trace.hpp"
#include "process_cache.hpp"
#include "process_inspector.hpp"

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

  explicit ProcessProbe(const Inspector &inspector) noexcept
      : inspector_(inspector) {}

  Result observe(const Request &request) noexcept {
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

  void stop() noexcept {}

  FixedText<4096> directory(pid_t process) const noexcept {
    return inspector_.directory(process);
  }

private:
  const Inspector &inspector_;
};

}
