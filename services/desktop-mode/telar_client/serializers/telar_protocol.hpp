#pragma once

#include "telar_frame.hpp"
#include "telar_messages.hpp"

namespace telar {

  enum class TabMoveDirection : Byte {
    previous = 0,
    next = 1,
  };

  enum class PaneDirection : Byte {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
  };

  enum class PaneFocusOutcome : Byte {
    focused = 0,
    no_neighbor = 1,
    source_not_focused = 2,
  };

  enum class ProxyScope : Byte {
    exact = 0,
    wildcard = 1,
  };

  enum class ExitKind : Byte {
    exited = 0,
    signaled = 1,
  };

  enum class FailureCode : std::uint16_t {
    pane_not_found = 1,
    invalid_request = 2,
    spawn_failed = 3,
    permission_denied = 4,
    resource_limit = 5,
    internal = 6,
    workspace_not_found = 7,
    tab_not_found = 8,
    agent_blocked = 9,
    pane_exited = 10,
    worktree_not_found = 11,
    pane_focused = 12,
    prompt_rate_limited = 13,
    agent_not_working = 14,
    interrupt_unsupported = 15,
    foreign_process = 16,
  };

  enum class AgentPlanOp : Byte {
    none = 0,
    add = 1,
    mark = 2,
    set = 3,
  };

  enum class AgentPlanStatus : Byte {
    pending = 0,
    in_progress = 1,
    completed = 2,
    deleted = 3,
  };

  enum class SuggestionStatus : Byte {
    ready = 0,
    unavailable = 1,
    timeout = 2,
    failed = 3,
  };

  enum class PaneTextSource : Byte {
    screen = 0,
    recent = 1,
  };

  enum class PaneTextMode : Byte {
    raw = 0,
    prompt = 1,
    raw_enter = 2,
  };

  enum class PaneLifecycle : Byte {
    running = 0,
    exited = 1,
  };

  enum class PathKindFilter : Byte {
    any = 0,
    files = 1,
    directories = 2,
  };

  enum class HistoryAuthorFilter : Byte {
    all = 0,
    human = 1,
    agent = 2,
  };

  enum class AgentSound : Byte {
    ready = 0,
    needs_input = 1,
  };

  enum class AgentReportState : Byte {
    working = 0,
    blocked = 1,
    ready = 2,
    exited = 3,
    settling = 4,
    continuing = 5,
    waiting = 6,
    idle = 7,
    released = 8,
  };

  enum class AgentSessionFileKind : Byte {
    claude_transcript = 0,
    codex_state = 1,
    cursor_meta = 2,
  };

  enum class AgentCommandPhase : Byte {
    started = 0,
    finished = 1,
  };

  enum class HistoryMatch : Byte {
    fts = 0,
    fuzzy = 1,
  };

  enum class PaneProgressState : Byte {
    remove = 0,
    set = 1,
    error = 2,
    indeterminate = 3,
    pause = 4,
  };

  enum class SnapshotPhase : Byte {
    begin = 0,
    end = 1,
  };

  enum class ExecutionAction : Byte {
    start = 0,
    status = 1,
    input = 2,
    eof = 3,
    cancel = 4,
    forget = 5,
    list = 6,
  };

  enum class ExecutionState : Byte {
    starting = 0,
    running = 1,
    exited = 2,
    failed = 3,
  };

  enum class EditorOutcome : Byte {
    unavailable = 0,
    opened = 1,
    failed = 2,
    missing = 3,
  };

