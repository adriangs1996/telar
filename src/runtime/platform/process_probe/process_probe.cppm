module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.platform.process_probe;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.session_host;
import telar.config.runtime;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: platform/process_arguments.cppm
export {
  namespace telar::runtime {

    std::string_view processBasename(std::string_view path) noexcept;

    class ProcessArguments {
    public:
      explicit ProcessArguments(std::string_view arguments) noexcept;

      static ProcessArguments fromMacos(std::span<const char> buffer) noexcept;

      [[nodiscard]] AgentProvider provider(const AgentManifests& manifests, std::string_view command) const noexcept;

      [[nodiscard]] SessionHost sessionHost(AgentProvider provider) const noexcept;

      // The arguments joined by spaces into `output`, cut where it ends.
      [[nodiscard]] tbc::val_a<std::string_view> joined(tbc::val_a<std::span<char>> output) const noexcept;

    private:
      static ds::Option<std::string_view> next(std::string_view& remaining) noexcept;

      static bool genericRuntime(std::string_view command) noexcept;

      std::string_view arguments_;
    };

  }
}

// Interface: platform/process_lineage.cppm
export {
  namespace telar::runtime {

    struct ProcessLineage {
      static constexpr std::size_t maximum_ancestors = 64;

      [[nodiscard]] std::span<const pid_t> ancestors() const noexcept;

      ds::Array<pid_t, maximum_ancestors> processes{};
      unsigned count = 0;
      bool descends = false;
    };

  }
}

