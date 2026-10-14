#pragma once

#include "../codecs/telar_codec.hpp"
#include "../codecs/telar_value_codec.hpp"

#include <optional>
#include <stdexcept>
#include <string_view>
#include <variant>

namespace telar {

  enum class ClientTag : Byte {
    open_pane = 0x01,
    pane_input = 0x02,
    pane_resize = 0x03,
    frame_ack = 0x04,
    request_snapshot = 0x05,
    detach_pane = 0x06,
    runtime_stop = 0x07,
    request_tab_snapshot = 0x08,
    create_pane = 0x09,
    close_pane = 0x0a,
    query_history = 0x0b,
    request_workspace_snapshot = 0x0c,
    create_tab = 0x0d,
    rename_tab = 0x0e,
    close_tab = 0x0f,
    move_tab = 0x10,
    request_graphics_snapshot = 0x11,
    graphics_credit = 0x12,
    configure_graphics = 0x13,
    request_runtime_state = 0x14,
    create_workspace = 0x15,
    rename_workspace = 0x16,
    set_pane_viewport = 0x17,
    copy_selection = 0x18,
    show_notification = 0x19,
    update_client_layout = 0x1a,
    acknowledge_agent = 0x1b,
    query_agents = 0x1c,
    read_pane = 0x1d,
    send_pane_text = 0x1e,
    report_agent_session = 0x1f,
    report_agent = 0x20,
    search_pane = 0x21,
    import_history = 0x22,
    delete_history = 0x23,
    prune_history = 0x24,
    read_history_output = 0x25,
    history_stats = 0x26,
    request_pane_focus = 0x27,
    complete_pane_focus = 0x28,
    suggest_command = 0x29,
    report_agent_command = 0x2a,
    report_agent_title = 0x2b,
    configure_terminal_colors = 0x2c,
    query_clients = 0x33,
    detach_client = 0x34,
    request_client_command = 0x35,
    complete_client_command = 0x36,
    open_editor = 0x3a,
    find_paths = 0x3b,
    register_worktree = 0x3c,
    launch_worktree = 0x3d,
    forget_worktree = 0x3e,
    interrupt_agent = 0x3f,
    report_agent_progress = 0x40,
    launch_tab = 0x41,
    verify_pane_descent = 0x42,
    report_limit = 0x43,
    query_limits = 0x44,
    configure_frame_interval = 0x45,
    execution_request = 0x46,
  };

  enum class ServerTag : Byte {
    pane_opened = 0x81,
    pane_frame = 0x82,
    pane_exited = 0x83,
    request_failed = 0x84,
    runtime_stopping = 0x85,
    tab_snapshot = 0x86,
    history_results = 0x87,
    workspace_snapshot = 0x88,
    tab_created = 0x89,
    tab_renamed = 0x8a,
    tab_closed = 0x8b,
    tab_moved = 0x8c,
    graphics_snapshot = 0x8d,
    graphics_image = 0x8e,
    graphics_image_chunk = 0x8f,
    graphics_placement = 0x90,
    graphics_delete_image = 0x91,
    graphics_delete_placement = 0x92,
    resync_required = 0x93,
    graphics_shared_image = 0x94,
    proxy_status = 0x95,
    agent_snapshot = 0x96,
    system_metrics = 0x97,
    workspace_list = 0x98,
    pane_cwd = 0x99,
    pane_clipboard = 0x9a,
    notification = 0x9b,
    notification_shown = 0x9c,
    pane_foreground = 0x9d,
    agent_sound = 0x9e,
    client_layout_snapshot = 0x9f,
    pane_text = 0xa0,
    request_completed = 0xa1,
    pane_title = 0xa2,
    pane_matches = 0xa3,
    history_pruned = 0xa4,
    history_output = 0xa5,
    history_stats_result = 0xa6,
    pane_focus_command = 0xa7,
    pane_focus_result = 0xa8,
    command_suggestion = 0xa9,
    pane_progress = 0xaa,
    client_list = 0xad,
    client_command = 0xae,
    client_command_result = 0xaf,
    editor_opened = 0xb2,
    path_results = 0xb3,
    worktree_registered = 0xb4,
    limit_list = 0xb5,
    execution_reply = 0xb6,
  };

  struct RequestRuntimeState {
    std::uint64_t client_identity;
    bool interactive = false;

    void validate() const {
      if (client_identity == 0) {
        throw std::runtime_error{"Invalid client identity"};
      }
    }
  };

  template <>
  struct MessageSchema<RequestRuntimeState>
      : Schema<Direction::client, ClientTag::request_runtime_state,
               Field<&RequestRuntimeState::client_identity, u64, "client_identity">,
               Field<&RequestRuntimeState::interactive, BoolByte, "interactive">> {
    static constexpr const char *name = "RequestRuntimeState";
  };

  struct SystemMetrics {
    std::uint64_t revision;
    std::uint8_t cpu_percent;
    std::uint16_t memory_used_decigib;
    bool has_battery;
    std::uint8_t battery_percent;
    std::uint16_t cpu_count;
    std::uint16_t memory_total_decigib;

    void validate() const {
      if (revision == 0 || cpu_percent > 100) {
        throw std::runtime_error{"Invalid system metrics"};
      }

      if ((has_battery && battery_percent > 100) || (!has_battery && battery_percent != 0)) {
        throw std::runtime_error{"Invalid battery metrics"};
      }
    }
  };

  template <>
  struct MessageSchema<SystemMetrics>
      : Schema<Direction::server, ServerTag::system_metrics,
               Field<&SystemMetrics::revision, u64, "revision">,
               Field<&SystemMetrics::cpu_percent, u8, "cpu_percent">,
               Field<&SystemMetrics::memory_used_decigib, u16, "memory_used_decigib">,
               Field<&SystemMetrics::has_battery, BoolByte, "has_battery">,
               Field<&SystemMetrics::battery_percent, u8, "battery_percent">,
               Field<&SystemMetrics::cpu_count, u16, "cpu_count">,
               Field<&SystemMetrics::memory_total_decigib, u16, "memory_total_decigib">> {
    static constexpr const char *name = "SystemMetrics";
  };