  inline void validateAgentSession(std::string_view session, bool empty_allowed) {
    if (session.empty()) {
      if (!empty_allowed) {
        throw EncodingError{"Missing agent session"};
      }
      return;
    }
    if (session.size() > 64 || session.front() == '-') {
      throw EncodingError{"Invalid agent session"};
    }
    for (const auto character : session) {
      const auto byte = static_cast<Byte>(character);
      if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
            (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' ||
            byte == ':')) {
        throw EncodingError{"Invalid agent session"};
      }
    }
  }

  inline void validateWorkspaceClosure(const WorkspaceLocation &workspace, bool closed,
                                       std::optional<std::uint64_t> previous) {
    if (previous && (!closed || workspace.kind != WorkspaceLocation::Kind::workspace ||
                     *previous == workspace.id)) {
      throw EncodingError{"Invalid previous workspace"};
    }
  }

  inline void validateSharedImageName(std::string_view name) {
    if (name.size() < 2 || name.size() > 31 || name.front() != '/') {
      throw EncodingError{"Invalid shared image name"};
    }
    for (const auto byte : name.substr(1)) {
      if (!((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-')) {
        throw EncodingError{"Invalid shared image name"};
      }
    }
  }

  inline bool sameWorkspace(const WorkspaceLocation &left, const WorkspaceLocation &right) {
    return left.kind == right.kind && left.id == right.id;
  }

  inline bool sameTab(const TabLocation &left, const TabLocation &right) {
    return sameWorkspace(left.workspace, right.workspace) && left.tab_id == right.tab_id;
  }

  inline void validateLayoutCollection(std::optional<TabLocation> active,
                                       std::span<const ClientTabLayout> tabs) {
    std::size_t nodes = 0;
    bool active_found = !active;
    for (std::size_t i = 0; i < tabs.size(); ++i) {
      nodes += tabs[i].nodes.size();
      for (std::size_t j = 0; j < i; ++j) {
        if (sameTab(tabs[i].location, tabs[j].location) ||
            (tabs[i].workspace_active && tabs[j].workspace_active &&
             sameWorkspace(tabs[i].location.workspace, tabs[j].location.workspace))) {
          throw EncodingError{"Duplicate client layout location"};
        }
      }
      if (active && sameTab(*active, tabs[i].location) && tabs[i].workspace_active) {
        active_found = true;
      }
    }
    if (nodes > 511 || !active_found) {
      throw EncodingError{"Invalid active client layout"};
    }
  }

  struct ScopedHistoryValue {
    using value_type = HistoryScopeValue;
    static constexpr std::size_t min_width = 0;
    static std::size_t encodedSize(const value_type &value, HistoryScope scope) {
      return BodySchema<HistoryScopeValue>::encodedSize(value, scope);
    }
    static void encode(const value_type &value, std::span<Byte> &output, HistoryScope scope) {
      BodySchema<HistoryScopeValue>::encodeBody(value, output, scope);
    }
    static value_type decode(std::span<const Byte> &input, DecodeStorage &storage,
                             HistoryScope scope) {
      value_type value{};
      BodySchema<HistoryScopeValue>::decodeBody(input, value, storage, scope);
      return value;
    }
  };

  struct TargetLaunch {
    using value_type = std::optional<Launch>;
    static constexpr std::size_t min_width = 0;
    static std::size_t encodedSize(const value_type &value, const PaneTarget &target) {
      if ((target.kind == PaneTarget::Kind::default_target) != value.has_value()) {
        throw EncodingError{"Launch and pane target do not match"};
      }
      return value ? ValueCodec<Launch>::encodedSize(*value) : 0;
    }
    static void encode(const value_type &value, std::span<Byte> &output, const PaneTarget &target) {
      (void)encodedSize(value, target);
      if (value) {
        ValueCodec<Launch>::encode(*value, output);
      }
    }
    static value_type decode(std::span<const Byte> &input, DecodeStorage &storage,
                             const PaneTarget &target) {
      if (target.kind != PaneTarget::Kind::default_target) {
        return std::nullopt;
      }
      return ValueCodec<Launch>::decode(input, storage);
    }
  };

  struct ImportHistoryEntry {
    std::int64_t started_at_ms = 0;
    std::string_view command{};
  };
  struct PaneDescriptor {
    std::uint64_t pane_id = 0;
    PaneLifecycle lifecycle{};
    std::uint64_t pane_generation = 0;
  };
  struct PaneMatch {
    std::uint16_t x = 0;
    std::uint32_t y = 0;
    std::uint16_t len = 0;
  };
  struct HistoryStatsEntry {
    std::uint64_t count = 0;
    std::string_view command{};
  };

  template <>
  struct BodySchema<ImportHistoryEntry>
      : Serializer<Field<&ImportHistoryEntry::started_at_ms, i64, "started_at_ms">,
                   Field<&ImportHistoryEntry::command, Text16<65535, false>, "command">> {};
  template <>
  struct BodySchema<PaneDescriptor>
      : Serializer<Field<&PaneDescriptor::pane_id, NonzeroU64, "pane_id">,
                   Field<&PaneDescriptor::lifecycle, EnumByte<PaneLifecycle, 1>, "lifecycle">,
                   Field<&PaneDescriptor::pane_generation, u64, "pane_generation">> {};
  template <>
  struct BodySchema<PaneMatch>
      : Serializer<Field<&PaneMatch::x, u16, "x">, Field<&PaneMatch::y, u32, "y">,
                   Field<&PaneMatch::len, BoundedInteger<u16, 1>, "len">> {};
  template <>
  struct BodySchema<HistoryStatsEntry>
      : Serializer<Field<&HistoryStatsEntry::count, u64, "count">,
                   Field<&HistoryStatsEntry::command, Text16<65535, false>, "command">> {};

  struct OpenPane {
    std::uint64_t request_id{};
    PaneTarget target{};
    TerminalSize size{};
    std::optional<Launch> launch{};
  };

  template <>
  struct MessageSchema<OpenPane>
      : Schema<Direction::client, ClientTag::open_pane,
               Field<&OpenPane::request_id, NonzeroU64, "request_id">,
               Field<&OpenPane::target, ValueCodec<PaneTarget>, "target">,
               Field<&OpenPane::size, ValueCodec<TerminalSize>, "size">,
               ContextField<&OpenPane::launch, &OpenPane::target, TargetLaunch, "launch">> {};

  struct PaneInput {
    std::uint64_t pane_id{};
    std::span<const Byte> bytes{};
  };

  template <>
  struct MessageSchema<PaneInput> : Schema<Direction::client, ClientTag::pane_input,
                                           Field<&PaneInput::pane_id, NonzeroU64, "pane_id">,
                                           Field<&PaneInput::bytes, TailBytes<65536, 1>, "bytes">> {
  };

  struct PaneResize {
    std::uint64_t pane_id{};
    TerminalSize size{};
  };

  template <>
  struct MessageSchema<PaneResize>
      : Schema<Direction::client, ClientTag::pane_resize,
               Field<&PaneResize::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneResize::size, ValueCodec<TerminalSize>, "size">> {};

  struct FrameAck {
    std::uint64_t pane_id{};
    std::uint64_t frame_id{};
  };

  template <>
  struct MessageSchema<FrameAck> : Schema<Direction::client, ClientTag::frame_ack,
                                          Field<&FrameAck::pane_id, NonzeroU64, "pane_id">,
                                          Field<&FrameAck::frame_id, u64, "frame_id">> {};

  struct RequestSnapshot {
    std::uint64_t pane_id{};
    std::uint64_t known_frame_id{};
  };

  template <>
  struct MessageSchema<RequestSnapshot>
      : Schema<Direction::client, ClientTag::request_snapshot,
               Field<&RequestSnapshot::pane_id, NonzeroU64, "pane_id">,
               Field<&RequestSnapshot::known_frame_id, u64, "known_frame_id">> {};

  struct DetachPane {
    std::uint64_t pane_id{};
  };

  template <>
  struct MessageSchema<DetachPane> : Schema<Direction::client, ClientTag::detach_pane,
                                            Field<&DetachPane::pane_id, NonzeroU64, "pane_id">> {};

  struct RuntimeStop {};

  template <>
  struct MessageSchema<RuntimeStop> : Schema<Direction::client, ClientTag::runtime_stop> {};

  struct RequestTabSnapshot {
    std::uint64_t request_id{};
    TabLocation location{};
  };

  template <>
  struct MessageSchema<RequestTabSnapshot>
      : Schema<Direction::client, ClientTag::request_tab_snapshot,
               Field<&RequestTabSnapshot::request_id, NonzeroU64, "request_id">,
               Field<&RequestTabSnapshot::location, ValueCodec<TabLocation>, "location">> {};

  struct CreatePane {
    std::uint64_t request_id{};
    TabLocation location{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreatePane>
      : Schema<Direction::client, ClientTag::create_pane,
               Field<&CreatePane::request_id, NonzeroU64, "request_id">,
               Field<&CreatePane::location, ValueCodec<TabLocation>, "location">,
               Field<&CreatePane::size, ValueCodec<TerminalSize>, "size">,
               Field<&CreatePane::launch, ValueCodec<Launch>, "launch">> {};

  struct ClosePane {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
  };

  template <>
  struct MessageSchema<ClosePane> : Schema<Direction::client, ClientTag::close_pane,
                                           Field<&ClosePane::request_id, NonzeroU64, "request_id">,
                                           Field<&ClosePane::pane_id, NonzeroU64, "pane_id">> {};

  struct QueryHistory {
    std::uint64_t request_id{};
    std::string_view query{};
    HistoryScope scope{};
    HistoryScopeValue scope_value{};
    bool failed_only{};
    HistoryAuthorFilter author{};
    HistoryMatch match{};
    bool distinct{};
    std::uint16_t limit{};
    std::uint32_t offset{};
    std::uint64_t snapshot_id{};
    std::uint64_t entry_id{};
  };

  template <>
  struct MessageSchema<QueryHistory>
      : Schema<Direction::client, ClientTag::query_history,
               Field<&QueryHistory::request_id, NonzeroU64, "request_id">,
               Field<&QueryHistory::query, Text16<1024>, "query">,
               Field<&QueryHistory::scope, EnumByte<HistoryScope, 3>, "scope">,
               ContextField<&QueryHistory::scope_value, &QueryHistory::scope, ScopedHistoryValue,
                            "scope_value">,
               Field<&QueryHistory::failed_only, BoolByte, "failed_only">,
               Field<&QueryHistory::author, EnumByte<HistoryAuthorFilter, 2>, "author">,
               Field<&QueryHistory::match, EnumByte<HistoryMatch, 1>, "match">,
               Field<&QueryHistory::distinct, BoolByte, "distinct">,
               Field<&QueryHistory::limit, BoundedInteger<u16, 1, 1000>, "limit">,
               Field<&QueryHistory::offset, u32, "offset">,
               Field<&QueryHistory::snapshot_id, u64, "snapshot_id">,
               Field<&QueryHistory::entry_id, u64, "entry_id">> {};

  struct RequestWorkspaceSnapshot {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
  };

  template <>
  struct MessageSchema<RequestWorkspaceSnapshot>
      : Schema<Direction::client, ClientTag::request_workspace_snapshot,
               Field<&RequestWorkspaceSnapshot::request_id, NonzeroU64, "request_id">,
               Field<&RequestWorkspaceSnapshot::workspace, ValueCodec<WorkspaceLocation>,
                     "workspace">> {};

  struct CreateTab {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view label{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreateTab>
      : Schema<Direction::client, ClientTag::create_tab,
               Field<&CreateTab::request_id, NonzeroU64, "request_id">,
               Field<&CreateTab::workspace, ValueCodec<WorkspaceLocation>, "workspace">,
               Field<&CreateTab::label, DisplayText16<128>, "label">,
               Field<&CreateTab::size, ValueCodec<TerminalSize>, "size">,
               Field<&CreateTab::launch, ValueCodec<Launch>, "launch">> {};

  struct RenameTab {
    std::uint64_t request_id{};
    TabLocation location{};
    std::string_view label{};
  };

  template <>
  struct MessageSchema<RenameTab>
      : Schema<Direction::client, ClientTag::rename_tab,
               Field<&RenameTab::request_id, NonzeroU64, "request_id">,
               Field<&RenameTab::location, ValueCodec<TabLocation>, "location">,
               Field<&RenameTab::label, DisplayText16<128, false>, "label">> {};

  struct CloseTab {
    std::uint64_t request_id{};
    TabLocation location{};
  };

  template <>
  struct MessageSchema<CloseTab>
      : Schema<Direction::client, ClientTag::close_tab,
               Field<&CloseTab::request_id, NonzeroU64, "request_id">,
               Field<&CloseTab::location, ValueCodec<TabLocation>, "location">> {};

  struct MoveTab {
    std::uint64_t request_id{};
    TabLocation location{};
    TabMoveDirection direction{};
    std::optional<std::uint64_t> relative_to{};
  };

  template <>
  struct MessageSchema<MoveTab>
      : Schema<Direction::client, ClientTag::move_tab,
               Field<&MoveTab::request_id, NonzeroU64, "request_id">,
               Field<&MoveTab::location, ValueCodec<TabLocation>, "location">,
               Field<&MoveTab::direction, EnumByte<TabMoveDirection, 1>, "direction">,
               Field<&MoveTab::relative_to, OptionalValue<NonzeroU64>, "relative_to">> {};

  struct RequestGraphicsSnapshot {
    std::uint64_t pane_id{};
  };

  template <>
  struct MessageSchema<RequestGraphicsSnapshot>
      : Schema<Direction::client, ClientTag::request_graphics_snapshot,
               Field<&RequestGraphicsSnapshot::pane_id, NonzeroU64, "pane_id">> {};

  struct GraphicsCredit {
    std::uint64_t pane_id{};
    std::uint64_t bytes{};
  };

  template <>
  struct MessageSchema<GraphicsCredit>
      : Schema<Direction::client, ClientTag::graphics_credit,
               Field<&GraphicsCredit::pane_id, NonzeroU64, "pane_id">,
               Field<&GraphicsCredit::bytes, u64, "bytes">> {};

  struct ConfigureGraphics {
    bool shared{};
  };

  template <>
  struct MessageSchema<ConfigureGraphics>
      : Schema<Direction::client, ClientTag::configure_graphics,
               Field<&ConfigureGraphics::shared, BoolByte, "shared">> {};

  struct CreateWorkspace {
    std::uint64_t request_id{};
    TerminalSize size{};
    std::string_view name{};
    bool create_cwd{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreateWorkspace>
      : Schema<Direction::client, ClientTag::create_workspace,
               Field<&CreateWorkspace::request_id, NonzeroU64, "request_id">,
               Field<&CreateWorkspace::size, ValueCodec<TerminalSize>, "size">,
               Field<&CreateWorkspace::name, DisplayText16<128, false>, "name">,
               Field<&CreateWorkspace::create_cwd, BoolByte, "create_cwd">,
               Field<&CreateWorkspace::launch, ValueCodec<Launch>, "launch">> {};

  struct RenameWorkspace {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view name{};
  };

  template <>
  struct MessageSchema<RenameWorkspace>
      : Schema<Direction::client, ClientTag::rename_workspace,
               Field<&RenameWorkspace::request_id, NonzeroU64, "request_id">,
               Field<&RenameWorkspace::workspace, ValueCodec<WorkspaceLocation>, "workspace">,
               Field<&RenameWorkspace::name, DisplayText16<128, false>, "name">> {};

  struct SetPaneViewport {
    std::uint64_t pane_id{};
    std::uint32_t offset{};
  };

  template <>
  struct MessageSchema<SetPaneViewport>
      : Schema<Direction::client, ClientTag::set_pane_viewport,
               Field<&SetPaneViewport::pane_id, NonzeroU64, "pane_id">,
               Field<&SetPaneViewport::offset, u32, "offset">> {};

  struct CopySelection {
    std::uint64_t pane_id{};
    std::uint16_t start_x{};
    std::uint32_t start_y{};
    std::uint16_t end_x{};
    std::uint32_t end_y{};
    bool linewise{};
  };

  template <>
  struct MessageSchema<CopySelection>
      : Schema<Direction::client, ClientTag::copy_selection,
               Field<&CopySelection::pane_id, NonzeroU64, "pane_id">,
               Field<&CopySelection::start_x, u16, "start_x">,
               Field<&CopySelection::start_y, u32, "start_y">,
               Field<&CopySelection::end_x, u16, "end_x">,
               Field<&CopySelection::end_y, u32, "end_y">,
               Field<&CopySelection::linewise, BoolByte, "linewise">> {};

  struct ShowNotification {
    std::uint64_t request_id{};
    NotificationBody notification{};
  };

  template <>
  struct MessageSchema<ShowNotification>
      : Schema<
            Direction::client, ClientTag::show_notification,
            Field<&ShowNotification::request_id, NonzeroU64, "request_id">,
            Field<&ShowNotification::notification, ValueCodec<NotificationBody>, "notification">> {
  };

  struct UpdateClientLayout {
    bool sidebar_visible{};
    std::uint16_t sidebar_width{};
    bool workspace_list_collapsed{};
    TabLocation active_tab{};
    std::span<const ClientTabLayout> tabs{};

    void validate() const {
      if (sidebar_width == 0) {
        throw EncodingError{"Invalid sidebar width"};
      }
      validateLayoutCollection(active_tab, tabs);
    }
  };

  template <>
  struct MessageSchema<UpdateClientLayout>
      : Schema<Direction::client, ClientTag::update_client_layout,
               Field<&UpdateClientLayout::sidebar_visible, BoolByte, "sidebar_visible">,
               Field<&UpdateClientLayout::sidebar_width, u16, "sidebar_width">,
               Field<&UpdateClientLayout::workspace_list_collapsed, BoolByte,
                     "workspace_list_collapsed">,
               Field<&UpdateClientLayout::active_tab, ValueCodec<TabLocation>, "active_tab">,
               SpanCountField<&UpdateClientLayout::tabs, u16, ValueCodec<ClientTabLayout>, 256,
                              "tab_count", 1>,
               SpanItemsField<&UpdateClientLayout::tabs, ValueCodec<ClientTabLayout>, "tabs">> {};

  struct AcknowledgeAgent {
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<AcknowledgeAgent>
      : Schema<Direction::client, ClientTag::acknowledge_agent,
               Field<&AcknowledgeAgent::pane_id, NonzeroU64, "pane_id">,
               Field<&AcknowledgeAgent::pane_generation, u64, "pane_generation">> {};

  struct QueryAgents {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<QueryAgents>
      : Schema<Direction::client, ClientTag::query_agents,
               Field<&QueryAgents::request_id, NonzeroU64, "request_id">> {};

  struct ReadPane {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    std::uint16_t rows{};
    PaneTextSource source{};
  };

  template <>
  struct MessageSchema<ReadPane>
      : Schema<Direction::client, ClientTag::read_pane,
               Field<&ReadPane::request_id, NonzeroU64, "request_id">,
               Field<&ReadPane::pane_id, NonzeroU64, "pane_id">,
               Field<&ReadPane::pane_generation, u64, "pane_generation">,
               Field<&ReadPane::rows, BoundedInteger<u16, 1, 2000>, "rows">,
               Field<&ReadPane::source, EnumByte<PaneTextSource, 1>, "source">> {};

  struct SendPaneText {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneTextMode mode{};
    std::string_view text{};
    std::optional<std::uint64_t> sender{};

    void validate() const {
      if (text.empty() && mode != PaneTextMode::raw_enter) {
        throw EncodingError{"Empty pane text"};
      }
    }
  };

  template <>
  struct MessageSchema<SendPaneText>
      : Schema<Direction::client, ClientTag::send_pane_text,
               Field<&SendPaneText::request_id, NonzeroU64, "request_id">,
               Field<&SendPaneText::pane_id, NonzeroU64, "pane_id">,
               Field<&SendPaneText::pane_generation, u64, "pane_generation">,
               Field<&SendPaneText::mode, EnumByte<PaneTextMode, 2>, "mode">,
               Field<&SendPaneText::text, Text32<65536>, "text">,
               Field<&SendPaneText::sender, OptionalValue<NonzeroU64>, "sender">> {};

  struct ReportAgentSession {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    std::string_view session{};

    void validate() const { validateAgentSession(session, false); }
  };

  template <>
  struct MessageSchema<ReportAgentSession>
      : Schema<Direction::client, ClientTag::report_agent_session,
               Field<&ReportAgentSession::request_id, NonzeroU64, "request_id">,
               Field<&ReportAgentSession::pane_id, NonzeroU64, "pane_id">,
               Field<&ReportAgentSession::pane_generation, u64, "pane_generation">,
               Field<&ReportAgentSession::session, Text16<64>, "session">> {};

  struct ReportAgent {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    AgentProvider provider{};
    AgentReportState state{};
    std::string_view session{};
    std::string_view session_file{};
    AgentSessionFileKind session_file_kind{};
    AgentBlockedReason blocked_reason{};
    std::string_view event{};

    void validate() const {
      validateAgentSession(session, true);
      if (state != AgentReportState::blocked && blocked_reason != AgentBlockedReason::none) {
        throw EncodingError{"Unexpected blocked reason"};
      }
    }
  };

  template <>
  struct MessageSchema<ReportAgent>
      : Schema<
            Direction::client, ClientTag::report_agent,
            Field<&ReportAgent::request_id, NonzeroU64, "request_id">,
            Field<&ReportAgent::pane_id, NonzeroU64, "pane_id">,
            Field<&ReportAgent::pane_generation, u64, "pane_generation">,
            Field<&ReportAgent::provider, EnumByte<AgentProvider, 32>, "provider">,
            Field<&ReportAgent::state, EnumByte<AgentReportState, 8>, "state">,
            Field<&ReportAgent::session, Text16<64>, "session">,
            Field<&ReportAgent::session_file, Text16<1024>, "session_file">,
            Field<&ReportAgent::session_file_kind, EnumByte<AgentSessionFileKind, 2>,
                  "session_file_kind">,
            Field<&ReportAgent::blocked_reason, EnumByte<AgentBlockedReason, 4>, "blocked_reason">,
            Field<&ReportAgent::event, DisplayText16<96>, "event">> {};

  struct SearchPane {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::string_view needle{};
  };

  template <>
  struct MessageSchema<SearchPane>
      : Schema<Direction::client, ClientTag::search_pane,
               Field<&SearchPane::request_id, NonzeroU64, "request_id">,
               Field<&SearchPane::pane_id, NonzeroU64, "pane_id">,
               Field<&SearchPane::needle, Text16<128, false>, "needle">> {};

  struct ImportHistory {
    std::uint64_t request_id{};
    std::string_view source{};
    std::uint64_t base_sequence{};
    std::span<const ImportHistoryEntry> entries{};
  };

  template <>
  struct MessageSchema<ImportHistory>
      : Schema<Direction::client, ClientTag::import_history,
               Field<&ImportHistory::request_id, NonzeroU64, "request_id">,
               Field<&ImportHistory::source, Text16<256, false>, "source">,
               Field<&ImportHistory::base_sequence, u64, "base_sequence">,
               SpanCountField<&ImportHistory::entries, u16, ValueCodec<ImportHistoryEntry>, 64,
                              "entry_count", 1>,
               SpanItemsField<&ImportHistory::entries, ValueCodec<ImportHistoryEntry>, "entries">> {
  };

  struct DeleteHistory {
    std::uint64_t request_id{};
    std::uint64_t id{};
  };

  template <>
  struct MessageSchema<DeleteHistory>
      : Schema<Direction::client, ClientTag::delete_history,
               Field<&DeleteHistory::request_id, NonzeroU64, "request_id">,
               Field<&DeleteHistory::id, NonzeroU64, "id">> {};

  struct PruneHistory {
    std::uint64_t request_id{};
    HistoryScope scope{};
    HistoryScopeValue scope_value{};
    std::int64_t before_ms{};
    bool failed_only{};
    std::string_view match{};
  };

  template <>
  struct MessageSchema<PruneHistory>
      : Schema<Direction::client, ClientTag::prune_history,
               Field<&PruneHistory::request_id, NonzeroU64, "request_id">,
               Field<&PruneHistory::scope, EnumByte<HistoryScope, 3>, "scope">,
               ContextField<&PruneHistory::scope_value, &PruneHistory::scope, ScopedHistoryValue,
                            "scope_value">,
               Field<&PruneHistory::before_ms, i64, "before_ms">,
               Field<&PruneHistory::failed_only, BoolByte, "failed_only">,
               Field<&PruneHistory::match, Text16<1024>, "match">> {};

  struct ReadHistoryOutput {
    std::uint64_t request_id{};
    std::uint64_t id{};
  };

  template <>
  struct MessageSchema<ReadHistoryOutput>
      : Schema<Direction::client, ClientTag::read_history_output,
               Field<&ReadHistoryOutput::request_id, NonzeroU64, "request_id">,
               Field<&ReadHistoryOutput::id, NonzeroU64, "id">> {};

  struct HistoryStatsQuery {
    std::uint64_t request_id{};
    HistoryScope scope{};
    HistoryScopeValue scope_value{};
    std::int64_t since_ms{};
  };

  template <>
  struct MessageSchema<HistoryStatsQuery>
      : Schema<Direction::client, ClientTag::history_stats,
               Field<&HistoryStatsQuery::request_id, NonzeroU64, "request_id">,
               Field<&HistoryStatsQuery::scope, EnumByte<HistoryScope, 3>, "scope">,
               ContextField<&HistoryStatsQuery::scope_value, &HistoryStatsQuery::scope,
                            ScopedHistoryValue, "scope_value">,
               Field<&HistoryStatsQuery::since_ms, i64, "since_ms">> {};

  struct RequestPaneFocus {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneDirection direction{};

    void validate() const {
      if (pane_generation == 0) {
        throw EncodingError{"Invalid pane generation"};
      }
    }
  };

  template <>
  struct MessageSchema<RequestPaneFocus>
      : Schema<Direction::client, ClientTag::request_pane_focus,
               Field<&RequestPaneFocus::request_id, NonzeroU64, "request_id">,
               Field<&RequestPaneFocus::pane_id, NonzeroU64, "pane_id">,
               Field<&RequestPaneFocus::pane_generation, u64, "pane_generation">,
               Field<&RequestPaneFocus::direction, EnumByte<PaneDirection, 3>, "direction">> {};

  struct CompletePaneFocus {
    ClientRoute requester{};
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneFocusOutcome outcome{};
    std::uint64_t focused_pane_id{};

    void validate() const {
      if (pane_generation == 0 || (outcome == PaneFocusOutcome::focused && focused_pane_id == 0)) {
        throw EncodingError{"Invalid focus completion"};
      }
    }
  };

  template <>
  struct MessageSchema<CompletePaneFocus>
      : Schema<Direction::client, ClientTag::complete_pane_focus,
               Field<&CompletePaneFocus::requester, ValueCodec<ClientRoute>, "requester">,
               Field<&CompletePaneFocus::request_id, NonzeroU64, "request_id">,
               Field<&CompletePaneFocus::pane_id, NonzeroU64, "pane_id">,
               Field<&CompletePaneFocus::pane_generation, u64, "pane_generation">,
               Field<&CompletePaneFocus::outcome, EnumByte<PaneFocusOutcome, 2>, "outcome">,
               Field<&CompletePaneFocus::focused_pane_id, u64, "focused_pane_id">> {};

  struct SuggestCommand {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::string_view text{};
  };

  template <>
  struct MessageSchema<SuggestCommand>
      : Schema<Direction::client, ClientTag::suggest_command,
               Field<&SuggestCommand::request_id, NonzeroU64, "request_id">,
               Field<&SuggestCommand::pane_id, NonzeroU64, "pane_id">,
               Field<&SuggestCommand::text, Text16<512, false>, "text">> {};

  struct ReportAgentCommand {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    AgentCommandPhase phase{};
    std::string_view provider{};
    std::string_view tool_call_id{};
    std::string_view command{};
    std::string_view cwd{};
    std::string_view session{};
    std::optional<std::int32_t> exit_code{};

    void validate() const {
      validateAgentSession(session, true);
      if (phase == AgentCommandPhase::started && exit_code) {
        throw EncodingError{"Unexpected command exit code"};
      }
    }
  };

  template <>
  struct MessageSchema<ReportAgentCommand>
      : Schema<Direction::client, ClientTag::report_agent_command,
               Field<&ReportAgentCommand::request_id, NonzeroU64, "request_id">,
               Field<&ReportAgentCommand::pane_id, NonzeroU64, "pane_id">,
               Field<&ReportAgentCommand::pane_generation, u64, "pane_generation">,
               Field<&ReportAgentCommand::phase, EnumByte<AgentCommandPhase, 1>, "phase">,
               Field<&ReportAgentCommand::provider, Text16<64, false>, "provider">,
               Field<&ReportAgentCommand::tool_call_id, Text16<256>, "tool_call_id">,
               Field<&ReportAgentCommand::command, Text32<65536, false>, "command">,
               Field<&ReportAgentCommand::cwd, Text16<4096>, "cwd">,
               Field<&ReportAgentCommand::session, Text16<64>, "session">,
               Field<&ReportAgentCommand::exit_code, OptionalValue<i32>, "exit_code">> {};

  struct ReportAgentTitle {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    AgentProvider provider{};
    std::string_view title{};
  };

  template <>
  struct MessageSchema<ReportAgentTitle>
      : Schema<Direction::client, ClientTag::report_agent_title,
               Field<&ReportAgentTitle::request_id, NonzeroU64, "request_id">,
               Field<&ReportAgentTitle::pane_id, NonzeroU64, "pane_id">,
               Field<&ReportAgentTitle::pane_generation, u64, "pane_generation">,
               Field<&ReportAgentTitle::provider, EnumByte<AgentProvider, 32>, "provider">,
               Field<&ReportAgentTitle::title, DisplayText16<96>, "title">> {};

  struct ConfigureTerminalColors {
    std::optional<std::array<Byte, 3>> foreground{};
    std::optional<std::array<Byte, 3>> background{};
    std::optional<std::array<Byte, 48>> palette{};
  };

  template <>
  struct MessageSchema<ConfigureTerminalColors>
      : Schema<
            Direction::client, ClientTag::configure_terminal_colors,
            Field<&ConfigureTerminalColors::foreground, OptionalValue<FixedBytes<3>>, "foreground">,
            Field<&ConfigureTerminalColors::background, OptionalValue<FixedBytes<3>>, "background">,
            Field<&ConfigureTerminalColors::palette, OptionalValue<FixedBytes<48>>, "palette">> {};

  struct QueryClients {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<QueryClients>
      : Schema<Direction::client, ClientTag::query_clients,
               Field<&QueryClients::request_id, NonzeroU64, "request_id">> {};

  struct DetachClient {
    std::uint64_t request_id{};
    std::uint64_t client_id{};
    std::uint64_t client_generation{};
  };

  template <>
  struct MessageSchema<DetachClient>
      : Schema<Direction::client, ClientTag::detach_client,
               Field<&DetachClient::request_id, NonzeroU64, "request_id">,
               Field<&DetachClient::client_id, NonzeroU64, "client_id">,
               Field<&DetachClient::client_generation, NonzeroU64, "client_generation">> {};

  struct RequestClientCommand : ClientCommand {};

  template <>
  struct MessageSchema<RequestClientCommand>
      : MessageLayout<Direction::client, ClientTag::request_client_command,
                      BodySchema<ClientCommand>> {};

  struct CompleteClientCommand : ClientCommand {};

  template <>
  struct MessageSchema<CompleteClientCommand>
      : MessageLayout<Direction::client, ClientTag::complete_client_command,
                      BodySchema<ClientCommand>> {};

  struct OpenEditor {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    std::string_view editor{};
    std::string_view path{};
    std::uint32_t line{};
    std::uint32_t column{};

    void validate() const {
      if (pane_generation == 0 || editor.empty() || editor.front() == '-' || path.empty() ||
          path.front() != '/' || (column != 0 && line == 0)) {
        throw EncodingError{"Invalid editor target"};
      }
    }
  };

  template <>
  struct MessageSchema<OpenEditor>
      : Schema<Direction::client, ClientTag::open_editor,
               Field<&OpenEditor::request_id, NonzeroU64, "request_id">,
               Field<&OpenEditor::pane_id, NonzeroU64, "pane_id">,
               Field<&OpenEditor::pane_generation, u64, "pane_generation">,
               Field<&OpenEditor::editor, DisplayText16<4096, false>, "editor">,
               Field<&OpenEditor::path, DisplayText16<4096, false>, "path">,
               Field<&OpenEditor::line, u32, "line">, Field<&OpenEditor::column, u32, "column">> {};

  struct FindPaths {
    std::uint64_t request_id{};
    std::string_view root{};
    std::string_view query{};
    PathKindFilter kind{};
    std::uint16_t limit{};
    bool refresh{};

    void validate() const {
      if (root.empty() || root.front() != '/') {
        throw EncodingError{"Invalid path root"};
      }
    }
  };

  template <>
  struct MessageSchema<FindPaths>
      : Schema<Direction::client, ClientTag::find_paths,
               Field<&FindPaths::request_id, NonzeroU64, "request_id">,
               Field<&FindPaths::root, Text16<4096, false>, "root">,
               Field<&FindPaths::query, SizedText<u16, 64, true, TextRule::utf8_no_nul>, "query">,
               Field<&FindPaths::kind, EnumByte<PathKindFilter, 2>, "kind">,
               Field<&FindPaths::limit, BoundedInteger<u16, 1, 50>, "limit">,
               Field<&FindPaths::refresh, BoolByte, "refresh">> {};

  struct RegisterWorktree {
    std::uint64_t request_id{};
    std::uint64_t source{};
    std::optional<std::uint64_t> created_by{};
    WorktreeOrigin origin{};
    std::string_view path{};
    std::string_view branch{};
    std::string_view base{};
    std::string_view title{};
    std::string_view brief{};
    std::string_view dispatched_from{};
    std::optional<CoordinatorReference> coordinator{};

    void validate() const {
      if (path.empty() || path.front() != '/') {
        throw EncodingError{"Invalid worktree path"};
      }
    }
  };

  template <>
  struct MessageSchema<RegisterWorktree>
      : Schema<Direction::client, ClientTag::register_worktree,
               Field<&RegisterWorktree::request_id, NonzeroU64, "request_id">,
               Field<&RegisterWorktree::source, NonzeroU64, "source">,
               Field<&RegisterWorktree::created_by, OptionalValue<NonzeroU64>, "created_by">,
               Field<&RegisterWorktree::origin, EnumByte<WorktreeOrigin, 1>, "origin">,
               Field<&RegisterWorktree::path, Text16<4096, false>, "path">,
               Field<&RegisterWorktree::branch, DisplayText16<200, false>, "branch">,
               Field<&RegisterWorktree::base, DisplayText16<200>, "base">,
               Field<&RegisterWorktree::title, DisplayText16<96>, "title">,
               Field<&RegisterWorktree::brief, MessageText16<512>, "brief">,
               Field<&RegisterWorktree::dispatched_from, DisplayText16<32>, "dispatched_from">,
               Field<&RegisterWorktree::coordinator,
                     OptionalValue<ValueCodec<CoordinatorReference>>, "coordinator">> {};

  struct LaunchWorktree {
    std::uint64_t request_id{};
    std::uint64_t worktree{};
    std::string_view label{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<LaunchWorktree>
      : Schema<Direction::client, ClientTag::launch_worktree,
               Field<&LaunchWorktree::request_id, NonzeroU64, "request_id">,
               Field<&LaunchWorktree::worktree, NonzeroU64, "worktree">,
               Field<&LaunchWorktree::label, DisplayText16<128>, "label">,
               Field<&LaunchWorktree::size, ValueCodec<TerminalSize>, "size">,
               Field<&LaunchWorktree::launch, ValueCodec<Launch>, "launch">> {};

  struct ForgetWorktree {
    std::uint64_t request_id{};
    std::uint64_t worktree{};
  };

  template <>
  struct MessageSchema<ForgetWorktree>
      : Schema<Direction::client, ClientTag::forget_worktree,
               Field<&ForgetWorktree::request_id, NonzeroU64, "request_id">,
               Field<&ForgetWorktree::worktree, NonzeroU64, "worktree">> {};

  struct InterruptAgent {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<InterruptAgent>
      : Schema<Direction::client, ClientTag::interrupt_agent,
               Field<&InterruptAgent::request_id, NonzeroU64, "request_id">,
               Field<&InterruptAgent::pane_id, NonzeroU64, "pane_id">,
               Field<&InterruptAgent::pane_generation, u64, "pane_generation">> {};

  struct ReportAgentProgress {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    AgentProvider provider{};
    std::string_view cwd{};
    std::string_view work_tree_path{};
    std::string_view work_tree_branch{};
    std::string_view final_message{};
    AgentPlanOp plan_op{};
    std::uint16_t plan_index{};
    AgentPlanStatus plan_status{};
    std::uint16_t plan_done{};
    std::uint16_t plan_total{};
    std::string_view plan_text{};

    void validate() const {
      if (plan_done > plan_total) {
        throw EncodingError{"Invalid agent plan counts"};
      }
    }
  };

  template <>
  struct MessageSchema<ReportAgentProgress>
      : Schema<
            Direction::client, ClientTag::report_agent_progress,
            Field<&ReportAgentProgress::request_id, NonzeroU64, "request_id">,
            Field<&ReportAgentProgress::pane_id, NonzeroU64, "pane_id">,
            Field<&ReportAgentProgress::pane_generation, u64, "pane_generation">,
            Field<&ReportAgentProgress::provider, EnumByte<AgentProvider, 32>, "provider">,
            Field<&ReportAgentProgress::cwd, Text16<4096>, "cwd">,
            Field<&ReportAgentProgress::work_tree_path, Text16<4096>, "work_tree_path">,
            Field<&ReportAgentProgress::work_tree_branch, DisplayText16<200>, "work_tree_branch">,
            Field<&ReportAgentProgress::final_message, MessageText16<2048>, "final_message">,
            Field<&ReportAgentProgress::plan_op, EnumByte<AgentPlanOp, 3>, "plan_op">,
            Field<&ReportAgentProgress::plan_index, u16, "plan_index">,
            Field<&ReportAgentProgress::plan_status, EnumByte<AgentPlanStatus, 3>, "plan_status">,
            Field<&ReportAgentProgress::plan_done, u16, "plan_done">,
            Field<&ReportAgentProgress::plan_total, u16, "plan_total">,
            Field<&ReportAgentProgress::plan_text, DisplayText16<96>, "plan_text">> {};

  struct LaunchTab {
    std::uint64_t request_id{};
    std::uint64_t workspace{};
    std::string_view label{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<LaunchTab>
      : Schema<Direction::client, ClientTag::launch_tab,
               Field<&LaunchTab::request_id, NonzeroU64, "request_id">,
               Field<&LaunchTab::workspace, NonzeroU64, "workspace">,
               Field<&LaunchTab::label, DisplayText16<128>, "label">,
               Field<&LaunchTab::size, ValueCodec<TerminalSize>, "size">,
               Field<&LaunchTab::launch, ValueCodec<Launch>, "launch">> {};

  struct VerifyPaneDescent {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<VerifyPaneDescent>
      : Schema<Direction::client, ClientTag::verify_pane_descent,
               Field<&VerifyPaneDescent::request_id, NonzeroU64, "request_id">,
               Field<&VerifyPaneDescent::pane_id, NonzeroU64, "pane_id">,
               Field<&VerifyPaneDescent::pane_generation, u64, "pane_generation">> {};

  struct ReportLimit {
    LimitReach reach{};
    std::uint32_t hits{};
  };

  template <>
  struct MessageSchema<ReportLimit>
      : Schema<Direction::client, ClientTag::report_limit,
               Field<&ReportLimit::reach, ValueCodec<LimitReach>, "reach">,
               Field<&ReportLimit::hits, BoundedInteger<u32, 1>, "hits">> {};

  struct QueryLimits {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<QueryLimits>
      : Schema<Direction::client, ClientTag::query_limits,
               Field<&QueryLimits::request_id, NonzeroU64, "request_id">> {};

  struct ConfigureFrameInterval {
    std::uint64_t interval_ns{};
  };

  template <>
  struct MessageSchema<ConfigureFrameInterval>
      : Schema<Direction::client, ClientTag::configure_frame_interval,
               Field<&ConfigureFrameInterval::interval_ns,
                     BoundedInteger<u64, 1000000000 / 240, 1000000000 / 30>, "interval_ns">> {};

  struct ExecutionRequest {
    std::uint64_t request_id{};
    ExecutionAction action{};
    std::uint64_t execution_id{};
    std::uint64_t workspace_id{};
    std::uint64_t stdout_offset{};
    std::uint64_t stderr_offset{};
    std::uint64_t input_offset{};
    bool stdin_open{};
    std::string_view cwd{};
    std::span<const std::string_view> arguments{};
    std::span<const Byte> bytes{};

    void validate() const {
      if ((execution_id == 0 && action != ExecutionAction::list) ||
          (!cwd.empty() && cwd.front() != '/')) {
        throw EncodingError{"Invalid execution request"};
      }
      if (action == ExecutionAction::start && (arguments.empty() || arguments.front().empty())) {
        throw EncodingError{"Missing execution arguments"};
      }
      std::size_t total = 0;
      for (const auto argument : arguments) {
        total = checkedWireSize(total, argument.size());
      }
      if (total > 32768) {
        throw EncodingError{"Execution arguments too large"};
      }
    }
  };

  template <>
  struct MessageSchema<ExecutionRequest>
      : Schema<Direction::client, ClientTag::execution_request,
               Field<&ExecutionRequest::request_id, NonzeroU64, "request_id">,
               Field<&ExecutionRequest::action, EnumByte<ExecutionAction, 6>, "action">,
               Field<&ExecutionRequest::execution_id, u64, "execution_id">,
               Field<&ExecutionRequest::workspace_id, u64, "workspace_id">,
               Field<&ExecutionRequest::stdout_offset, u64, "stdout_offset">,
               Field<&ExecutionRequest::stderr_offset, u64, "stderr_offset">,
               Field<&ExecutionRequest::input_offset, u64, "input_offset">,
               Field<&ExecutionRequest::stdin_open, BoolByte, "stdin_open">,
               Field<&ExecutionRequest::cwd, Text16<4096>, "cwd">,
               SpanCountField<&ExecutionRequest::arguments, u8, Text16<32768>, 64, "argument_count",
                              0>,
               SpanItemsField<&ExecutionRequest::arguments, Text16<32768>, "arguments">,
               Field<&ExecutionRequest::bytes, SizedBytes<u16, 4096>, "bytes">> {};

  struct PaneOpened {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    TabLocation location{};
    bool created{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<PaneOpened>
      : Schema<Direction::server, ServerTag::pane_opened,
               Field<&PaneOpened::request_id, NonzeroU64, "request_id">,
               Field<&PaneOpened::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneOpened::location, ValueCodec<TabLocation>, "location">,
               Field<&PaneOpened::created, BoolByte, "created">,
               Field<&PaneOpened::pane_generation, u64, "pane_generation">> {};

  struct PaneExited {
    std::uint64_t pane_id{};
    ExitKind kind{};
    std::uint32_t value{};
  };

  template <>
  struct MessageSchema<PaneExited> : Schema<Direction::server, ServerTag::pane_exited,
                                            Field<&PaneExited::pane_id, NonzeroU64, "pane_id">,
                                            Field<&PaneExited::kind, EnumByte<ExitKind, 1>, "kind">,
                                            Field<&PaneExited::value, u32, "value">> {};

  struct RequestFailed {
    std::uint64_t request_id{};
    FailureCode code{};
    std::string_view message{};
  };

  template <>
  struct MessageSchema<RequestFailed>
      : Schema<Direction::server, ServerTag::request_failed,
               Field<&RequestFailed::request_id, u64, "request_id">,
               Field<&RequestFailed::code, EnumInteger<FailureCode, u16, 1, 16>, "code">,
               Field<&RequestFailed::message, Utf8Tail<1024>, "message">> {};

  struct RuntimeStopping {};

  template <>
  struct MessageSchema<RuntimeStopping> : Schema<Direction::server, ServerTag::runtime_stopping> {};

  struct TabSnapshot {
    std::uint64_t request_id{};
    TabLocation location{};
    std::span<const PaneDescriptor> panes{};

    void validate() const {
      for (std::size_t i = 0; i < panes.size(); ++i) {
        for (std::size_t j = 0; j < i; ++j) {
          if (panes[i].pane_id == panes[j].pane_id) {
            throw EncodingError{"Duplicate pane identity"};
          }
        }
      }
    }
  };

  template <>
  struct MessageSchema<TabSnapshot>
      : Schema<Direction::server, ServerTag::tab_snapshot,
               Field<&TabSnapshot::request_id, NonzeroU64, "request_id">,
               Field<&TabSnapshot::location, ValueCodec<TabLocation>, "location">,
               SpanCountField<&TabSnapshot::panes, u16, ValueCodec<PaneDescriptor>, 64,
                              "pane_count", 0>,
               SpanItemsField<&TabSnapshot::panes, ValueCodec<PaneDescriptor>, "panes">> {};

  struct HistoryResults {
    std::uint64_t request_id{};
    std::uint64_t snapshot_id{};
    bool has_more{};
    std::span<const HistoryEntry> entries{};
  };

  template <>
  struct MessageSchema<HistoryResults>
      : Schema<Direction::server, ServerTag::history_results,
               Field<&HistoryResults::request_id, NonzeroU64, "request_id">,
               SpanCountField<&HistoryResults::entries, u16, ValueCodec<HistoryEntry>, 1000,
                              "entry_count", 0>,
               Field<&HistoryResults::snapshot_id, u64, "snapshot_id">,
               Field<&HistoryResults::has_more, BoolByte, "has_more">,
               SpanItemsField<&HistoryResults::entries, ValueCodec<HistoryEntry>, "entries">> {};

  struct WorkspaceSnapshot {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view name{};
    std::span<const TabDescriptor> tabs{};
  };

  template <>
  struct MessageSchema<WorkspaceSnapshot>
      : Schema<Direction::server, ServerTag::workspace_snapshot,
               Field<&WorkspaceSnapshot::request_id, NonzeroU64, "request_id">,
               Field<&WorkspaceSnapshot::workspace, ValueCodec<WorkspaceLocation>, "workspace">,
               Field<&WorkspaceSnapshot::name, Text16<256, false>, "name">,
               SpanCountField<&WorkspaceSnapshot::tabs, u16, ValueCodec<TabDescriptor>, 64,
                              "tab_count", 0>,
               SpanItemsField<&WorkspaceSnapshot::tabs, ValueCodec<TabDescriptor>, "tabs">> {};

  struct TabCreated {
    std::uint64_t request_id{};
    TabLocation location{};
    std::uint16_t position{};
    std::string_view label{};
    std::uint64_t root_pane_id{};
    std::uint64_t pane_generation{};
  };

  template <>
  struct MessageSchema<TabCreated>
      : Schema<Direction::server, ServerTag::tab_created,
               Field<&TabCreated::request_id, NonzeroU64, "request_id">,
               Field<&TabCreated::location, ValueCodec<TabLocation>, "location">,
               Field<&TabCreated::position, u16, "position">,
               Field<&TabCreated::label, DisplayText16<128>, "label">,
               Field<&TabCreated::root_pane_id, NonzeroU64, "root_pane_id">,
               Field<&TabCreated::pane_generation, u64, "pane_generation">> {};

  struct TabRenamed {
    std::uint64_t request_id{};
    TabLocation location{};
    std::string_view label{};
  };

  template <>
  struct MessageSchema<TabRenamed>
      : Schema<Direction::server, ServerTag::tab_renamed,
               Field<&TabRenamed::request_id, NonzeroU64, "request_id">,
               Field<&TabRenamed::location, ValueCodec<TabLocation>, "location">,
               Field<&TabRenamed::label, DisplayText16<128, false>, "label">> {};

  struct TabClosed {
    std::uint64_t request_id{};
    TabLocation location{};
    bool workspace_closed{};
    std::optional<std::uint64_t> previous_workspace{};

    void validate() const {
      validateWorkspaceClosure(location.workspace, workspace_closed, previous_workspace);
    }
  };

  template <>
  struct MessageSchema<TabClosed>
      : Schema<Direction::server, ServerTag::tab_closed,
               Field<&TabClosed::request_id, u64, "request_id">,
               Field<&TabClosed::location, ValueCodec<TabLocation>, "location">,
               Field<&TabClosed::workspace_closed, BoolByte, "workspace_closed">,
               Field<&TabClosed::previous_workspace, OptionalValue<NonzeroU64>,
                     "previous_workspace">> {};

  struct TabMoved {
    std::uint64_t request_id{};
    TabLocation location{};
    std::uint16_t position{};
  };

  template <>
  struct MessageSchema<TabMoved>
      : Schema<Direction::server, ServerTag::tab_moved,
               Field<&TabMoved::request_id, NonzeroU64, "request_id">,
               Field<&TabMoved::location, ValueCodec<TabLocation>, "location">,
               Field<&TabMoved::position, u16, "position">> {};

  struct GraphicsSnapshot {
    GraphicsHeader header{};
    SnapshotPhase phase{};
  };

  template <>
  struct MessageSchema<GraphicsSnapshot>
      : Schema<Direction::server, ServerTag::graphics_snapshot,
               Field<&GraphicsSnapshot::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsSnapshot::phase, EnumByte<SnapshotPhase, 1>, "phase">> {};

  struct GraphicsImage {
    GraphicsHeader header{};
    ImageDescription image{};
  };

  template <>
  struct MessageSchema<GraphicsImage>
      : Schema<Direction::server, ServerTag::graphics_image,
               Field<&GraphicsImage::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsImage::image, ValueCodec<ImageDescription>, "image">> {};

  struct GraphicsImageChunk {
    GraphicsHeader header{};
    ImageKey key{};
    std::uint64_t offset{};
    std::span<const Byte> bytes{};
  };

  template <>
  struct MessageSchema<GraphicsImageChunk>
      : Schema<Direction::server, ServerTag::graphics_image_chunk,
               Field<&GraphicsImageChunk::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsImageChunk::key, ValueCodec<ImageKey>, "key">,
               Field<&GraphicsImageChunk::offset, u64, "offset">,
               Field<&GraphicsImageChunk::bytes, SizedBytes<u32, 1048576, 1>, "bytes">> {};

  struct GraphicsPlacementMessage {
    GraphicsHeader header{};
    GraphicsPlacement placement{};
  };

  template <>
  struct MessageSchema<GraphicsPlacementMessage>
      : Schema<Direction::server, ServerTag::graphics_placement,
               Field<&GraphicsPlacementMessage::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsPlacementMessage::placement, ValueCodec<GraphicsPlacement>,
                     "placement">> {};

  struct GraphicsDeleteImage {
    GraphicsHeader header{};
    ImageKey key{};
  };

  template <>
  struct MessageSchema<GraphicsDeleteImage>
      : Schema<Direction::server, ServerTag::graphics_delete_image,
               Field<&GraphicsDeleteImage::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsDeleteImage::key, ValueCodec<ImageKey>, "key">> {};

  struct GraphicsDeletePlacement {
    GraphicsHeader header{};
    ImageKey key{};
    std::uint64_t virtual_id{};
    std::uint32_t placement_id{};
  };

  template <>
  struct MessageSchema<GraphicsDeletePlacement>
      : Schema<Direction::server, ServerTag::graphics_delete_placement,
               Field<&GraphicsDeletePlacement::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsDeletePlacement::key, ValueCodec<ImageKey>, "key">,
               Field<&GraphicsDeletePlacement::virtual_id, u64, "virtual_id">,
               Field<&GraphicsDeletePlacement::placement_id, u32, "placement_id">> {};

  struct ResyncRequired {
    WorkspaceLocation workspace{};
    bool workspace_closed{};
    std::optional<std::uint64_t> previous_workspace{};

    void validate() const {
      validateWorkspaceClosure(workspace, workspace_closed, previous_workspace);
    }
  };

  template <>
  struct MessageSchema<ResyncRequired>
      : Schema<Direction::server, ServerTag::resync_required,
               Field<&ResyncRequired::workspace, ValueCodec<WorkspaceLocation>, "workspace">,
               Field<&ResyncRequired::workspace_closed, BoolByte, "workspace_closed">,
               Field<&ResyncRequired::previous_workspace, OptionalValue<NonzeroU64>,
                     "previous_workspace">> {};

  struct GraphicsSharedImage {
    GraphicsHeader header{};
    ImageDescription image{};
    std::string_view name{};

    void validate() const { validateSharedImageName(name); }
  };

  template <>
  struct MessageSchema<GraphicsSharedImage>
      : Schema<Direction::server, ServerTag::graphics_shared_image,
               Field<&GraphicsSharedImage::header, ValueCodec<GraphicsHeader>, "header">,
               Field<&GraphicsSharedImage::image, ValueCodec<ImageDescription>, "image">,
               Field<&GraphicsSharedImage::name, Text32<31, false>, "name">> {};

  struct ProxyStatus {
    bool active{};
    ProxyScope scope{};
    bool system_trusted{};
    std::optional<std::uint16_t> port{};
    std::optional<std::uint16_t> preferred_port{};
  };

  template <>
  struct MessageSchema<ProxyStatus>
      : Schema<Direction::server, ServerTag::proxy_status,
               Field<&ProxyStatus::active, BoolByte, "active">,
               Field<&ProxyStatus::scope, EnumByte<ProxyScope, 1>, "scope">,
               Field<&ProxyStatus::system_trusted, BoolByte, "system_trusted">,
               Field<&ProxyStatus::port, OptionalValue<u16>, "port">,
               Field<&ProxyStatus::preferred_port, OptionalValue<u16>, "preferred_port">> {};

  struct AgentSnapshot {
    std::uint64_t revision{};
    std::span<const AgentSnapshotEntry> entries{};
  };

  template <>
  struct MessageSchema<AgentSnapshot>
      : Schema<Direction::server, ServerTag::agent_snapshot,
               Field<&AgentSnapshot::revision, u64, "revision">,
               SpanCountField<&AgentSnapshot::entries, u16, ValueCodec<AgentSnapshotEntry>, 64,
                              "entry_count", 0>,
               SpanItemsField<&AgentSnapshot::entries, ValueCodec<AgentSnapshotEntry>, "entries">> {
  };

  struct WorkspaceList {
    std::uint64_t revision{};
    std::span<const WorkspaceListEntry> entries{};
    std::span<const WorktreeListEntry> worktrees{};
  };

  template <>
  struct MessageSchema<WorkspaceList>
      : Schema<
            Direction::server, ServerTag::workspace_list,
            Field<&WorkspaceList::revision, u64, "revision">,
            SpanCountField<&WorkspaceList::entries, u16, ValueCodec<WorkspaceListEntry>, 64,
                           "entry_count", 0>,
            SpanItemsField<&WorkspaceList::entries, ValueCodec<WorkspaceListEntry>, "entries">,
            SpanCountField<&WorkspaceList::worktrees, u16, ValueCodec<WorktreeListEntry>, 64,
                           "worktree_count", 0>,
            SpanItemsField<&WorkspaceList::worktrees, ValueCodec<WorktreeListEntry>, "worktrees">> {
  };

  struct PaneCwd {
    std::uint64_t pane_id{};
    std::string_view cwd{};
  };

  template <>
  struct MessageSchema<PaneCwd> : Schema<Direction::server, ServerTag::pane_cwd,
                                         Field<&PaneCwd::pane_id, NonzeroU64, "pane_id">,
                                         Field<&PaneCwd::cwd, Text16<4096, false>, "cwd">> {};

  struct PaneClipboard {
    std::uint64_t pane_id{};
    std::span<const Byte> bytes{};
  };

  template <>
  struct MessageSchema<PaneClipboard>
      : Schema<Direction::server, ServerTag::pane_clipboard,
               Field<&PaneClipboard::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneClipboard::bytes, SizedBytes<u32, 1048576>, "bytes">> {};

  struct Notification : NotificationBody {};

  template <>
  struct MessageSchema<Notification>
      : MessageLayout<Direction::server, ServerTag::notification, BodySchema<NotificationBody>> {};

  struct NotificationShown {
    std::uint64_t request_id{};
    std::uint8_t delivered_clients{};
  };

  template <>
  struct MessageSchema<NotificationShown>
      : Schema<Direction::server, ServerTag::notification_shown,
               Field<&NotificationShown::request_id, NonzeroU64, "request_id">,
               Field<&NotificationShown::delivered_clients, u8, "delivered_clients">> {};

  template <>
  struct MessageSchema<PaneForeground>
      : Schema<Direction::server, ServerTag::pane_foreground,
               Field<&PaneForeground::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneForeground::name, Text16<48, false>, "name">> {};

  struct AgentSoundNotification {
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    AgentSound sound{};
  };

  template <>
  struct MessageSchema<AgentSoundNotification>
      : Schema<Direction::server, ServerTag::agent_sound,
               Field<&AgentSoundNotification::pane_id, NonzeroU64, "pane_id">,
               Field<&AgentSoundNotification::pane_generation, u64, "pane_generation">,
               Field<&AgentSoundNotification::sound, EnumByte<AgentSound, 1>, "sound">> {};

  struct ClientLayoutSnapshot {
    bool restored{};
    bool sidebar_visible{};
    std::uint16_t sidebar_width{};
    bool workspace_list_collapsed{};
    std::optional<TabLocation> active_tab{};
    std::span<const ClientTabLayout> tabs{};

    void validate() const {
      if (!restored) {
        if (sidebar_width != 0 || active_tab || !tabs.empty()) {
          throw EncodingError{"Invalid empty layout"};
        }
      } else {
        if (sidebar_width == 0) {
          throw EncodingError{"Invalid sidebar width"};
        }
        validateLayoutCollection(active_tab, tabs);
      }
    }
  };

  template <>
  struct MessageSchema<ClientLayoutSnapshot>
      : Schema<Direction::server, ServerTag::client_layout_snapshot,
               Field<&ClientLayoutSnapshot::restored, BoolByte, "restored">,
               Field<&ClientLayoutSnapshot::sidebar_visible, BoolByte, "sidebar_visible">,
               Field<&ClientLayoutSnapshot::sidebar_width, u16, "sidebar_width">,
               Field<&ClientLayoutSnapshot::workspace_list_collapsed, BoolByte,
                     "workspace_list_collapsed">,
               Field<&ClientLayoutSnapshot::active_tab, OptionalValue<ValueCodec<TabLocation>>,
                     "active_tab">,
               SpanCountField<&ClientLayoutSnapshot::tabs, u16, ValueCodec<ClientTabLayout>, 256,
                              "tab_count", 0>,
               SpanItemsField<&ClientLayoutSnapshot::tabs, ValueCodec<ClientTabLayout>, "tabs">> {};

  struct PaneText {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    bool truncated{};
    std::string_view text{};
    std::optional<std::int32_t> exit_code{};
  };

  template <>
  struct MessageSchema<PaneText>
      : Schema<Direction::server, ServerTag::pane_text,
               Field<&PaneText::request_id, NonzeroU64, "request_id">,
               Field<&PaneText::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneText::truncated, BoolByte, "truncated">,
               Field<&PaneText::text, SizedText<u32, 262144, true, TextRule::opaque>, "text">,
               Field<&PaneText::exit_code, OptionalValue<i32>, "exit_code">> {};

  struct RequestCompleted {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<RequestCompleted>
      : Schema<Direction::server, ServerTag::request_completed,
               Field<&RequestCompleted::request_id, NonzeroU64, "request_id">> {};

  struct PaneTitle {
    std::uint64_t pane_id{};
    std::string_view title{};
  };

  template <>
  struct MessageSchema<PaneTitle> : Schema<Direction::server, ServerTag::pane_title,
                                           Field<&PaneTitle::pane_id, NonzeroU64, "pane_id">,
                                           Field<&PaneTitle::title, Text16<256>, "title">> {};

  struct PaneMatches {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    bool truncated{};
    std::span<const PaneMatch> matches{};
  };

  template <>
  struct MessageSchema<PaneMatches>
      : Schema<Direction::server, ServerTag::pane_matches,
               Field<&PaneMatches::request_id, NonzeroU64, "request_id">,
               Field<&PaneMatches::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneMatches::truncated, BoolByte, "truncated">,
               SpanCountField<&PaneMatches::matches, u16, ValueCodec<PaneMatch>, 256, "match_count",
                              0>,
               SpanItemsField<&PaneMatches::matches, ValueCodec<PaneMatch>, "matches">> {};

  struct HistoryPruned {
    std::uint64_t request_id{};
    std::uint64_t removed{};
  };

  template <>
  struct MessageSchema<HistoryPruned>
      : Schema<Direction::server, ServerTag::history_pruned,
               Field<&HistoryPruned::request_id, NonzeroU64, "request_id">,
               Field<&HistoryPruned::removed, u64, "removed">> {};

  struct HistoryOutput {
    std::uint64_t request_id{};
    std::uint64_t id{};
    bool truncated{};
    std::uint64_t observed_bytes{};
    std::span<const Byte> content{};
  };

  template <>
  struct MessageSchema<HistoryOutput>
      : Schema<Direction::server, ServerTag::history_output,
               Field<&HistoryOutput::request_id, NonzeroU64, "request_id">,
               Field<&HistoryOutput::id, u64, "id">,
               Field<&HistoryOutput::truncated, BoolByte, "truncated">,
               Field<&HistoryOutput::observed_bytes, u64, "observed_bytes">,
               Field<&HistoryOutput::content, SizedBytes<u32, 65536>, "content">> {};

  struct HistoryStatsResult {
    std::uint64_t request_id{};
    std::uint64_t total{};
    std::uint64_t unique{};
    std::span<const HistoryStatsEntry> top{};
  };

  template <>
  struct MessageSchema<HistoryStatsResult>
      : Schema<Direction::server, ServerTag::history_stats_result,
               Field<&HistoryStatsResult::request_id, NonzeroU64, "request_id">,
               Field<&HistoryStatsResult::total, u64, "total">,
               Field<&HistoryStatsResult::unique, u64, "unique">,
               SpanCountField<&HistoryStatsResult::top, u8, ValueCodec<HistoryStatsEntry>, 10,
                              "top_count", 0>,
               SpanItemsField<&HistoryStatsResult::top, ValueCodec<HistoryStatsEntry>, "top">> {};

  struct PaneFocusCommand {
    ClientRoute requester{};
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneDirection direction{};

    void validate() const {
      if (pane_generation == 0) {
        throw EncodingError{"Invalid pane generation"};
      }
    }
  };

  template <>
  struct MessageSchema<PaneFocusCommand>
      : Schema<Direction::server, ServerTag::pane_focus_command,
               Field<&PaneFocusCommand::requester, ValueCodec<ClientRoute>, "requester">,
               Field<&PaneFocusCommand::request_id, NonzeroU64, "request_id">,
               Field<&PaneFocusCommand::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneFocusCommand::pane_generation, u64, "pane_generation">,
               Field<&PaneFocusCommand::direction, EnumByte<PaneDirection, 3>, "direction">> {};

  struct PaneFocusResult {
    std::uint64_t request_id{};
    PaneFocusOutcome outcome{};
    std::uint64_t focused_pane_id{};

    void validate() const {
      if (outcome == PaneFocusOutcome::focused && focused_pane_id == 0) {
        throw EncodingError{"Missing focused pane"};
      }
    }
  };

  template <>
  struct MessageSchema<PaneFocusResult>
      : Schema<Direction::server, ServerTag::pane_focus_result,
               Field<&PaneFocusResult::request_id, NonzeroU64, "request_id">,
               Field<&PaneFocusResult::outcome, EnumByte<PaneFocusOutcome, 2>, "outcome">,
               Field<&PaneFocusResult::focused_pane_id, u64, "focused_pane_id">> {};

  struct CommandSuggestion {
    std::uint64_t request_id{};
    SuggestionStatus status{};
    std::string_view text{};

    void validate() const {
      if (status != SuggestionStatus::ready && !text.empty()) {
        throw EncodingError{"Unexpected suggestion text"};
      }
    }
  };

  template <>
  struct MessageSchema<CommandSuggestion>
      : Schema<Direction::server, ServerTag::command_suggestion,
               Field<&CommandSuggestion::request_id, NonzeroU64, "request_id">,
               Field<&CommandSuggestion::status, EnumByte<SuggestionStatus, 3>, "status">,
               Field<&CommandSuggestion::text, Text16<1024>, "text">> {};

  struct PaneProgress {
    std::uint64_t pane_id{};
    PaneProgressState state{};
    std::optional<Byte> percent{};

    void validate() const {
      if ((state == PaneProgressState::remove || state == PaneProgressState::indeterminate) &&
          percent) {
        throw EncodingError{"Unexpected progress percent"};
      }
      if (state == PaneProgressState::set && !percent) {
        throw EncodingError{"Missing progress percent"};
      }
    }
  };

  template <>
  struct MessageSchema<PaneProgress>
      : Schema<Direction::server, ServerTag::pane_progress,
               Field<&PaneProgress::pane_id, NonzeroU64, "pane_id">,
               Field<&PaneProgress::state, EnumByte<PaneProgressState, 4>, "state">,
               Field<&PaneProgress::percent, PercentSentinel, "percent">> {};

  struct ClientList {
    std::uint64_t request_id{};
    std::span<const ClientDescriptor> entries{};

    void validate() const {
      for (std::size_t i = 0; i < entries.size(); ++i) {
        for (std::size_t j = 0; j < i; ++j) {
          if (entries[i].id == entries[j].id) {
            throw EncodingError{"Duplicate client identity"};
          }
        }
      }
    }
  };

  template <>
  struct MessageSchema<ClientList>
      : Schema<
            Direction::server, ServerTag::client_list,
            Field<&ClientList::request_id, NonzeroU64, "request_id">,
            SpanCountField<&ClientList::entries, u8, ValueCodec<ClientDescriptor>, 32, "count", 0>,
            SpanItemsField<&ClientList::entries, ValueCodec<ClientDescriptor>, "entries">> {};

  template <>
  struct MessageSchema<ClientCommand>
      : MessageLayout<Direction::server, ServerTag::client_command, BodySchema<ClientCommand>> {};

  struct ClientCommandResult : ClientCommand {};

  template <>
  struct MessageSchema<ClientCommandResult>
      : MessageLayout<Direction::server, ServerTag::client_command_result,
                      BodySchema<ClientCommand>> {};

  struct EditorOpened {
    std::uint64_t request_id{};
    EditorOutcome outcome{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};

    void validate() const {
      if (outcome == EditorOutcome::opened && (pane_id == 0 || pane_generation == 0)) {
        throw EncodingError{"Missing editor pane identity"};
      }
    }
  };

  template <>
  struct MessageSchema<EditorOpened>
      : Schema<Direction::server, ServerTag::editor_opened,
               Field<&EditorOpened::request_id, NonzeroU64, "request_id">,
               Field<&EditorOpened::outcome, EnumByte<EditorOutcome, 3>, "outcome">,
               Field<&EditorOpened::pane_id, u64, "pane_id">,
               Field<&EditorOpened::pane_generation, u64, "pane_generation">> {};

  struct PathResults {
    std::uint64_t request_id{};
    std::string_view root{};
    std::uint32_t scanned{};
    bool complete{};
    bool truncated{};
    std::span<const PathMatch> matches{};

    void validate() const {
      if (root.empty() || root.front() != '/') {
        throw EncodingError{"Invalid path root"};
      }
    }
  };

  template <>
  struct MessageSchema<PathResults>
      : Schema<
            Direction::server, ServerTag::path_results,
            Field<&PathResults::request_id, NonzeroU64, "request_id">,
            Field<&PathResults::root, Text16<4096, false>, "root">,
            Field<&PathResults::scanned, u32, "scanned">,
            Field<&PathResults::complete, BoolByte, "complete">,
            Field<&PathResults::truncated, BoolByte, "truncated">,
            SpanCountField<&PathResults::matches, u16, ValueCodec<PathMatch>, 50, "match_count", 0>,
            SpanItemsField<&PathResults::matches, ValueCodec<PathMatch>, "matches">> {};

  struct WorktreeRegistered {
    std::uint64_t request_id{};
    std::uint64_t worktree{};
    bool created{};
  };

  template <>
  struct MessageSchema<WorktreeRegistered>
      : Schema<Direction::server, ServerTag::worktree_registered,
               Field<&WorktreeRegistered::request_id, NonzeroU64, "request_id">,
               Field<&WorktreeRegistered::worktree, NonzeroU64, "worktree">,
               Field<&WorktreeRegistered::created, BoolByte, "created">> {};

  struct LimitList {
    std::uint64_t request_id{};
    std::uint64_t runtime_evicted{};
    std::uint64_t client_evicted{};
    std::uint64_t refused_reports{};
    std::span<const LimitListEntry> entries{};
  };

  template <>
  struct MessageSchema<LimitList>
      : Schema<Direction::server, ServerTag::limit_list,
               Field<&LimitList::request_id, NonzeroU64, "request_id">,
               Field<&LimitList::runtime_evicted, u64, "runtime_evicted">,
               Field<&LimitList::client_evicted, u64, "client_evicted">,
               Field<&LimitList::refused_reports, u64, "refused_reports">,
               SpanCountField<&LimitList::entries, u16, ValueCodec<LimitListEntry>, 256,
                              "entry_count", 0>,
               SpanItemsField<&LimitList::entries, ValueCodec<LimitListEntry>, "entries">> {};

  struct ExecutionReply {
    std::uint64_t request_id{};
    std::uint64_t execution_id{};
    std::uint64_t workspace_id{};
    std::uint64_t stdout_offset{};
    std::uint64_t stderr_offset{};
    std::uint64_t stdout_total{};
    std::uint64_t stderr_total{};
    std::uint64_t input_offset{};
    std::uint64_t input_available{};
    ExecutionState state{};
    std::int32_t exit_code{};
    bool stdin_open{};
    std::span<const Byte> failure{};
    std::span<const Byte> stdout_bytes{};
    std::span<const Byte> stderr_bytes{};
  };

  template <>
  struct MessageSchema<ExecutionReply>
      : Schema<Direction::server, ServerTag::execution_reply,
               Field<&ExecutionReply::request_id, NonzeroU64, "request_id">,
               Field<&ExecutionReply::execution_id, u64, "execution_id">,
               Field<&ExecutionReply::workspace_id, u64, "workspace_id">,
               Field<&ExecutionReply::stdout_offset, u64, "stdout_offset">,
               Field<&ExecutionReply::stderr_offset, u64, "stderr_offset">,
               Field<&ExecutionReply::stdout_total, u64, "stdout_total">,
               Field<&ExecutionReply::stderr_total, u64, "stderr_total">,
               Field<&ExecutionReply::input_offset, u64, "input_offset">,
               Field<&ExecutionReply::input_available, u64, "input_available">,
               Field<&ExecutionReply::state, EnumByte<ExecutionState, 3>, "state">,
               Field<&ExecutionReply::exit_code, i32, "exit_code">,
               Field<&ExecutionReply::stdin_open, BoolByte, "stdin_open">,
               Field<&ExecutionReply::failure, SizedBytes<u16, 128>, "failure">,
               Field<&ExecutionReply::stdout_bytes, SizedBytes<u16, 4096>, "stdout">,
               Field<&ExecutionReply::stderr_bytes, SizedBytes<u16, 4096>, "stderr">> {};

} // namespace telar
