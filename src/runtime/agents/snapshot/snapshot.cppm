module;
#include "tbc/annotations.hpp"

export module telar.runtime.agents.snapshot;

import std;

import telar.config.runtime;

import telar.runtime.platform.process_probe;
import telar.runtime.agents.description_generator;

import telar.platform.events;

import telar.wire.vocabulary;
import telar.wire.agents;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.runtime.platform.session_host;
import telar.base.ds;

// Interface: agents/evidence_state.cppm
export {
  namespace telar::runtime {

    class AgentEvidenceState {
    public:
      AgentProvider provider() const noexcept;
      bool accepts(AgentProvider incoming) const noexcept;
      void claim(AgentProvider incoming) noexcept;
      bool applyReport(const ReportAgent& incoming, ObservationTime now);
      bool applyScreen(AgentSignal signal, ObservationTime now, AgentStatus projected, bool interrupted) noexcept;
      ds::Option<AgentEvidence> choose(std::int64_t now) const noexcept;
      void expire(std::int64_t now) noexcept;
      void clearReport() noexcept;

      ds::Option<AgentEvidence> process;
      ds::Option<AgentEvidence> screen;
      ds::Option<AgentEvidence> report;
      ds::Option<AgentEvidence> work;
      AgentProvider reporter = AgentProvider::unknown;
      AgentAuthority authority = AgentAuthority::candidate;
      AgentReportState report_state = AgentReportState::ready;
      AgentBlockedReason report_reason = AgentBlockedReason::none;
      FixedText<96> report_event;
      bool hooks_seen = false;
    };

  }
}

// Interface: agents/progress.cppm
export {
  namespace telar::runtime {

    class AgentProgress {
    public:
      bool apply(const ReportAgentProgress& report);
      std::uint16_t done() const noexcept;
      std::uint16_t total() const noexcept;
      std::string_view step() const noexcept;

      FixedText<2048> final_message;
      static constexpr std::size_t task_capacity = 128;

    private:
      struct Task {
        FixedText<96> subject;
        AgentPlanStatus status = AgentPlanStatus::pending;
      };

      std::array<Task, task_capacity> tasks_{};
      std::size_t count_ = 0;
      bool uses_tasks_ = false;
      std::uint16_t done_ = 0;
      std::uint16_t total_ = 0;
      FixedText<96> step_;
    };

  }
}

// Interface: agents/session_file.cppm
export {
  namespace telar::runtime {

    struct SessionFileWatch {
      void configure(std::string_view reference, std::string_view file, AgentSessionFileKind format);
      void clear() noexcept;
      bool remember(std::string_view title);

      FixedText<64> session;
      FixedText<1024> path;
      AgentSessionFileKind kind = AgentSessionFileKind::claude_transcript;
      ds::Option<std::uint64_t> offset;
      ds::Option<FixedText<96>> last_title;
      std::chrono::steady_clock::time_point checked_at{};
      std::uint64_t revision = 0;

    private:
      void resetProgress() noexcept;
    };

    struct SessionFileRequest {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      SessionFileWatch watch;
    };

    struct SessionFileResult {
      SessionFileRequest request;
      ds::Option<std::uint64_t> offset;
      ds::Option<FixedText<96>> title;
    };

  }
}

