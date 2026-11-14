#pragma once

#include "../serializers/telar_messages.hpp"

namespace telar {

  struct RequestTabSnapshot {
    std::uint64_t request_id{};
    TabLocation location{};
  };

  template <>
  struct MessageSchema<RequestTabSnapshot>
      : Schema<Direction::client, ClientTag::request_tab_snapshot, Field<&RequestTabSnapshot::request_id, NonzeroU64, "request_id">, Field<&RequestTabSnapshot::location, ValueCodec<TabLocation>, "location">> {};

  struct RequestWorkspaceSnapshot {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
  };

  template <>
  struct MessageSchema<RequestWorkspaceSnapshot>
      : Schema<Direction::client, ClientTag::request_workspace_snapshot, Field<&RequestWorkspaceSnapshot::request_id, NonzeroU64, "request_id">, Field<&RequestWorkspaceSnapshot::workspace, ValueCodec<WorkspaceLocation>, "workspace">> {};

  struct CreateTab {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view label{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreateTab>
      : Schema<Direction::client, ClientTag::create_tab, Field<&CreateTab::request_id, NonzeroU64, "request_id">, Field<&CreateTab::workspace, ValueCodec<WorkspaceLocation>, "workspace">, Field<&CreateTab::label, DisplayText16<128>, "label">, Field<&CreateTab::size, ValueCodec<TerminalSize>, "size">, Field<&CreateTab::launch, ValueCodec<Launch>, "launch">> {};

  struct RenameTab {
    std::uint64_t request_id{};
    TabLocation location{};
    std::string_view label{};
  };

  template <>
  struct MessageSchema<RenameTab>
      : Schema<Direction::client, ClientTag::rename_tab, Field<&RenameTab::request_id, NonzeroU64, "request_id">, Field<&RenameTab::location, ValueCodec<TabLocation>, "location">, Field<&RenameTab::label, DisplayText16<128, false>, "label">> {};

  struct CloseTab {
    std::uint64_t request_id{};
    TabLocation location{};
  };

  template <>
  struct MessageSchema<CloseTab>
      : Schema<Direction::client, ClientTag::close_tab, Field<&CloseTab::request_id, NonzeroU64, "request_id">, Field<&CloseTab::location, ValueCodec<TabLocation>, "location">> {};

  // Keeps a tab with no panes while this client shows something else there.
  struct HoldTab {
    std::uint64_t request_id{};
    TabLocation location{};
    bool held{};
  };

  template <>
  struct MessageSchema<HoldTab>
      : Schema<Direction::client, ClientTag::hold_tab, Field<&HoldTab::request_id, NonzeroU64, "request_id">, Field<&HoldTab::location, ValueCodec<TabLocation>, "location">, Field<&HoldTab::held, BoolByte, "held">> {};

  struct MoveTab {
    std::uint64_t request_id{};
    TabLocation location{};
    TabMoveDirection direction{};
    std::optional<std::uint64_t> relative_to{};
  };

  template <>
  struct MessageSchema<MoveTab>
      : Schema<Direction::client, ClientTag::move_tab, Field<&MoveTab::request_id, NonzeroU64, "request_id">, Field<&MoveTab::location, ValueCodec<TabLocation>, "location">, Field<&MoveTab::direction, EnumByte<TabMoveDirection, 1>, "direction">, Field<&MoveTab::relative_to, OptionalValue<NonzeroU64>, "relative_to">> {};