  // | `TerminalSize` | `cols:u16, rows:u16, cell_width_px:u16, cell_height_px:u16` |
  struct TerminalSize {
    std::uint16_t cols;
    std::uint16_t rows;
    std::uint16_t cell_width_px;
    std::uint16_t cell_height_px;
  };

  template <>
  struct MessageSchema<TerminalSize>
      : Serializer<Field<&TerminalSize::cols, u16, "cols">, Field<&TerminalSize::rows, u16, "rows">,
                   Field<&TerminalSize::cell_width_px, u16, "cell_width_px">,
                   Field<&TerminalSize::cell_height_px, u16, "cell_height_px">> {
    static constexpr const char *name = "TerminalSize";
  };

  enum class EnvironmentMode : Byte {
    inherit_runtime = 0,
    replace = 1,
  };

  enum class HistoryScope : Byte {
    global = 0,
    cwd = 1,
    workspace = 2,
    pane = 3,
  };

  enum class WorktreeOrigin : Byte {
    telar = 0,
    external = 1,
  };

  enum class WorktreeState : Byte {
    active = 0,
    integrated = 1,
    gone = 2,
  };

  enum class CommandState : Byte {
    none = 0,
    running = 1,
    exited = 2,
  };

  enum class HistoryStatus : Byte {
    completed = 0,
    interrupted = 1,
    running = 2,
  };

  enum class HistoryAuthor : Byte {
    human = 0,
    agent = 1,
  };

  enum class HistoryOrigin : Byte {
    pane = 0,
    hook = 1,
    plugin = 2,
  };

  enum class AgentTitleSource : Byte {
    telar = 0,
    generated = 1,
    manual = 2,
    terminal = 3,
    agent = 4,
  };

  enum class AgentTitleState : Byte {
    placeholder = 0,
    pending = 1,
    ready = 2,
    failed = 3,
  };

  enum class AgentProvider : Byte {
    unknown = 0,
    claude = 1,
    codex = 2,
    pi = 3,
    cursor = 4,
    opencode = 5,
  };

  inline constexpr Byte first_custom_agent_provider = 6;
  inline constexpr Byte max_agent_provider_index = 32;

  enum class AgentAttachmentMarkers : Byte {
    none = 0,
    ordered = 1,
    stable_number = 2,
    pasted_path = 3,
  };

  enum class AgentStatus : Byte {
    unknown = 0,
    working = 1,
    blocked = 2,
    ready = 3,
    failed = 4,
    done = 5,
  };

  enum class AgentBlockedReason : Byte {
    none = 0,
    permission = 1,
    question = 2,
    plan = 3,
    other = 4,
  };

  enum class AgentSource : Byte {
    screen = 1,
    foreground_process = 2,
    lifecycle_report = 3,
  };

  enum class AgentAuthority : Byte {
    candidate = 0,
    active = 1,
    obscured = 2,
    resumed = 3,
    exited = 4,
    stale = 5,
  };

  enum class ClientAction : Byte {
    workspace_select = 0,
    tab_create = 1,
    tab_select = 2,
    tab_next = 3,
    tab_previous = 4,
    pane_create = 5,
    pane_split = 6,
    pane_close = 7,
    pane_focus = 8,
    pane_resize = 9,
    pane_fullscreen = 10,
    pane_scroll = 11,
    sidebar_get = 12,
    sidebar_show = 13,
    sidebar_hide = 14,
    sidebar_resize = 15,
    workspace_list_expand = 16,
    workspace_list_collapse = 17,
    client_open_goto = 18,
    client_open_history = 19,
    client_copy_mode = 20,
    notification_dismiss = 21,
    client_open_link = 22,
    client_clipboard_copy = 23,
    pane_copy = 24,
    layout_get = 25,
    layout_apply = 26,
    config_reload = 27,
    config_show = 28,
    plugin_list = 29,
    plugin_get = 30,
    plugin_enable = 31,
    plugin_disable = 32,
    plugin_run = 33,
  };

  enum class ClientCommandStatus : Byte {
    request = 0,
    applied = 1,
    admitted = 2,
    failed = 3,
  };

  enum class ClientLayoutAxis : Byte {
    horizontal = 0,
    vertical = 1,
  };

  enum class NotificationLevel : Byte {
    info = 0,
    success = 1,
    warning = 2,
    failure = 3,
  };

  enum class PathKind : Byte {
    file = 0,
    directory = 1,
  };

  enum class LimitOrigin : Byte {
    runtime = 0,
    client = 1,
  };

  enum class ImageFormat : Byte {
    rgb = 24,
    rgba = 32,
  };

  // Matches core.PlacementLocation: anchored at a cell, or drawn wherever
  // Kitty Unicode placeholder cells name the image.
  enum class PlacementLocation : Byte {
    cell = 0,
    placeholders = 1,
  };

  // These are value types, not packed wire layouts. String and span members
  // borrow storage that must outlive the value; codecs derive lengths/counts.
  struct PaneTarget {
    enum class Kind : Byte {
      default_target = 0,
      pane = 1,
      workspace = 2,
    };

    Kind kind = Kind::default_target;
    std::uint64_t id = 0;
  };

  struct WorkspaceLocation {
    enum class Kind : Byte {
      workspace = 0,
      worktree = 1,
    };

    Kind kind = Kind::workspace;
    std::uint64_t id = 0;
  };

  struct TabLocation {
    WorkspaceLocation workspace{};
    std::uint64_t tab_id = 0;
  };

  // The containing message's HistoryScope selects the path or pane ID;
  // global contributes no bytes and cwd/workspace both use the path.
  using HistoryScopeValue = std::variant<std::monostate, std::string_view, std::uint64_t>;

  struct ClientRoute {
    std::uint64_t id = 0;
    std::uint64_t generation = 0;
  };