// Interface: agents/agent.cppm
export {
  namespace telar::runtime {

    struct Agent {
      Agent(std::uint64_t pane, std::uint64_t generation);

      void setSession(std::string_view value);
      bool report(const ReportAgent& incoming, ObservationTime now = ObservationTime::now());
      bool observeProcess(ProcessIdentity identity, AgentProvider incoming, ObservationTime now = ObservationTime::now());
      bool observeScreen(AgentSignal signal, ObservationTime now = ObservationTime::now());
      bool setProcessContext(SessionHost host, bool installed, ds::Option<ProcessIdentity> identity) noexcept;
      std::string_view eventFor(const AgentEvidence& selected, std::int64_t now) const noexcept;
      bool project(std::int64_t now);
      void forgetReports();
      bool reportTitle(std::string_view value);
      void observeInput(std::span<const Byte> bytes);
      bool queueDescription() noexcept;
      void finishTitleCapture() noexcept;
      bool hasPendingDescription() const noexcept;

      std::uint64_t pane;
      std::uint64_t generation;
      AgentEvidenceState evidence;
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus status = AgentStatus::unknown;
      AgentBlockedReason blocked_reason = AgentBlockedReason::none;
      AgentSource source = AgentSource::screen;
      AgentAuthority authority = AgentAuthority::candidate;
      Byte confidence = 0;
      AgentTitleSource title_source = AgentTitleSource::telar;
      AgentTitleState title_state = AgentTitleState::placeholder;
      std::array<Byte, 16> session_id{};
      FixedText<64> session;
      SessionFileWatch file_watch;
      FixedText<96> event;
      FixedText<96> title;
      DescriptionCapture description_capture;
      DescriptionPhase description_phase = DescriptionPhase::waiting_query;
      std::uint64_t description_revision = 0;
      AgentProgress progress;
      std::uint64_t worktree = 0;
      std::uint64_t sequence = 1;
      std::uint64_t cwd_revision = 0;
      std::uint64_t title_revision = 0;
      std::int64_t observed_at = 0;
      std::int64_t changed_at = 0;
      std::int64_t expires_at = 0;
      bool acknowledged = true;
      bool in_pane = false;
      ds::Option<ProcessIdentity> process_identity;
      ds::Option<ProcessIdentity> projected_process;
      ds::Option<ProcessIdentity> agent_identity;
      SessionHost session_host = SessionHost::unknown;
      bool hooks_installed = false;
      ds::Option<std::int64_t> unreported_work_at;
      std::uint64_t interrupt_revision = 0;
      bool interrupt_draft_cleared = false;
      ds::Option<std::chrono::steady_clock::time_point> interrupt_at;
      ds::Option<std::chrono::steady_clock::time_point> interrupt_idle_at;
    };

  }
}

// Interface: agents/registry.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class AgentRegistry {
    public:
      explicit AgentRegistry(Memory& memory);

      Agent* find(std::uint64_t pane, std::uint64_t generation) const noexcept;
      Agent& ensure(std::uint64_t pane, std::uint64_t generation);

      // The predicate is the caller's type, so this member keeps its body here.
      template <typename Predicate>
      TBC_GENERIC inline void removeIf(Predicate&& predicate) {
        if (std::erase_if(records_, [&](const auto& agent) {
              return predicate(*agent);
            }) != 0) {
          changed();
        }
      }

      std::span<const Owned<Agent, Memory>> records() const noexcept;
      void changed() noexcept;
      std::uint64_t revision() const noexcept;

      static constexpr std::size_t capacity = 64;

    private:
      Memory& memory_;
      Vector<Owned<Agent, Memory>, Memory> records_;
      std::uint64_t revision_ = 1;
    };

    extern template class AgentRegistry<Memory>;
    extern template class AgentRegistry<ConcurrentMemory>;
    // The test fixtures run the agent service on SystemAllocator, through ClientPeer.
    extern template class AgentRegistry<SystemAllocator>;

  }
}

// Interface: agents/session_file_reader.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class SessionFileReader {
    public:
      using Request = SessionFileRequest;
      using Result = SessionFileResult;

      explicit SessionFileReader(Memory& memory);

      Result observe(const Request& request) noexcept;
      void stop() noexcept;

    private:
      void codex(const SessionFileWatch& watch, Result& result);
      static bool cursorPath(std::string_view path, std::string_view session) noexcept;
      void cursor(const SessionFileWatch& watch, Result& result);
      void claude(const SessionFileWatch& watch, Result& result);
      ds::Option<FixedText<96>> readTitle(std::string_view input, ds::Option<std::string_view> session);
      static ds::Option<std::uint64_t> regularFileSize(const FileDescriptor& file) noexcept;
      std::string_view read(int descriptor, std::uint64_t offset, std::size_t limit);

      static constexpr std::size_t title_capacity = 96;
      static constexpr std::size_t metadata_capacity = 16 * 1024;
      static constexpr std::size_t transcript_capacity = 64 * 1024;
      static constexpr std::size_t line_capacity = 4096;
      String<Memory> path_;
      Vector<char, Memory> bytes_;
      String<Memory> decoded_;
    };

    extern template class SessionFileReader<Memory>;
    extern template class SessionFileReader<ConcurrentMemory>;

  }
}