// Interface: platform/process_inspector.cppm
export {
  namespace telar::runtime {

    // The longest process name, and the longest path, an inspector reports.
    inline constexpr std::size_t process_name_bytes = 48;
    inline constexpr std::size_t process_path_bytes = 4096;

    struct ProcessIdentity {
      pid_t pid = 0;
      pid_t parent = 0;
      std::uint64_t started_seconds = 0;
      std::uint64_t started_microseconds = 0;
      pid_t process_group = 0;
      bool operator==(const ProcessIdentity&) const = default;

      [[nodiscard]] bool sameInstance(const ProcessIdentity& other) const noexcept;
    };

    struct IdentifiedProcess {
      ds::Option<ProcessIdentity> identity;
      AgentProvider provider = AgentProvider::unknown;
      SessionHost session_host = SessionHost::unknown;
      FixedText<process_name_bytes> name;
    };

    // A process's command line, its arguments joined by spaces, and the agent it runs.
    struct CommandLine {
      std::string_view text;
      AgentProvider provider = AgentProvider::unknown;
    };

    struct ProcessSnapshot {
      ProcessIdentity identity;
      pid_t terminal_foreground = 0;
    };

    // The lowest distinct TCP ports a process group listens on, ascending.
    struct ListeningPorts {
      ds::Array<std::uint16_t, max_listed_ports> values{};
      std::uint8_t count = 0;

      void add(std::uint16_t port) noexcept;

      [[nodiscard]] std::span<const std::uint16_t> view() const noexcept;

      bool operator==(const ListeningPorts& other) const noexcept;
    };

    // Reads the operating system's process table: every query is const and keeps no state, so threads
    // share one inspector.
    class TBC_SHARED ProcessInspector {
    public:
      explicit ProcessInspector(const AgentManifests& manifests = builtinManifests(), uid_t uid = ::geteuid()) noexcept;

      [[nodiscard]] ds::Option<ProcessIdentity> identity(pid_t process) const noexcept;
      [[nodiscard]] ds::Option<ProcessSnapshot> snapshot(pid_t process) const noexcept;
      [[nodiscard]] ds::Option<ProcessIdentity> peer(int socket) const noexcept;
      [[nodiscard]] bool descendsFrom(const ProcessIdentity& process, pid_t root) const noexcept;
      [[nodiscard]] ProcessLineage lineage(const ProcessIdentity& process, pid_t root) const noexcept;
      [[nodiscard]] AgentProvider provider(pid_t process) const noexcept;
      [[nodiscard]] FixedText<process_name_bytes> name(pid_t process) const noexcept;
      [[nodiscard]] FixedText<process_path_bytes> directory(pid_t process) const noexcept;
      [[nodiscard]] FixedText<process_path_bytes> terminal(pid_t process) const noexcept;
      [[nodiscard]] IdentifiedProcess identifyGroup(pid_t group, AgentProvider preferred) const noexcept;
      [[nodiscard]] ListeningPorts listeningPorts(pid_t group) const noexcept;
      // Of any user's process the system lets the runtime read; the text views `output`.
      [[nodiscard]] tbc::val_a<CommandLine> commandLine(pid_t process, tbc::val_a<std::span<char>> output) const noexcept;

    private:
      // The arguments view the caller's buffer.
      static tbc::val_a<ProcessArguments> readArguments(pid_t process, tbc::val_a<std::span<char>> buffer) noexcept;
      static FixedText<process_path_bytes> executable(pid_t process) noexcept;
      static std::size_t groupMembers(pid_t group, std::span<pid_t> members) noexcept;
      [[nodiscard]] IdentifiedProcess identifyProcess(pid_t process) const noexcept;
      const AgentManifests& manifests_;
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
    concept LineageInspector = requires(const Inspector& inspector, ProcessIdentity process, pid_t root) {
      { inspector.lineage(process, root) } noexcept -> std::same_as<ProcessLineage>;
    };

    // Kept whole: tests instantiate it with their own fake Inspector (descent_test's GatedLineageInspector).
    template <LineageInspector Inspector>
    class TBC_GENERIC DescentProbe {
    public:
      static constexpr std::size_t batch_capacity = 32;

      struct Request {
        ds::Array<DescentCheck, batch_capacity> checks;
        std::size_t count = 0;
      };

      struct Completion {
        DescentCheck check;
        ProcessLineage lineage;
      };

      struct Result {
        ds::Array<Completion, batch_capacity> checks;
        std::size_t count = 0;
      };

      inline explicit DescentProbe(const Inspector& inspector) noexcept
          : inspector_(inspector) {}

      inline Result observe(const Request& request) noexcept {
        TELAR_TRACE("agents.verifyDescent");
        Result result;

        for (const auto& check : std::span{request.checks}.first(request.count)) {
          result.checks.atMut(result.count++) = {check, inspector_.lineage(check.peer, check.root)};
        }

        return result;
      }

      inline void stop() noexcept {}

    private:
      const Inspector& inspector_;
    };

  }
}

// Interface: platform/process_cache.cppm
export {
  namespace telar::runtime {

    struct ProcessCache {
      static constexpr unsigned acquisition_attempts = 6;

      [[nodiscard]] bool needsIdentification(pid_t foreground, bool recheck) const noexcept;

      [[nodiscard]] AgentProvider preferred(pid_t foreground) const noexcept;

      void update(pid_t foreground, const IdentifiedProcess& process, bool installed) noexcept;

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
      bool ports = false;
    };

    struct ProcessProbeResult {
      ProcessProbeRequest request;
      ds::Option<ProcessIdentity> identity;
      AgentProvider provider = AgentProvider::unknown;
      FixedText<process_name_bytes> name;
      FixedText<process_path_bytes> cwd;
      bool shell_foreground = false;
      ds::Option<ProcessIdentity> agent_identity;
      SessionHost session_host = SessionHost::unknown;
      bool hooks_installed = false;
      ProcessCache cache{};
      ListeningPorts ports;
      bool inspected = false;
      bool ports_inspected = false;
    };

    template <typename Inspector>
    concept ProcessProbeInspector = requires(const Inspector& inspector, pid_t process) {
      { inspector.identity(process) } noexcept -> std::same_as<ds::Option<ProcessIdentity>>;
      { inspector.snapshot(process) } noexcept -> std::same_as<ds::Option<ProcessSnapshot>>;
      { inspector.directory(process) } noexcept -> std::same_as<FixedText<process_path_bytes>>;
      { inspector.identifyGroup(process, AgentProvider::unknown) } noexcept -> std::same_as<IdentifiedProcess>;
      { inspector.listeningPorts(process) } noexcept -> std::same_as<ListeningPorts>;
    };

    // A stateless view of an inspector, shared as the inspector is.
    // Kept whole: tests instantiate it with their own fake Inspector (process_identification_test's
    // LeaderlessGroupInspector).
    template <ProcessProbeInspector Inspector>
    class TBC_SHARED TBC_GENERIC ProcessProbe {
    public:
      static constexpr std::size_t batch_capacity = 16;

      struct Request {
        ds::Array<ProcessProbeRequest, batch_capacity> panes{};
        std::size_t count = 0;
      };

      struct Result {
        ds::Array<ProcessProbeResult, batch_capacity> panes;
        std::size_t count = 0;
      };

      inline explicit ProcessProbe(const Inspector& inspector) noexcept
          : inspector_(inspector) {}

      inline Result observe(const Request& request) noexcept {
        TELAR_TRACE("process.observe");
        Result result;

        for (const auto& pane : std::span{request.panes}.first(request.count)) {
          const auto root = inspector_.snapshot(pane.root);
          const auto foreground_group = pane.discover_foreground && root ? root->terminal_foreground : pane.foreground;
          if (!root || foreground_group <= 0) {
            continue;
          }

          const auto foreground = foreground_group == pane.root ? ds::Option{root->identity} : inspector_.identity(foreground_group);
          auto& observation = result.panes.atMut(result.count);

          observation.request = pane;
          observation.request.foreground = foreground_group;
          observation.identity = foreground.valueOr(ProcessIdentity{.pid = foreground_group, .process_group = foreground_group});
          observation.cache = pane.cache;
          observation.inspected = pane.cache.needsIdentification(foreground_group, pane.recheck);
          if (observation.inspected) {
            const auto preferred = pane.cache.preferred(foreground_group);
            const auto identified = inspector_.identifyGroup(foreground_group, preferred);

            observation.cache.update(foreground_group, identified, hooksInstalled(identified.provider, identified.session_host));
          }

          const auto& identified = observation.cache.identified;

          observation.provider = identified.provider;
          observation.agent_identity = identified.identity;
          observation.session_host = identified.session_host;
          observation.hooks_installed = observation.cache.hooks_installed;
          observation.name = identified.name;
          observation.cwd = inspector_.directory(pane.root);
          if (pane.ports) {
            observation.ports = inspector_.listeningPorts(foreground_group);
            observation.ports_inspected = true;
          }

          observation.shell_foreground = pane.root == foreground_group && observation.provider == AgentProvider::unknown;
          if (inspector_.identity(pane.root) == root->identity && (foreground_group == pane.root || inspector_.identity(foreground_group) == foreground)) {
            ++result.count;
          }
        }

        return result;
      }

      inline void stop() noexcept {}

      [[nodiscard]] inline FixedText<process_path_bytes> directory(pid_t process) const noexcept {
        return inspector_.directory(process);
      }

    private:
      const Inspector& inspector_;
    };

  }
}