  struct CoordinatorReference {
    std::array<Byte, 16> session_id{};
    std::uint64_t pane_id = 0;
    std::uint64_t pane_generation = 0;
  };

  struct EnvironmentEntry {
    std::string_view name{};
    std::string_view value{};
  };

  struct Launch {
    std::string_view cwd{};
    std::uint64_t cwd_source = 0;
    std::span<const std::string_view> arguments{};
    EnvironmentMode environment_mode = EnvironmentMode::inherit_runtime;
    std::span<const EnvironmentEntry> environment{};
  };

  struct PaneForeground {
    std::uint64_t pane_id = 0;
    std::string_view name{};
  };

  struct TabDescriptor {
    std::uint64_t tab_id = 0;
    std::uint16_t position = 0;
    std::uint16_t pane_count = 0;
    std::string_view label{};
    std::span<const PaneForeground> foregrounds{};
  };

  struct WorkspaceListEntry {
    std::uint64_t workspace = 0;
    std::string_view name{};
    std::string_view path{};
    std::uint16_t tab_count = 0;
    std::string_view branch{};
    bool dirty = false;
  };

  struct WorktreeListEntry {
    std::uint64_t worktree = 0;
    std::uint64_t source = 0;
    std::optional<std::uint64_t> workspace{};
    std::optional<std::uint64_t> created_by{};
    WorktreeOrigin origin = WorktreeOrigin::telar;
    WorktreeState state = WorktreeState::active;
    std::string_view path{};
    std::string_view branch{};
    std::string_view base{};
    std::string_view title{};
    std::string_view brief{};
    std::string_view dispatched_from{};
    std::optional<CoordinatorReference> coordinator{};
    std::uint32_t diff_added = 0;
    std::uint32_t diff_removed = 0;
    std::uint32_t diff_files = 0;
    std::uint32_t commits_ahead = 0;
    std::string_view command_label{};
    CommandState command_state = CommandState::none;
    std::int32_t command_exit = 0;
  };

  struct HistoryEntry {
    std::uint64_t id = 0;
    std::uint64_t pane_id = 0;
    std::int64_t started_at_ms = 0;
    std::int64_t duration_ns = 0;
    std::optional<std::int32_t> exit_code{};
    HistoryStatus status = HistoryStatus::completed;
    HistoryAuthor author = HistoryAuthor::human;
    HistoryOrigin origin = HistoryOrigin::pane;
    std::string_view provider{};
    std::string_view command{};
    std::string_view cwd{};
    std::string_view workspace_path{};
    bool command_truncated = false;
  };

  struct AgentSnapshotEntry {
    std::uint64_t pane_id = 0;
    std::uint64_t pane_generation = 0;
    TabLocation location{};
    std::uint16_t pane_index = 0;
    std::uint32_t process_id = 0;
    std::array<Byte, 16> session_id{};
    std::string_view workspace_label{};
    std::string_view tab_label{};
    std::string_view session_title{};
    AgentTitleSource title_source = AgentTitleSource::telar;
    AgentTitleState title_state = AgentTitleState::placeholder;
    std::string_view cwd_label{};
    AgentProvider provider = AgentProvider::unknown;
    std::string_view provider_name{};
    std::string_view display_name{};
    std::string_view icon{};
    AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
    AgentStatus status = AgentStatus::unknown;
    AgentBlockedReason blocked_reason = AgentBlockedReason::none;
    std::string_view last_event{};
    std::uint32_t status_age_s = 0;
    AgentSource source = AgentSource::screen;
    AgentAuthority authority = AgentAuthority::candidate;
    Byte confidence = 0;
    std::uint64_t sequence = 0;
    std::int64_t observed_at_ms = 0;
    std::int64_t expires_at_ms = 0;
    std::uint64_t work_tree = 0;
    std::string_view final_message{};
    std::uint16_t plan_done = 0;
    std::uint16_t plan_total = 0;
    std::string_view plan_step{};
  };

  struct ClientDescriptor {
    std::uint64_t id = 0;
    std::uint64_t generation = 0;
    std::uint64_t identity = 0;
    std::uint16_t attachments = 0;
    std::uint64_t last_input_pane = 0;
    std::uint64_t last_input_sequence = 0;
  };

  struct ClientCommand {
    std::uint64_t request_id = 0;
    ClientRoute route{};
    ClientAction action = ClientAction::workspace_select;
    ClientCommandStatus status = ClientCommandStatus::request;
    std::uint64_t target_id = 0;
    std::int64_t value = 0;
    std::string_view text{};
  };

  struct ClientLayoutPane {
    std::uint64_t pane_id = 0;
  };

  struct ClientLayoutSplit {
    ClientLayoutAxis axis = ClientLayoutAxis::horizontal;
    std::uint16_t ratio = 0;
  };

  using ClientLayoutNode = std::variant<ClientLayoutPane, ClientLayoutSplit>;

  struct ClientTabLayout {
    TabLocation location{};
    std::uint64_t focused_pane = 0;
    bool fullscreen = false;
    bool workspace_active = false;
    std::span<const ClientLayoutNode> nodes{};
  };

  struct NotificationTarget {
    enum class Kind : Byte {
      none = 0,
      pane = 1,
      tab = 2,
      workspace = 3,
    };

    Kind kind = Kind::none;
    std::uint64_t id = 0;
  };

  inline constexpr std::uint32_t default_notification_duration_ms = 4000;

  struct NotificationBody {
    NotificationLevel level = NotificationLevel::info;
    std::uint32_t duration_ms = default_notification_duration_ms;
    NotificationTarget target{};
    std::string_view title{};
    std::string_view message{};
    std::string_view link{};
  };

  struct PathMatch {
    std::string_view path{};
    PathKind kind = PathKind::file;
    std::span<const std::uint16_t> positions{};
  };

  struct LimitReach {
    std::string_view name{};
    std::string_view noun{};
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested{};
    std::string_view route{};
  };

