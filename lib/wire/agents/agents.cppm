export module telar.wire.agents;

// Agent reports and snapshots, and the requests that act on agents.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module for agents.cpp.
export extern "C++" {
  namespace telar {

    // The byte and count limits of the agent reports and snapshots.
    inline constexpr std::size_t agent_report_session_bytes = 64;
    inline constexpr std::size_t agent_report_session_file_bytes = 1024;
    inline constexpr std::size_t agent_report_event_bytes = 96;
    inline constexpr std::size_t agent_report_provider_bytes = 64;
    inline constexpr std::size_t agent_report_tool_call_bytes = 256;
    inline constexpr std::size_t agent_report_command_bytes = 65536;
    inline constexpr std::size_t agent_report_path_bytes = 4096;
    inline constexpr std::size_t agent_report_title_bytes = 96;
    inline constexpr std::size_t agent_report_branch_bytes = 200;
    inline constexpr std::size_t agent_report_message_bytes = 2048;
    inline constexpr std::size_t agent_report_plan_bytes = 96;
    inline constexpr std::size_t max_agent_snapshot_entries = 64;

    struct AcknowledgeAgent {
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
    };

    template <>
    struct MessageSchema<AcknowledgeAgent>
        : Schema<Direction::client, ClientTag::acknowledge_agent, Field<&AcknowledgeAgent::pane_id, NonzeroU64, "pane_id">, Field<&AcknowledgeAgent::pane_generation, u64, "pane_generation">> {};

    struct QueryAgents {
      std::uint64_t request_id{};
    };

    template <>
    struct MessageSchema<QueryAgents>
        : Schema<Direction::client, ClientTag::query_agents, Field<&QueryAgents::request_id, NonzeroU64, "request_id">> {};

    struct ReportAgentSession {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      std::string_view session;

      void validate() const;
    };

    template <>
    struct MessageSchema<ReportAgentSession>
        : Schema<Direction::client, ClientTag::report_agent_session, Field<&ReportAgentSession::request_id, NonzeroU64, "request_id">, Field<&ReportAgentSession::pane_id, NonzeroU64, "pane_id">, Field<&ReportAgentSession::pane_generation, u64, "pane_generation">, Field<&ReportAgentSession::session, Text16<agent_report_session_bytes>, "session">> {};

    struct ReportAgent {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      AgentProvider provider{};
      AgentReportState state{};
      std::string_view session;
      std::string_view session_file;
      AgentSessionFileKind session_file_kind{};
      AgentBlockedReason blocked_reason{};
      std::string_view event;

      void validate() const;
    };

    template <>
    struct MessageSchema<ReportAgent>
        : Schema<
              Direction::client,
              ClientTag::report_agent,
              Field<&ReportAgent::request_id, NonzeroU64, "request_id">,
              Field<&ReportAgent::pane_id, NonzeroU64, "pane_id">,
              Field<&ReportAgent::pane_generation, u64, "pane_generation">,
              Field<&ReportAgent::provider, EnumByte<AgentProvider, max_agent_provider_index>, "provider">,
              Field<&ReportAgent::state, EnumByte<AgentReportState, std::to_underlying(AgentReportState::interrupted)>, "state">,
              Field<&ReportAgent::session, Text16<agent_report_session_bytes>, "session">,
              Field<&ReportAgent::session_file, Text16<agent_report_session_file_bytes>, "session_file">,
              Field<&ReportAgent::session_file_kind, EnumByte<AgentSessionFileKind, 3>, "session_file_kind">,
              Field<&ReportAgent::blocked_reason, EnumByte<AgentBlockedReason, 4>, "blocked_reason">,
              Field<&ReportAgent::event, DisplayText16<agent_report_event_bytes>, "event">> {};

    struct ReportAgentCommand {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      AgentCommandPhase phase{};
      std::string_view provider;
      std::string_view tool_call_id;
      std::string_view command;
      std::string_view cwd;
      std::string_view session;
      ds::Option<std::int32_t> exit_code;

      void validate() const;
    };

    template <>
    struct MessageSchema<ReportAgentCommand>
        : Schema<Direction::client, ClientTag::report_agent_command, Field<&ReportAgentCommand::request_id, NonzeroU64, "request_id">, Field<&ReportAgentCommand::pane_id, NonzeroU64, "pane_id">, Field<&ReportAgentCommand::pane_generation, u64, "pane_generation">, Field<&ReportAgentCommand::phase, EnumByte<AgentCommandPhase, 1>, "phase">, Field<&ReportAgentCommand::provider, Text16<agent_report_provider_bytes, false>, "provider">, Field<&ReportAgentCommand::tool_call_id, Text16<agent_report_tool_call_bytes>, "tool_call_id">, Field<&ReportAgentCommand::command, Text32<agent_report_command_bytes, false>, "command">, Field<&ReportAgentCommand::cwd, Text16<agent_report_path_bytes>, "cwd">, Field<&ReportAgentCommand::session, Text16<agent_report_session_bytes>, "session">, Field<&ReportAgentCommand::exit_code, OptionalValue<i32>, "exit_code">> {};

    struct ReportAgentTitle {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      AgentProvider provider{};
      std::string_view title;
    };

    template <>
    struct MessageSchema<ReportAgentTitle>
        : Schema<Direction::client, ClientTag::report_agent_title, Field<&ReportAgentTitle::request_id, NonzeroU64, "request_id">, Field<&ReportAgentTitle::pane_id, NonzeroU64, "pane_id">, Field<&ReportAgentTitle::pane_generation, u64, "pane_generation">, Field<&ReportAgentTitle::provider, EnumByte<AgentProvider, max_agent_provider_index>, "provider">, Field<&ReportAgentTitle::title, DisplayText16<agent_report_title_bytes>, "title">> {};

    struct InterruptAgent {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
    };

    template <>
    struct MessageSchema<InterruptAgent>
        : Schema<Direction::client, ClientTag::interrupt_agent, Field<&InterruptAgent::request_id, NonzeroU64, "request_id">, Field<&InterruptAgent::pane_id, NonzeroU64, "pane_id">, Field<&InterruptAgent::pane_generation, u64, "pane_generation">> {};

    struct ReportAgentProgress {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      AgentProvider provider{};
      std::string_view cwd;
      std::string_view work_tree_path;
      std::string_view work_tree_branch;
      std::string_view final_message;
      AgentPlanOp plan_op{};
      std::uint16_t plan_index{};
      AgentPlanStatus plan_status{};
      std::uint16_t plan_done{};
      std::uint16_t plan_total{};
      std::string_view plan_text;

      void validate() const;
    };

    template <>
    struct MessageSchema<ReportAgentProgress>
        : Schema<
              Direction::client,
              ClientTag::report_agent_progress,
              Field<&ReportAgentProgress::request_id, NonzeroU64, "request_id">,
              Field<&ReportAgentProgress::pane_id, NonzeroU64, "pane_id">,
              Field<&ReportAgentProgress::pane_generation, u64, "pane_generation">,
              Field<&ReportAgentProgress::provider, EnumByte<AgentProvider, max_agent_provider_index>, "provider">,
              Field<&ReportAgentProgress::cwd, Text16<agent_report_path_bytes>, "cwd">,
              Field<&ReportAgentProgress::work_tree_path, Text16<agent_report_path_bytes>, "work_tree_path">,
              Field<&ReportAgentProgress::work_tree_branch, DisplayText16<agent_report_branch_bytes>, "work_tree_branch">,
              Field<&ReportAgentProgress::final_message, MessageText16<agent_report_message_bytes>, "final_message">,
              Field<&ReportAgentProgress::plan_op, EnumByte<AgentPlanOp, 3>, "plan_op">,
              Field<&ReportAgentProgress::plan_index, u16, "plan_index">,
              Field<&ReportAgentProgress::plan_status, EnumByte<AgentPlanStatus, 3>, "plan_status">,
              Field<&ReportAgentProgress::plan_done, u16, "plan_done">,
              Field<&ReportAgentProgress::plan_total, u16, "plan_total">,
              Field<&ReportAgentProgress::plan_text, DisplayText16<agent_report_plan_bytes>, "plan_text">> {};

    struct AgentSnapshot {
      std::uint64_t revision{};
      std::span<const AgentSnapshotEntry> entries;
    };

    template <>
    struct MessageSchema<AgentSnapshot>
        : Schema<Direction::server, ServerTag::agent_snapshot, Field<&AgentSnapshot::revision, u64, "revision">, SpanCountField<&AgentSnapshot::entries, u16, ValueCodec<AgentSnapshotEntry>, max_agent_snapshot_entries, "entry_count", 0>, SpanItemsField<&AgentSnapshot::entries, ValueCodec<AgentSnapshotEntry>, "entries">> {
    };

    struct AgentSoundNotification {
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      AgentSound sound{};
    };

    template <>
    struct MessageSchema<AgentSoundNotification>
        : Schema<Direction::server, ServerTag::agent_sound, Field<&AgentSoundNotification::pane_id, NonzeroU64, "pane_id">, Field<&AgentSoundNotification::pane_generation, u64, "pane_generation">, Field<&AgentSoundNotification::sound, EnumByte<AgentSound, 1>, "sound">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