  struct CreateWorkspace {
    std::uint64_t request_id{};
    TerminalSize size{};
    std::string_view name{};
    bool create_cwd{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<CreateWorkspace>
      : Schema<Direction::client, ClientTag::create_workspace, Field<&CreateWorkspace::request_id, NonzeroU64, "request_id">, Field<&CreateWorkspace::size, ValueCodec<TerminalSize>, "size">, Field<&CreateWorkspace::name, DisplayText16<128, false>, "name">, Field<&CreateWorkspace::create_cwd, BoolByte, "create_cwd">, Field<&CreateWorkspace::launch, ValueCodec<Launch>, "launch">> {};

  struct RenameWorkspace {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view name{};
  };

  template <>
  struct MessageSchema<RenameWorkspace>
      : Schema<Direction::client, ClientTag::rename_workspace, Field<&RenameWorkspace::request_id, NonzeroU64, "request_id">, Field<&RenameWorkspace::workspace, ValueCodec<WorkspaceLocation>, "workspace">, Field<&RenameWorkspace::name, DisplayText16<128, false>, "name">> {};

  struct UpdateClientLayout {
    bool sidebar_visible{};
    std::uint16_t sidebar_width{};
    bool workspace_list_collapsed{};
    TabLocation active_tab{};
    std::span<const ClientTabLayout> tabs{};

    void validate() const;
  };

  template <>
  struct MessageSchema<UpdateClientLayout>
      : Schema<Direction::client, ClientTag::update_client_layout, Field<&UpdateClientLayout::sidebar_visible, BoolByte, "sidebar_visible">, Field<&UpdateClientLayout::sidebar_width, u16, "sidebar_width">, Field<&UpdateClientLayout::workspace_list_collapsed, BoolByte, "workspace_list_collapsed">, Field<&UpdateClientLayout::active_tab, ValueCodec<TabLocation>, "active_tab">, SpanCountField<&UpdateClientLayout::tabs, u16, ValueCodec<ClientTabLayout>, 256, "tab_count", 1>, SpanItemsField<&UpdateClientLayout::tabs, ValueCodec<ClientTabLayout>, "tabs">> {};

  struct RequestPaneFocus {
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneDirection direction{};

    void validate() const;
  };

  template <>
  struct MessageSchema<RequestPaneFocus>
      : Schema<Direction::client, ClientTag::request_pane_focus, Field<&RequestPaneFocus::request_id, NonzeroU64, "request_id">, Field<&RequestPaneFocus::pane_id, NonzeroU64, "pane_id">, Field<&RequestPaneFocus::pane_generation, u64, "pane_generation">, Field<&RequestPaneFocus::direction, EnumByte<PaneDirection, 3>, "direction">> {};

  struct CompletePaneFocus {
    ClientRoute requester{};
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneFocusOutcome outcome{};
    std::uint64_t focused_pane_id{};

    void validate() const;
  };

  template <>
  struct MessageSchema<CompletePaneFocus>
      : Schema<Direction::client, ClientTag::complete_pane_focus, Field<&CompletePaneFocus::requester, ValueCodec<ClientRoute>, "requester">, Field<&CompletePaneFocus::request_id, NonzeroU64, "request_id">, Field<&CompletePaneFocus::pane_id, NonzeroU64, "pane_id">, Field<&CompletePaneFocus::pane_generation, u64, "pane_generation">, Field<&CompletePaneFocus::outcome, EnumByte<PaneFocusOutcome, 2>, "outcome">, Field<&CompletePaneFocus::focused_pane_id, u64, "focused_pane_id">> {};

  struct LaunchTab {
    std::uint64_t request_id{};
    std::uint64_t workspace{};
    std::string_view label{};
    TerminalSize size{};
    Launch launch{};
  };

  template <>
  struct MessageSchema<LaunchTab>
      : Schema<Direction::client, ClientTag::launch_tab, Field<&LaunchTab::request_id, NonzeroU64, "request_id">, Field<&LaunchTab::workspace, NonzeroU64, "workspace">, Field<&LaunchTab::label, DisplayText16<128>, "label">, Field<&LaunchTab::size, ValueCodec<TerminalSize>, "size">, Field<&LaunchTab::launch, ValueCodec<Launch>, "launch">> {};

  struct TabSnapshot {
    std::uint64_t request_id{};
    TabLocation location{};
    std::span<const PaneDescriptor> panes{};

    void validate() const;
  };

  template <>
  struct MessageSchema<TabSnapshot>
      : Schema<Direction::server, ServerTag::tab_snapshot, Field<&TabSnapshot::request_id, NonzeroU64, "request_id">, Field<&TabSnapshot::location, ValueCodec<TabLocation>, "location">, SpanCountField<&TabSnapshot::panes, u16, ValueCodec<PaneDescriptor>, 64, "pane_count", 0>, SpanItemsField<&TabSnapshot::panes, ValueCodec<PaneDescriptor>, "panes">> {};

  struct WorkspaceSnapshot {
    std::uint64_t request_id{};
    WorkspaceLocation workspace{};
    std::string_view name{};
    std::span<const TabDescriptor> tabs{};
  };

  template <>
  struct MessageSchema<WorkspaceSnapshot>
      : Schema<Direction::server, ServerTag::workspace_snapshot, Field<&WorkspaceSnapshot::request_id, NonzeroU64, "request_id">, Field<&WorkspaceSnapshot::workspace, ValueCodec<WorkspaceLocation>, "workspace">, Field<&WorkspaceSnapshot::name, Text16<256, false>, "name">, SpanCountField<&WorkspaceSnapshot::tabs, u16, ValueCodec<TabDescriptor>, 64, "tab_count", 0>, SpanItemsField<&WorkspaceSnapshot::tabs, ValueCodec<TabDescriptor>, "tabs">> {};

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
      : Schema<Direction::server, ServerTag::tab_created, Field<&TabCreated::request_id, NonzeroU64, "request_id">, Field<&TabCreated::location, ValueCodec<TabLocation>, "location">, Field<&TabCreated::position, u16, "position">, Field<&TabCreated::label, DisplayText16<128>, "label">, Field<&TabCreated::root_pane_id, NonzeroU64, "root_pane_id">, Field<&TabCreated::pane_generation, u64, "pane_generation">> {};

  struct TabRenamed {
    std::uint64_t request_id{};
    TabLocation location{};
    std::string_view label{};
  };

  template <>
  struct MessageSchema<TabRenamed>
      : Schema<Direction::server, ServerTag::tab_renamed, Field<&TabRenamed::request_id, NonzeroU64, "request_id">, Field<&TabRenamed::location, ValueCodec<TabLocation>, "location">, Field<&TabRenamed::label, DisplayText16<128, false>, "label">> {};

  struct TabClosed {
    std::uint64_t request_id{};
    TabLocation location{};
    bool workspace_closed{};
    std::optional<std::uint64_t> previous_workspace{};

    void validate() const;
  };

  template <>
  struct MessageSchema<TabClosed>
      : Schema<Direction::server, ServerTag::tab_closed, Field<&TabClosed::request_id, u64, "request_id">, Field<&TabClosed::location, ValueCodec<TabLocation>, "location">, Field<&TabClosed::workspace_closed, BoolByte, "workspace_closed">, Field<&TabClosed::previous_workspace, OptionalValue<NonzeroU64>, "previous_workspace">> {};

  struct TabMoved {
    std::uint64_t request_id{};
    TabLocation location{};
    std::uint16_t position{};
  };

  template <>
  struct MessageSchema<TabMoved>
      : Schema<Direction::server, ServerTag::tab_moved, Field<&TabMoved::request_id, NonzeroU64, "request_id">, Field<&TabMoved::location, ValueCodec<TabLocation>, "location">, Field<&TabMoved::position, u16, "position">> {};

  struct ResyncRequired {
    WorkspaceLocation workspace{};
    bool workspace_closed{};
    std::optional<std::uint64_t> previous_workspace{};

    void validate() const;
  };

  template <>
  struct MessageSchema<ResyncRequired>
      : Schema<Direction::server, ServerTag::resync_required, Field<&ResyncRequired::workspace, ValueCodec<WorkspaceLocation>, "workspace">, Field<&ResyncRequired::workspace_closed, BoolByte, "workspace_closed">, Field<&ResyncRequired::previous_workspace, OptionalValue<NonzeroU64>, "previous_workspace">> {};

  struct WorkspaceList {
    std::uint64_t revision{};
    std::span<const WorkspaceListEntry> entries{};
    std::span<const WorktreeListEntry> worktrees{};
  };

  template <>
  struct MessageSchema<WorkspaceList>
      : Schema<
            Direction::server,
            ServerTag::workspace_list,
            Field<&WorkspaceList::revision, u64, "revision">,
            SpanCountField<&WorkspaceList::entries, u16, ValueCodec<WorkspaceListEntry>, 64, "entry_count", 0>,
            SpanItemsField<&WorkspaceList::entries, ValueCodec<WorkspaceListEntry>, "entries">,
            SpanCountField<&WorkspaceList::worktrees, u16, ValueCodec<WorktreeListEntry>, 64, "worktree_count", 0>,
            SpanItemsField<&WorkspaceList::worktrees, ValueCodec<WorktreeListEntry>, "worktrees">> {
  };

  struct ClientLayoutSnapshot {
    bool restored{};
    bool sidebar_visible{};
    std::uint16_t sidebar_width{};
    bool workspace_list_collapsed{};
    std::optional<TabLocation> active_tab{};
    std::span<const ClientTabLayout> tabs{};

    void validate() const;
  };

  template <>
  struct MessageSchema<ClientLayoutSnapshot>
      : Schema<Direction::server, ServerTag::client_layout_snapshot, Field<&ClientLayoutSnapshot::restored, BoolByte, "restored">, Field<&ClientLayoutSnapshot::sidebar_visible, BoolByte, "sidebar_visible">, Field<&ClientLayoutSnapshot::sidebar_width, u16, "sidebar_width">, Field<&ClientLayoutSnapshot::workspace_list_collapsed, BoolByte, "workspace_list_collapsed">, Field<&ClientLayoutSnapshot::active_tab, OptionalValue<ValueCodec<TabLocation>>, "active_tab">, SpanCountField<&ClientLayoutSnapshot::tabs, u16, ValueCodec<ClientTabLayout>, 256, "tab_count", 0>, SpanItemsField<&ClientLayoutSnapshot::tabs, ValueCodec<ClientTabLayout>, "tabs">> {};

  struct PaneFocusCommand {
    ClientRoute requester{};
    std::uint64_t request_id{};
    std::uint64_t pane_id{};
    std::uint64_t pane_generation{};
    PaneDirection direction{};

    void validate() const;
  };

  template <>
  struct MessageSchema<PaneFocusCommand>
      : Schema<Direction::server, ServerTag::pane_focus_command, Field<&PaneFocusCommand::requester, ValueCodec<ClientRoute>, "requester">, Field<&PaneFocusCommand::request_id, NonzeroU64, "request_id">, Field<&PaneFocusCommand::pane_id, NonzeroU64, "pane_id">, Field<&PaneFocusCommand::pane_generation, u64, "pane_generation">, Field<&PaneFocusCommand::direction, EnumByte<PaneDirection, 3>, "direction">> {};

  struct PaneFocusResult {
    std::uint64_t request_id{};
    PaneFocusOutcome outcome{};
    std::uint64_t focused_pane_id{};

    void validate() const;
  };

  template <>
  struct MessageSchema<PaneFocusResult>
      : Schema<Direction::server, ServerTag::pane_focus_result, Field<&PaneFocusResult::request_id, NonzeroU64, "request_id">, Field<&PaneFocusResult::outcome, EnumByte<PaneFocusOutcome, 2>, "outcome">, Field<&PaneFocusResult::focused_pane_id, u64, "focused_pane_id">> {};

} // namespace telar