  struct LimitListEntry {
    LimitReach reach{};
    LimitOrigin origin = LimitOrigin::runtime;
    std::uint64_t hits = 0;
    std::int64_t last_ms = 0;
  };

  struct GraphicsHeader {
    std::uint64_t pane_id = 0;
    std::uint64_t revision = 0;
  };

  struct ImageKey {
    std::uint32_t image_id = 0;
    std::uint64_t generation = 0;
  };

  struct ImageDescription {
    ImageKey key{};
    ImageFormat format = ImageFormat::rgb;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint64_t byte_len = 0;
  };

  struct GraphicsPlacement {
    ImageKey key{};
    std::uint64_t virtual_id = 0;
    std::uint32_t placement_id = 0;
    std::int32_t x = 0;
    std::int32_t y = 0;
    std::uint32_t source_x = 0;
    std::uint32_t source_y = 0;
    std::uint32_t source_width = 0;
    std::uint32_t source_height = 0;
    std::uint32_t columns = 0;
    std::uint32_t rows = 0;
    std::uint32_t offset_x = 0;
    std::uint32_t offset_y = 0;
    std::int32_t z_index = 0;
    PlacementLocation location = PlacementLocation::cell;
  };

  template <> struct BodySchema<TerminalSize> : MessageSchema<TerminalSize> {
    // Matches frame_support.max_cell_count and its worst-case metadata budget.
    static constexpr std::uint32_t max_cells = 130359;

    static void validate(const TerminalSize &value) {
      const auto cells = static_cast<std::uint32_t>(value.cols) * value.rows;
      if (value.cols == 0 || value.rows == 0 || cells > max_cells) {
        throw EncodingError{"Invalid terminal dimensions"};
      }
    }
  };

  template <typename Value, Byte Maximum> struct TaggedIdSerializer {
    static constexpr std::size_t min_width = 1;
    static constexpr bool fixed_size = false;
    using KindCodec = EnumByte<typename Value::Kind, Maximum>;

    static std::size_t encodedSize(const Value &value) {
      KindCodec::validate(value.kind);
      if (static_cast<Byte>(value.kind) == 0) {
        return 1;
      }
      NonzeroU64::validate(value.id);

      return 9;
    }

    static void encodeBody(const Value &value, std::span<Byte> &output) {
      KindCodec::encode(value.kind, output);
      if (static_cast<Byte>(value.kind) != 0) {
        NonzeroU64::encode(value.id, output);
      }
    }

    static void decodeBody(std::span<const Byte> &input, Value &value, DecodeStorage &) {
      value.kind = KindCodec::decode(input);
      value.id = static_cast<Byte>(value.kind) == 0 ? 0 : NonzeroU64::decode(input);
    }
  };

  template <> struct BodySchema<PaneTarget> : TaggedIdSerializer<PaneTarget, 2> {};

  template <>
  struct BodySchema<WorkspaceLocation>
      : Serializer<Field<&WorkspaceLocation::kind, EnumByte<WorkspaceLocation::Kind, 1>, "kind">,
                   Field<&WorkspaceLocation::id, NonzeroU64, "id">> {};

  template <>
  struct BodySchema<TabLocation>
      : Serializer<Field<&TabLocation::workspace, ValueCodec<WorkspaceLocation>, "workspace">,
                   Field<&TabLocation::tab_id, NonzeroU64, "tab_id">> {};

  // HistoryScope is supplied by the containing message, never written twice.
  template <> struct BodySchema<HistoryScopeValue> {
    static constexpr std::size_t min_width = 0;
    static constexpr bool fixed_size = false;
    using PathCodec = Text16<4096, false>;

    static std::size_t encodedSize(const HistoryScopeValue &value, HistoryScope scope) {
      EnumByte<HistoryScope, 3>::validate(scope);
      switch (scope) {
      case HistoryScope::global:
        if (std::holds_alternative<std::monostate>(value)) {
          return 0;
        }
        break;
      case HistoryScope::cwd:
      case HistoryScope::workspace:
        if (const auto *path = std::get_if<std::string_view>(&value)) {
          return PathCodec::encodedSize(*path);
        }
        break;
      case HistoryScope::pane:
        if (const auto *id = std::get_if<std::uint64_t>(&value)) {
          NonzeroU64::validate(*id);
          return 8;
        }
        break;
      }

      throw EncodingError{"History scope and value do not match"};
    }

    static void encodeBody(const HistoryScopeValue &value, std::span<Byte> &output,
                           HistoryScope scope) {
      (void)encodedSize(value, scope);
      switch (scope) {
      case HistoryScope::global:
        break;
      case HistoryScope::cwd:
      case HistoryScope::workspace:
        PathCodec::encode(std::get<std::string_view>(value), output);
        break;
      case HistoryScope::pane:
        NonzeroU64::encode(std::get<std::uint64_t>(value), output);
        break;
      }
    }

    static void decodeBody(std::span<const Byte> &input, HistoryScopeValue &value, DecodeStorage &,
                           HistoryScope scope) {
      EnumByte<HistoryScope, 3>::validate(scope);
      switch (scope) {
      case HistoryScope::global:
        value = std::monostate{};
        break;
      case HistoryScope::cwd:
      case HistoryScope::workspace:
        value = PathCodec::decode(input);
        break;
      case HistoryScope::pane:
        value = NonzeroU64::decode(input);
        break;
      }
    }
  };

  template <>
  struct BodySchema<ClientRoute>
      : Serializer<Field<&ClientRoute::id, NonzeroU64, "id">,
                   Field<&ClientRoute::generation, NonzeroU64, "generation">> {};

  template <>
  struct BodySchema<CoordinatorReference>
      : Serializer<Field<&CoordinatorReference::session_id, FixedBytes<16>, "session_id">,
                   Field<&CoordinatorReference::pane_id, NonzeroU64, "pane_id">,
                   Field<&CoordinatorReference::pane_generation, NonzeroU64, "pane_generation">> {
    static void validate(const CoordinatorReference &value) {
      for (const auto byte : value.session_id) {
        if (byte != 0) {
          return;
        }
      }

      throw EncodingError{"Missing coordinator session identity"};
    }
  };

