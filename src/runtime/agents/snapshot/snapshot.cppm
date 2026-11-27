export module telar.runtime.agents.snapshot;

import std;

import telar.config.runtime;

import telar.runtime.host.process_probe;
import telar.runtime.agents.description_generator;

import telar.platform.events;

import telar.wire.vocabulary;
import telar.wire.agents;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.runtime.host.session_host;
import telar.base.ds;

// Interface: agents/evidence_state.cppm
export {
  namespace telar::runtime {

    class AgentEvidenceState {
    public:
      [[nodiscard]] AgentProvider provider() const noexcept;
      [[nodiscard]] bool accepts(AgentProvider incoming) const noexcept;
      void claim(AgentProvider incoming) noexcept;
      bool applyReport(const ReportAgent& incoming, ObservationTime now);
      bool applyScreen(AgentSignal signal, ObservationTime now, AgentStatus projected, bool interrupted) noexcept;
      [[nodiscard]] ds::Option<AgentEvidence> choose(std::int64_t now) const noexcept;
      // The report that still holds: an unexpired one, or a settling one no screen confirmed,
      // which ends the turn when it expires.
      [[nodiscard]] ds::Option<AgentEvidence> activeReport(std::int64_t now) const noexcept;
      // Whether what the screen shows now replaces the report: a question on screen while the
      // report says the agent works, work on screen while it says the agent waits, and Claude's
      // idle prompt after a turn the user stopped, which no hook reports.
      [[nodiscard]] bool supersedes(const AgentEvidence& reported, std::int64_t now) const noexcept;
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
      FixedText<agent_report_event_bytes> report_event;
      // The last status the agent settled in, ready or failed, which outlives its evidence while
      // the agent's process runs; unknown once work starts again.
      AgentStatus settled = AgentStatus::unknown;
      // Whether the latest screen the observer read still shows the screen evidence, and since when
      // it does not.
      bool screen_current = false;
      std::int64_t screen_lost_at = 0;
      bool hooks_seen = false;

      // How long Claude's idle prompt shows before it ends a turn no hook ended.
      static constexpr std::chrono::milliseconds ready_settle{1'500};
      // How long the working phrases of an agent no reader knows may be gone before its work ends.
      static constexpr std::chrono::milliseconds lost_working{3'000};

    private:
      // Codex's own screen and reports: whether the screen's signal may replace what the report says.
      bool applyCodexScreen(AgentSignal signal, ObservationTime now, bool interrupted) noexcept;
    };

  }
}

// Interface: agents/progress.cppm
export {
  namespace telar::runtime {

    class AgentProgress {
    public:
      bool apply(const ReportAgentProgress& report);
      // Takes the final message a session restored after a restart had reported before it,
      // unless the agent has said one since.
      void restore(std::string_view final_message);
      [[nodiscard]] std::uint16_t done() const noexcept;
      [[nodiscard]] std::uint16_t total() const noexcept;
      [[nodiscard]] std::string_view step() const noexcept;
      [[nodiscard]] std::string_view finalMessage() const noexcept;

      static constexpr std::size_t task_capacity = 128;

    private:
      struct Task {
        FixedText<agent_report_plan_bytes> subject;
        AgentPlanStatus status = AgentPlanStatus::pending;
      };

      FixedText<agent_report_message_bytes> final_message_;
      ds::Array<Task, task_capacity> tasks_{};
      std::size_t count_ = 0;
      bool uses_tasks_ = false;
      std::uint16_t done_ = 0;
      std::uint16_t total_ = 0;
      FixedText<agent_report_plan_bytes> step_;
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

      FixedText<agent_report_session_bytes> session;
      FixedText<agent_report_session_file_bytes> path;
      AgentSessionFileKind kind = AgentSessionFileKind::claude_transcript;
      ds::Option<std::uint64_t> offset;
      ds::Option<FixedText<agent_report_title_bytes>> last_title;
      std::chrono::steady_clock::time_point checked_at;
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
      ds::Option<FixedText<agent_report_title_bytes>> title;
    };

  }
}

// Interface: agents/agent.cppm
export {
  namespace telar::runtime {

    struct Agent {
      explicit Agent(PaneKey key);

      void setSession(std::string_view value);
      bool report(const ReportAgent& incoming, ObservationTime now = ObservationTime::now());
      bool observeProcess(ProcessIdentity identity, AgentProvider incoming, ObservationTime now = ObservationTime::now());
      bool observeScreen(AgentSignal signal, ObservationTime now = ObservationTime::now());
      bool setProcessContext(SessionHost host, bool installed, ds::Option<ProcessIdentity> identity) noexcept;
      [[nodiscard]] std::string_view eventFor(const AgentEvidence& selected, std::int64_t now) const noexcept;
      bool project(std::int64_t now);
      void forgetReports();
      bool reportTitle(std::string_view value);
      void observeInput(std::span<const Byte> bytes);
      bool queueDescription() noexcept;
      void finishTitleCapture() noexcept;
      [[nodiscard]] bool hasPendingDescription() const noexcept;

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
      ds::Array<Byte, agent_session_id_bytes> session_id{};
      FixedText<agent_report_session_bytes> session;
      SessionFileWatch file_watch;
      FixedText<agent_report_event_bytes> event;
      FixedText<agent_report_title_bytes> title;
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
      // Whether the screen ended the running turn, which a later Stop then finishes as done.
      bool screen_ended_turn = false;
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

      [[nodiscard]] const Agent* find(std::uint64_t pane, std::uint64_t generation) const noexcept;
      Agent* findMut(std::uint64_t pane, std::uint64_t generation) noexcept;
      Agent& ensure(std::uint64_t pane, std::uint64_t generation);

      // The predicate is the caller's type, so this member keeps its body here.
      template <typename Predicate>
      [[tbc::generic]] inline void removeIf(const Predicate& predicate) {
        if (records_.retain([&](const auto& agent) {
              return !predicate(*agent);
            }) != 0) {
          changed();
        }
      }

      [[nodiscard]] std::span<const ds::Box<Agent, Memory>> records() const noexcept;
      std::span<ds::Box<Agent, Memory>> recordsMut() noexcept;
      void changed() noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;

      static constexpr std::size_t capacity = 64;

    private:
      Memory& memory_;
      ds::Vec<ds::Box<Agent, Memory>, Memory> records_;
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
      static bool antigravityPath(std::string_view path, std::string_view session) noexcept;
      void antigravity(const SessionFileWatch& watch, Result& result);
      // The title of an annotation Antigravity writes in protobuf's text format, `title:"…"`.
      ds::Option<FixedText<agent_report_title_bytes>> annotationTitle(std::string_view input);
      // A quoted string of an annotation, from its opening quote, into decoded_: the index after
      // its closing quote.
      std::size_t annotationString(std::string_view input, std::size_t start);
      // The value of the `title` field whose name ends at `index`, into `title`: the index after
      // it.
      std::size_t annotationTitleValue(std::string_view input, std::size_t index, ds::Option<FixedText<agent_report_title_bytes>>& title);
      // A field's name from `index`, and its value when it is the title at the top level, into
      // `title`: the index after what it read.
      std::size_t annotationField(std::string_view input, std::size_t index, bool top, ds::Option<FixedText<agent_report_title_bytes>>& title);
      ds::Option<FixedText<agent_report_title_bytes>> readTitle(std::string_view input, ds::Option<std::string_view> session);
      static ds::Option<std::uint64_t> regularFileSize(const FileDescriptor& file) noexcept;
      std::string_view read(int descriptor, std::uint64_t offset, std::size_t limit);

      static constexpr std::size_t title_capacity = 96;
      static constexpr std::size_t metadata_capacity = std::size_t{16} * 1024;
      static constexpr std::size_t transcript_capacity = std::size_t{64} * 1024;
      static constexpr std::size_t line_capacity = 4096;
      ds::String<Memory> path_;
      ds::Vec<char, Memory> bytes_;
      ds::String<Memory> decoded_;
    };

    extern template class SessionFileReader<Memory>;
    extern template class SessionFileReader<ConcurrentMemory>;

  }
}