  template <>
  struct BodySchema<EnvironmentEntry>
      : Serializer<Field<&EnvironmentEntry::name, Text16<65535, false>, "name">,
                   Field<&EnvironmentEntry::value, Text32<512 * 1024>, "value">> {
    static void validate(const EnvironmentEntry &value) {
      if (value.name.find('=') != std::string_view::npos) {
        throw EncodingError{"Invalid environment name"};
      }
    }
  };

  template <>
  struct BodySchema<Launch>
      : Serializer<
            Field<&Launch::cwd, Text16<4096, false>, "cwd">,
            Field<&Launch::cwd_source, u64, "cwd_source">,
            Field<&Launch::arguments, CountedSpan<u16, Text16<65535>, 64, 1>, "arguments">,
            Field<&Launch::environment_mode, EnumByte<EnvironmentMode, 1>, "environment_mode">,
            Field<&Launch::environment, CountedSpan<u16, ValueCodec<EnvironmentEntry>, 256>,
                  "environment">> {
    static void validate(const Launch &value) {
      if (value.arguments.empty() || value.arguments.size() > 64 ||
          value.arguments.front().empty() || value.environment.size() > 256) {
        throw EncodingError{"Invalid launch collections"};
      }

      std::size_t arguments = 0;
      for (const auto argument : value.arguments) {
        arguments = checkedWireSize(arguments, argument.size());
      }
      std::size_t environment = 0;
      for (const auto &entry : value.environment) {
        environment = checkedWireSize(environment, entry.name.size());
        environment = checkedWireSize(environment, entry.value.size());
      }
      if (arguments > 128 * 1024 || environment > 512 * 1024) {
        throw EncodingError{"Launch byte budget exceeded"};
      }
    }
  };

  template <>
  struct BodySchema<PaneForeground>
      : Serializer<Field<&PaneForeground::pane_id, NonzeroU64, "pane_id">,
                   Field<&PaneForeground::name, Text16<48, false>, "name">> {};

  template <>
  struct BodySchema<TabDescriptor>
      : Serializer<Field<&TabDescriptor::tab_id, NonzeroU64, "tab_id">,
                   Field<&TabDescriptor::position, u16, "position">,
                   Field<&TabDescriptor::pane_count, BoundedInteger<u16, 0, 64>, "pane_count">,
                   Field<&TabDescriptor::label, DisplayText16<128>, "label">,
                   Field<&TabDescriptor::foregrounds,
                         CountedSpan<u16, ValueCodec<PaneForeground>, 64>, "foregrounds">> {
    static void validate(const TabDescriptor &value) {
      if (value.foregrounds.size() > value.pane_count) {
        throw EncodingError{"Too many foreground entries"};
      }
      for (std::size_t i = 0; i < value.foregrounds.size(); ++i) {
        for (std::size_t j = 0; j < i; ++j) {
          if (value.foregrounds[i].pane_id == value.foregrounds[j].pane_id) {
            throw EncodingError{"Duplicate foreground pane"};
          }
        }
      }
    }
  };

  template <>
  struct BodySchema<WorkspaceListEntry>
      : Serializer<Field<&WorkspaceListEntry::workspace, NonzeroU64, "workspace">,
                   Field<&WorkspaceListEntry::name, Text16<256, false>, "name">,
                   Field<&WorkspaceListEntry::path, Text16<4096, false>, "path">,
                   Field<&WorkspaceListEntry::tab_count, BoundedInteger<u16, 0, 64>, "tab_count">,
                   Field<&WorkspaceListEntry::branch, Text16<200>, "branch">,
                   Field<&WorkspaceListEntry::dirty, BoolByte, "dirty">> {};

  template <>
  struct BodySchema<WorktreeListEntry>
      : Serializer<
            Field<&WorktreeListEntry::worktree, NonzeroU64, "worktree">,
            Field<&WorktreeListEntry::source, NonzeroU64, "source">,
            Field<&WorktreeListEntry::workspace, OptionalValue<NonzeroU64>, "workspace">,
            Field<&WorktreeListEntry::created_by, OptionalValue<NonzeroU64>, "created_by">,
            Field<&WorktreeListEntry::origin, EnumByte<WorktreeOrigin, 1>, "origin">,
            Field<&WorktreeListEntry::state, EnumByte<WorktreeState, 2>, "state">,
            Field<&WorktreeListEntry::path, Text16<4096, false>, "path">,
            Field<&WorktreeListEntry::branch, DisplayText16<200, false>, "branch">,
            Field<&WorktreeListEntry::base, DisplayText16<200>, "base">,
            Field<&WorktreeListEntry::title, DisplayText16<96>, "title">,
            Field<&WorktreeListEntry::brief, MessageText16<512>, "brief">,
            Field<&WorktreeListEntry::dispatched_from, DisplayText16<32>, "dispatched_from">,
            Field<&WorktreeListEntry::coordinator, OptionalValue<ValueCodec<CoordinatorReference>>,
                  "coordinator">,
            Field<&WorktreeListEntry::diff_added, u32, "diff_added">,
            Field<&WorktreeListEntry::diff_removed, u32, "diff_removed">,
            Field<&WorktreeListEntry::diff_files, u32, "diff_files">,
            Field<&WorktreeListEntry::commits_ahead, u32, "commits_ahead">,
            Field<&WorktreeListEntry::command_label, DisplayText16<48>, "command_label">,
            Field<&WorktreeListEntry::command_state, EnumByte<CommandState, 2>, "command_state">,
            Field<&WorktreeListEntry::command_exit, i32, "command_exit">> {
    static void validate(const WorktreeListEntry &value) {
      if (value.path.empty() || value.path.front() != '/') {
        throw EncodingError{"Worktree path must be absolute"};
      }
    }
  };

  template <>
  struct BodySchema<HistoryEntry>
      : Serializer<Field<&HistoryEntry::id, NonzeroU64, "id">,
                   Field<&HistoryEntry::pane_id, NonzeroU64, "pane_id">,
                   Field<&HistoryEntry::started_at_ms, i64, "started_at_ms">,
                   Field<&HistoryEntry::duration_ns, i64, "duration_ns">,
                   Field<&HistoryEntry::exit_code, OptionalValue<i32>, "exit_code">,
                   Field<&HistoryEntry::status, EnumByte<HistoryStatus, 2>, "status">,
                   Field<&HistoryEntry::author, EnumByte<HistoryAuthor, 1>, "author">,
                   Field<&HistoryEntry::origin, EnumByte<HistoryOrigin, 2>, "origin">,
                   Field<&HistoryEntry::provider, Text16<64>, "provider">,
                   Field<&HistoryEntry::command, Text32<64 * 1024, false>, "command">,
                   Field<&HistoryEntry::cwd, Text16<4096>, "cwd">,
                   Field<&HistoryEntry::workspace_path, Text16<4096>, "workspace_path">,
                   Field<&HistoryEntry::command_truncated, BoolByte, "command_truncated">> {};

  template <>
  struct BodySchema<AgentSnapshotEntry>
      : Serializer<
            Field<&AgentSnapshotEntry::pane_id, NonzeroU64, "pane_id">,
            Field<&AgentSnapshotEntry::pane_generation, NonzeroU64, "pane_generation">,
            Field<&AgentSnapshotEntry::location, ValueCodec<TabLocation>, "location">,
            Field<&AgentSnapshotEntry::pane_index, BoundedInteger<u16, 1>, "pane_index">,
            Field<&AgentSnapshotEntry::process_id, u32, "process_id">,
            Field<&AgentSnapshotEntry::session_id, FixedBytes<16>, "session_id">,
            Field<&AgentSnapshotEntry::workspace_label, DisplayText16<48>, "workspace_label">,
            Field<&AgentSnapshotEntry::tab_label, DisplayText16<128>, "tab_label">,
            Field<&AgentSnapshotEntry::session_title, DisplayText16<96>, "session_title">,
            Field<&AgentSnapshotEntry::title_source, EnumByte<AgentTitleSource, 4>, "title_source">,
            Field<&AgentSnapshotEntry::title_state, EnumByte<AgentTitleState, 3>, "title_state">,
            Field<&AgentSnapshotEntry::cwd_label, DisplayText16<48>, "cwd_label">,
            Field<&AgentSnapshotEntry::provider, EnumByte<AgentProvider, max_agent_provider_index>,
                  "provider">,
            Field<&AgentSnapshotEntry::provider_name, DisplayText16<32>, "provider_name">,
            Field<&AgentSnapshotEntry::display_name, DisplayText16<32>, "display_name">,
            Field<&AgentSnapshotEntry::icon, DisplayText16<8>, "icon">,
            Field<&AgentSnapshotEntry::attachments, EnumByte<AgentAttachmentMarkers, 3>,
                  "attachments">,
            Field<&AgentSnapshotEntry::status, EnumByte<AgentStatus, 5>, "status">,
            Field<&AgentSnapshotEntry::blocked_reason, EnumByte<AgentBlockedReason, 4>,
                  "blocked_reason">,
            Field<&AgentSnapshotEntry::last_event, DisplayText16<96>, "last_event">,
            Field<&AgentSnapshotEntry::status_age_s, u32, "status_age_s">,
            Field<&AgentSnapshotEntry::source, EnumByte<AgentSource, 3, 1>, "source">,
            Field<&AgentSnapshotEntry::authority, EnumByte<AgentAuthority, 5>, "authority">,
            Field<&AgentSnapshotEntry::confidence, BoundedInteger<u8, 0, 100>, "confidence">,
            Field<&AgentSnapshotEntry::sequence, NonzeroU64, "sequence">,
            Field<&AgentSnapshotEntry::observed_at_ms, i64, "observed_at_ms">,
            Field<&AgentSnapshotEntry::expires_at_ms, i64, "expires_at_ms">,
            Field<&AgentSnapshotEntry::work_tree, u64, "work_tree">,
            Field<&AgentSnapshotEntry::final_message, MessageText16<2048>, "final_message">,
            Field<&AgentSnapshotEntry::plan_done, u16, "plan_done">,
            Field<&AgentSnapshotEntry::plan_total, u16, "plan_total">,
            Field<&AgentSnapshotEntry::plan_step, DisplayText16<96>, "plan_step">> {
    static void validate(const AgentSnapshotEntry &value) {
      if (value.expires_at_ms < value.observed_at_ms || value.plan_done > value.plan_total ||
          (value.status != AgentStatus::blocked &&
           value.blocked_reason != AgentBlockedReason::none)) {
        throw EncodingError{"Invalid agent state"};
      }
      switch (value.title_source) {
      case AgentTitleSource::telar:
        if (value.title_state == AgentTitleState::ready) {
          throw EncodingError{"Invalid agent title"};
        }
        break;
      case AgentTitleSource::generated:
      case AgentTitleSource::manual:
      case AgentTitleSource::agent:
        if (value.title_state != AgentTitleState::ready || value.session_title.empty()) {
          throw EncodingError{"Invalid agent title"};
        }
        break;
      case AgentTitleSource::terminal:
        if (value.session_title.empty()) {
          throw EncodingError{"Invalid agent title"};
        }
        break;
      }
    }
  };

  template <>
  struct BodySchema<ClientDescriptor>
      : Serializer<Field<&ClientDescriptor::id, NonzeroU64, "id">,
                   Field<&ClientDescriptor::generation, NonzeroU64, "generation">,
                   Field<&ClientDescriptor::identity, NonzeroU64, "identity">,
                   Field<&ClientDescriptor::attachments, u16, "attachments">,
                   Field<&ClientDescriptor::last_input_pane, u64, "last_input_pane">,
                   Field<&ClientDescriptor::last_input_sequence, u64, "last_input_sequence">> {};

  template <>
  struct BodySchema<ClientCommand>
      : Serializer<Field<&ClientCommand::request_id, NonzeroU64, "request_id">,
                   Field<&ClientCommand::route, ValueCodec<ClientRoute>, "route">,
                   Field<&ClientCommand::action, EnumByte<ClientAction, 33>, "action">,
                   Field<&ClientCommand::status, EnumByte<ClientCommandStatus, 3>, "status">,
                   Field<&ClientCommand::target_id, u64, "target_id">,
                   Field<&ClientCommand::value, i64, "value">,
                   Field<&ClientCommand::text, Utf8Text16<4096>, "text">> {};

  template <>
  struct BodySchema<ClientLayoutPane>
      : Serializer<Field<&ClientLayoutPane::pane_id, NonzeroU64, "pane_id">> {};

  template <>
  struct BodySchema<ClientLayoutSplit>
      : Serializer<Field<&ClientLayoutSplit::axis, EnumByte<ClientLayoutAxis, 1>, "axis">,
                   Field<&ClientLayoutSplit::ratio, BoundedInteger<u16, 1000, 9000>, "ratio">> {};

  template <> struct BodySchema<ClientLayoutNode> {
    static constexpr std::size_t min_width = 4;
    static constexpr bool fixed_size = false;

    static std::size_t encodedSize(const ClientLayoutNode &value) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&value)) {
        return 1 + ValueCodec<ClientLayoutPane>::encodedSize(*pane);
      }
      if (const auto *split = std::get_if<ClientLayoutSplit>(&value)) {
        return 1 + ValueCodec<ClientLayoutSplit>::encodedSize(*split);
      }

      throw EncodingError{"Invalid layout node"};
    }

    static void encodeBody(const ClientLayoutNode &value, std::span<Byte> &output) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&value)) {
        u8::encode(0, output);
        ValueCodec<ClientLayoutPane>::encode(*pane, output);
      } else if (const auto *split = std::get_if<ClientLayoutSplit>(&value)) {
        u8::encode(1, output);
        ValueCodec<ClientLayoutSplit>::encode(*split, output);
      } else {
        throw EncodingError{"Invalid layout node"};
      }
    }

    static void decodeBody(std::span<const Byte> &input, ClientLayoutNode &value,
                           DecodeStorage &storage) {
      switch (u8::decode(input)) {
      case 0:
        value = ValueCodec<ClientLayoutPane>::decode(input, storage);
        break;
      case 1:
        value = ValueCodec<ClientLayoutSplit>::decode(input, storage);
        break;
      default:
        throw EncodingError{"Unknown layout node tag"};
      }
    }
  };

  template <>
  struct BodySchema<ClientTabLayout>
      : Serializer<Field<&ClientTabLayout::location, ValueCodec<TabLocation>, "location">,
                   Field<&ClientTabLayout::focused_pane, NonzeroU64, "focused_pane">,
                   Field<&ClientTabLayout::fullscreen, BoolByte, "fullscreen">,
                   Field<&ClientTabLayout::workspace_active, BoolByte, "workspace_active">,
                   Field<&ClientTabLayout::nodes,
                         CountedSpan<u16, ValueCodec<ClientLayoutNode>, 127, 1>, "nodes">> {
    static void validate(const ClientTabLayout &value) {
      if (value.nodes.empty() || value.nodes.size() > 127) {
        throw EncodingError{"Invalid layout node count"};
      }

      std::array<std::uint64_t, 64> panes{};
      std::size_t pane_count = 0;
      std::size_t pending = 1;
      bool focused = false;
      for (const auto &node : value.nodes) {
        if (pending == 0) {
          throw EncodingError{"Invalid layout tree"};
        }
        --pending;
        if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
          if (pane_count == panes.size()) {
            throw EncodingError{"Too many layout panes"};
          }
          for (std::size_t i = 0; i < pane_count; ++i) {
            if (panes[i] == pane->pane_id) {
              throw EncodingError{"Duplicate layout pane"};
            }
          }
          panes[pane_count++] = pane->pane_id;
          focused = focused || pane->pane_id == value.focused_pane;
        } else {
          pending += 2;
        }
      }
      if (pending != 0 || !focused) {
        throw EncodingError{"Invalid layout tree or focus"};
      }
    }
  };

  template <> struct BodySchema<NotificationTarget> : TaggedIdSerializer<NotificationTarget, 3> {};

  template <>
  struct BodySchema<NotificationBody>
      : Serializer<
            Field<&NotificationBody::level, EnumByte<NotificationLevel, 3>, "level">,
            Field<&NotificationBody::duration_ms, BoundedInteger<u32, 500, 60000>, "duration_ms">,
            Field<&NotificationBody::target, ValueCodec<NotificationTarget>, "target">,
            Field<&NotificationBody::title, DisplayText16<96, false>, "title">,
            Field<&NotificationBody::message, DisplayText16<512>, "message">,
            Field<&NotificationBody::link, Text16<1024>, "link">> {
    static void validate(const NotificationBody &value) {
      const auto link = value.link;
      if (link.empty()) {
        return;
      }
      if (!link.starts_with("https://")) {
        throw EncodingError{"Notification link must use HTTPS"};
      }
      for (const auto character : link) {
        const auto byte = static_cast<Byte>(character);
        if (byte <= 0x20 || byte >= 0x7f || byte == '\\') {
          throw EncodingError{"Invalid notification link"};
        }
      }

      const auto rest = link.substr(8);
      const auto host = rest.substr(0, rest.find_first_of("/?#"));
      if (host.empty() || host.front() == '.' || host.front() == '-' || host.back() == '.') {
        throw EncodingError{"Invalid notification host"};
      }
      for (const auto byte : host) {
        const auto alphanumeric = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                                  (byte >= '0' && byte <= '9');
        if (!alphanumeric && byte != '.' && byte != '-') {
          throw EncodingError{"Invalid notification host"};
        }
      }
    }
  };

  template <>
  struct BodySchema<PathMatch>
      : Serializer<Field<&PathMatch::path, DisplayText16<1024, false>, "path">,
                   Field<&PathMatch::kind, EnumByte<PathKind, 1>, "kind">,
                   Field<&PathMatch::positions, CountedSpan<u8, u16, 64>, "positions">> {
    static void validate(const PathMatch &value) {
      if (value.path.empty() || (value.kind == PathKind::directory) != (value.path.back() == '/')) {
        throw EncodingError{"Invalid path kind"};
      }
      std::size_t next = 0;
      for (const auto position : value.positions) {
        if (position < next || position >= value.path.size()) {
          throw EncodingError{"Invalid path match positions"};
        }
        next = static_cast<std::size_t>(position) + 1;
      }
    }
  };

  template <>
  struct BodySchema<LimitReach>
      : Serializer<Field<&LimitReach::name, Text16<64, false>, "name">,
                   Field<&LimitReach::noun, Text16<32>, "noun">,
                   Field<&LimitReach::value, u64, "value">,
                   Field<&LimitReach::requested, OptionalValue<u64>, "requested">,
                   Field<&LimitReach::route, Text16<32>, "route">> {

    static void validate(const LimitReach &value) {
      const auto alphanumeric = [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
               (byte >= '0' && byte <= '9');
      };

      for (const auto byte : value.name) {
        if (!alphanumeric(byte) && byte != '.' && byte != '_' && byte != '-') {
          throw EncodingError{"Invalid limit name"};
        }
      }

      for (const auto character : value.noun) {
        const auto byte = static_cast<Byte>(character);
        if (byte < 0x20 || byte >= 0x7f) {
          throw EncodingError{"Invalid limit noun"};
        }
      }

      for (const auto byte : value.route) {
        if (!alphanumeric(byte) && byte != '_') {
          throw EncodingError{"Invalid limit route"};
        }
      }
    }
  };

  template <>
  struct BodySchema<LimitListEntry>
      : Serializer<Field<&LimitListEntry::reach, ValueCodec<LimitReach>, "reach">,
                   Field<&LimitListEntry::origin, EnumByte<LimitOrigin, 1>, "origin">,
                   Field<&LimitListEntry::hits, u64, "hits">,
                   Field<&LimitListEntry::last_ms, i64, "last_ms">> {};

  template <>
  struct BodySchema<GraphicsHeader>
      : Serializer<Field<&GraphicsHeader::pane_id, NonzeroU64, "pane_id">,
                   Field<&GraphicsHeader::revision, NonzeroU64, "revision">> {};

  template <>
  struct BodySchema<ImageKey>
      : Serializer<Field<&ImageKey::image_id, BoundedInteger<u32, 1>, "image_id">,
                   Field<&ImageKey::generation, NonzeroU64, "generation">> {};

  template <>
  struct BodySchema<ImageDescription>
      : Serializer<
            Field<&ImageDescription::key, ValueCodec<ImageKey>, "key">,
            Field<&ImageDescription::format,
                  EnumChoiceByte<ImageFormat, ImageFormat::rgb, ImageFormat::rgba>, "format">,
            Field<&ImageDescription::width, BoundedInteger<u32, 1>, "width">,
            Field<&ImageDescription::height, BoundedInteger<u32, 1>, "height">,
            Field<&ImageDescription::byte_len, u64, "byte_len">> {

    static void validate(const ImageDescription &value) {
      const auto pixels = static_cast<std::uint64_t>(value.width) * value.height;
      const auto channels = value.format == ImageFormat::rgb ? 3u : 4u;
      constexpr std::uint64_t maximum = 256 * 1024 * 1024;

      if (pixels > maximum / channels || value.byte_len != pixels * channels) {
        throw EncodingError{"Invalid image byte length"};
      }
    }
  };

  template <>
  struct BodySchema<GraphicsPlacement>
      : Serializer<Field<&GraphicsPlacement::key, ValueCodec<ImageKey>, "key">,
                   Field<&GraphicsPlacement::virtual_id, NonzeroU64, "virtual_id">,
                   Field<&GraphicsPlacement::placement_id, u32, "placement_id">,
                   Field<&GraphicsPlacement::x, i32, "x">, Field<&GraphicsPlacement::y, i32, "y">,
                   Field<&GraphicsPlacement::source_x, u32, "source_x">,
                   Field<&GraphicsPlacement::source_y, u32, "source_y">,
                   Field<&GraphicsPlacement::source_width, u32, "source_width">,
                   Field<&GraphicsPlacement::source_height, u32, "source_height">,
                   Field<&GraphicsPlacement::columns, u32, "columns">,
                   Field<&GraphicsPlacement::rows, u32, "rows">,
                   Field<&GraphicsPlacement::offset_x, u32, "offset_x">,
                   Field<&GraphicsPlacement::offset_y, u32, "offset_y">,
                   Field<&GraphicsPlacement::z_index, i32, "z_index">,
                   Field<&GraphicsPlacement::location,
                         EnumChoiceByte<PlacementLocation, PlacementLocation::cell,
                                        PlacementLocation::placeholders>,
                         "location">> {};

  static_assert(BodySchema<TerminalSize>::payload_size == 8);
  static_assert(BodySchema<WorkspaceLocation>::payload_size == 9);
  static_assert(BodySchema<TabLocation>::payload_size == 17);
  static_assert(BodySchema<ClientRoute>::payload_size == 16);
  static_assert(BodySchema<CoordinatorReference>::payload_size == 32);
  static_assert(BodySchema<ClientDescriptor>::payload_size == 42);
  static_assert(BodySchema<GraphicsHeader>::payload_size == 16);
  static_assert(BodySchema<ImageKey>::payload_size == 12);
  static_assert(BodySchema<ImageDescription>::payload_size == 29);
  static_assert(BodySchema<GraphicsPlacement>::payload_size == 69);
  static_assert(MessageSchema<RequestRuntimeState>::payload_size == 10);
  static_assert(MessageSchema<SystemMetrics>::payload_size == 18);

}; // namespace telar
