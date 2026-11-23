#pragma once

#include "../codecs/telar_codec.hpp"
#include "../codecs/telar_value_codec.hpp"
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/ds/values.hpp"

#include <algorithm>
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
    read_pane_theme = 0x2d,
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
    hold_tab = 0x47,
    execution_request = 0x46,
    configure_pane_desktop = 0x48,
    complete_clipboard_desktop = 0x49,
    paste_pane_clipboard = 0x4a,
    read_runtime_clipboard = 0x4b,
    complete_words = 0x4c,
    request_command_spec = 0x4d,
    read_pane_rows = 0x4e,
    search_pane_rows = 0x4f,
    pane_command = 0x50,
    configure_shell_prompt = 0x51,
    query_monitor = 0x52,
    request_process_signal = 0x53,
    request_process_priority = 0x54,
    query_history_workspaces = 0x55,
    create_nvim_pane = 0x56,
    nvim_input = 0x57,
    nvim_paste = 0x58,
    nvim_mouse = 0x59,
    nvim_focus = 0x5a,
    nvim_prompt_reply = 0x5b,
    nvim_open = 0x5c,
    nvim_navigate = 0x5d,
    nvim_menu_select = 0x5e,
    find_text = 0x5f,
    nvim_buffers = 0x60,
    nvim_preview = 0x61,
    nvim_list = 0x62,
    nvim_configuration = 0x63,
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
    clipboard_desktop_request = 0xb7,
    clipboard_desktop_execute = 0xb8,
    clipboard_desktop_cancel = 0xb9,
    runtime_clipboard_chunk = 0xba,
    pane_list = 0xbb,
    pane_shell = 0xbc,
    pane_git = 0xbd,
    completion_words = 0xbe,
    pane_blocks = 0xbf,
    command_spec = 0xc0,
    pane_rows = 0xc1,
    pane_scrollback = 0xc2,
    pane_document = 0xc3,
    monitor_snapshot = 0xc4,
    pane_theme = 0xc5,
    history_workspaces = 0xc6,
    pane_kind_notice = 0xc7,
    nvim_grid = 0xc8,
    nvim_frame = 0xc9,
    nvim_cmdline = 0xca,
    nvim_popup_menu = 0xcb,
    nvim_message_list = 0xcc,
    nvim_tab_line = 0xcd,
    nvim_prompt = 0xce,
    nvim_navigated = 0xcf,
    text_results = 0xd0,
    nvim_pick = 0xd1,
    nvim_link = 0xd2,
  };

  struct RequestRuntimeState {
    std::uint64_t client_identity{};
    bool interactive = false;

    void validate() const;
  };

  struct SystemMetrics {
    std::uint64_t revision;
    std::uint8_t cpu_percent;
    std::uint16_t memory_used_decigib;
    bool has_battery;
    std::uint8_t battery_percent;
    std::uint16_t cpu_count;
    std::uint16_t memory_total_decigib;

    void validate() const;
  };

  template <>
  struct MessageSchema<TerminalSize>
      : Serializer<Field<&TerminalSize::cols, u16, "cols">, Field<&TerminalSize::rows, u16, "rows">, Field<&TerminalSize::cell_width_px, u16, "cell_width_px">, Field<&TerminalSize::cell_height_px, u16, "cell_height_px">> {
    static constexpr const char* name = "TerminalSize";
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
    last_custom = 32,
  };

  inline constexpr Byte first_custom_agent_provider = 6;
  inline constexpr Byte max_agent_provider_index = static_cast<Byte>(AgentProvider::last_custom);

  // The agents telar knows without a manifest, in the order of their values: the one list of them,
  // which the configuration, the hooks and the window walk. A built-in added to the enum joins it,
  // or the assertions below fail.
  inline constexpr ds::Array built_in_agent_providers{AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode};

  static_assert(built_in_agent_providers.size() + 1 == first_custom_agent_provider);
  static_assert(static_cast<Byte>(built_in_agent_providers.back()) + 1 == first_custom_agent_provider);

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

  // The name of each request, message, agent status and reason for an agent to wait, as `api schema`
  // and every command print it: the one place that spells them. Empty for a value that names none.
  // Each switch lists every enumerator, and here a missing one is an error: an enumerator added
  // without its name does not compile.
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wswitch"

  [[nodiscard]] constexpr std::string_view clientTagName(ClientTag tag) noexcept { // NOLINT(readability-function-size): one case per tag, in one switch, is what makes a tag without its name an error
    switch (tag) {
    case ClientTag::open_pane:
      return "open_pane";
    case ClientTag::pane_input:
      return "pane_input";
    case ClientTag::pane_resize:
      return "pane_resize";
    case ClientTag::frame_ack:
      return "frame_ack";
    case ClientTag::request_snapshot:
      return "request_snapshot";
    case ClientTag::detach_pane:
      return "detach_pane";
    case ClientTag::runtime_stop:
      return "runtime_stop";
    case ClientTag::request_tab_snapshot:
      return "request_tab_snapshot";
    case ClientTag::create_pane:
      return "create_pane";
    case ClientTag::close_pane:
      return "close_pane";
    case ClientTag::query_history:
      return "query_history";
    case ClientTag::request_workspace_snapshot:
      return "request_workspace_snapshot";
    case ClientTag::create_tab:
      return "create_tab";
    case ClientTag::rename_tab:
      return "rename_tab";
    case ClientTag::close_tab:
      return "close_tab";
    case ClientTag::move_tab:
      return "move_tab";
    case ClientTag::request_graphics_snapshot:
      return "request_graphics_snapshot";
    case ClientTag::graphics_credit:
      return "graphics_credit";
    case ClientTag::configure_graphics:
      return "configure_graphics";
    case ClientTag::request_runtime_state:
      return "request_runtime_state";
    case ClientTag::create_workspace:
      return "create_workspace";
    case ClientTag::rename_workspace:
      return "rename_workspace";
    case ClientTag::set_pane_viewport:
      return "set_pane_viewport";
    case ClientTag::copy_selection:
      return "copy_selection";
    case ClientTag::show_notification:
      return "show_notification";
    case ClientTag::update_client_layout:
      return "update_client_layout";
    case ClientTag::acknowledge_agent:
      return "acknowledge_agent";
    case ClientTag::query_agents:
      return "query_agents";
    case ClientTag::read_pane:
      return "read_pane";
    case ClientTag::send_pane_text:
      return "send_pane_text";
    case ClientTag::report_agent_session:
      return "report_agent_session";
    case ClientTag::report_agent:
      return "report_agent";
    case ClientTag::search_pane:
      return "search_pane";
    case ClientTag::import_history:
      return "import_history";
    case ClientTag::delete_history:
      return "delete_history";
    case ClientTag::prune_history:
      return "prune_history";
    case ClientTag::read_history_output:
      return "read_history_output";
    case ClientTag::history_stats:
      return "history_stats";
    case ClientTag::request_pane_focus:
      return "request_pane_focus";
    case ClientTag::complete_pane_focus:
      return "complete_pane_focus";
    case ClientTag::suggest_command:
      return "suggest_command";
    case ClientTag::report_agent_command:
      return "report_agent_command";
    case ClientTag::report_agent_title:
      return "report_agent_title";
    case ClientTag::configure_terminal_colors:
      return "configure_terminal_colors";
    case ClientTag::read_pane_theme:
      return "read_pane_theme";
    case ClientTag::query_clients:
      return "query_clients";
    case ClientTag::detach_client:
      return "detach_client";
    case ClientTag::request_client_command:
      return "request_client_command";
    case ClientTag::complete_client_command:
      return "complete_client_command";
    case ClientTag::open_editor:
      return "open_editor";
    case ClientTag::find_paths:
      return "find_paths";
    case ClientTag::register_worktree:
      return "register_worktree";
    case ClientTag::launch_worktree:
      return "launch_worktree";
    case ClientTag::forget_worktree:
      return "forget_worktree";
    case ClientTag::interrupt_agent:
      return "interrupt_agent";
    case ClientTag::report_agent_progress:
      return "report_agent_progress";
    case ClientTag::launch_tab:
      return "launch_tab";
    case ClientTag::verify_pane_descent:
      return "verify_pane_descent";
    case ClientTag::report_limit:
      return "report_limit";
    case ClientTag::query_limits:
      return "query_limits";
    case ClientTag::configure_frame_interval:
      return "configure_frame_interval";
    case ClientTag::hold_tab:
      return "hold_tab";
    case ClientTag::execution_request:
      return "execution_request";
    case ClientTag::configure_pane_desktop:
      return "configure_pane_desktop";
    case ClientTag::complete_clipboard_desktop:
      return "complete_clipboard_desktop";
    case ClientTag::paste_pane_clipboard:
      return "paste_pane_clipboard";
    case ClientTag::read_runtime_clipboard:
      return "read_runtime_clipboard";
    case ClientTag::complete_words:
      return "complete_words";
    case ClientTag::request_command_spec:
      return "request_command_spec";
    case ClientTag::read_pane_rows:
      return "read_pane_rows";
    case ClientTag::search_pane_rows:
      return "search_pane_rows";
    case ClientTag::pane_command:
      return "pane_command";
    case ClientTag::configure_shell_prompt:
      return "configure_shell_prompt";
    case ClientTag::query_monitor:
      return "query_monitor";
    case ClientTag::request_process_signal:
      return "request_process_signal";
    case ClientTag::request_process_priority:
      return "request_process_priority";
    case ClientTag::query_history_workspaces:
      return "query_history_workspaces";
    case ClientTag::create_nvim_pane:
      return "create_nvim_pane";
    case ClientTag::nvim_input:
      return "nvim_input";
    case ClientTag::nvim_paste:
      return "nvim_paste";
    case ClientTag::nvim_mouse:
      return "nvim_mouse";
    case ClientTag::nvim_focus:
      return "nvim_focus";
    case ClientTag::nvim_prompt_reply:
      return "nvim_prompt_reply";
    case ClientTag::nvim_open:
      return "nvim_open";
    case ClientTag::nvim_navigate:
      return "nvim_navigate";
    case ClientTag::nvim_menu_select:
      return "nvim_menu_select";
    case ClientTag::find_text:
      return "find_text";
    case ClientTag::nvim_buffers:
      return "nvim_buffers";
    case ClientTag::nvim_preview:
      return "nvim_preview";
    case ClientTag::nvim_list:
      return "nvim_list";
    case ClientTag::nvim_configuration:
      return "nvim_configuration";
    }

    return {};
  }

  [[nodiscard]] constexpr std::string_view serverTagName(ServerTag tag) noexcept { // NOLINT(readability-function-size): one case per tag, as clientTagName
    switch (tag) {
    case ServerTag::pane_opened:
      return "pane_opened";
    case ServerTag::pane_frame:
      return "pane_frame";
    case ServerTag::pane_exited:
      return "pane_exited";
    case ServerTag::request_failed:
      return "request_failed";
    case ServerTag::runtime_stopping:
      return "runtime_stopping";
    case ServerTag::tab_snapshot:
      return "tab_snapshot";
    case ServerTag::history_results:
      return "history_results";
    case ServerTag::workspace_snapshot:
      return "workspace_snapshot";
    case ServerTag::tab_created:
      return "tab_created";
    case ServerTag::tab_renamed:
      return "tab_renamed";
    case ServerTag::tab_closed:
      return "tab_closed";
    case ServerTag::tab_moved:
      return "tab_moved";
    case ServerTag::graphics_snapshot:
      return "graphics_snapshot";
    case ServerTag::graphics_image:
      return "graphics_image";
    case ServerTag::graphics_image_chunk:
      return "graphics_image_chunk";
    case ServerTag::graphics_placement:
      return "graphics_placement";
    case ServerTag::graphics_delete_image:
      return "graphics_delete_image";
    case ServerTag::graphics_delete_placement:
      return "graphics_delete_placement";
    case ServerTag::resync_required:
      return "resync_required";
    case ServerTag::graphics_shared_image:
      return "graphics_shared_image";
    case ServerTag::proxy_status:
      return "proxy_status";
    case ServerTag::agent_snapshot:
      return "agent_snapshot";
    case ServerTag::system_metrics:
      return "system_metrics";
    case ServerTag::workspace_list:
      return "workspace_list";
    case ServerTag::pane_cwd:
      return "pane_cwd";
    case ServerTag::pane_clipboard:
      return "pane_clipboard";
    case ServerTag::notification:
      return "notification";
    case ServerTag::notification_shown:
      return "notification_shown";
    case ServerTag::pane_foreground:
      return "pane_foreground";
    case ServerTag::agent_sound:
      return "agent_sound";
    case ServerTag::client_layout_snapshot:
      return "client_layout_snapshot";
    case ServerTag::pane_text:
      return "pane_text";
    case ServerTag::request_completed:
      return "request_completed";
    case ServerTag::pane_title:
      return "pane_title";
    case ServerTag::pane_matches:
      return "pane_matches";
    case ServerTag::history_pruned:
      return "history_pruned";
    case ServerTag::history_output:
      return "history_output";
    case ServerTag::history_stats_result:
      return "history_stats_result";
    case ServerTag::pane_focus_command:
      return "pane_focus_command";
    case ServerTag::pane_focus_result:
      return "pane_focus_result";
    case ServerTag::command_suggestion:
      return "command_suggestion";
    case ServerTag::pane_progress:
      return "pane_progress";
    case ServerTag::client_list:
      return "client_list";
    case ServerTag::client_command:
      return "client_command";
    case ServerTag::client_command_result:
      return "client_command_result";
    case ServerTag::editor_opened:
      return "editor_opened";
    case ServerTag::path_results:
      return "path_results";
    case ServerTag::worktree_registered:
      return "worktree_registered";
    case ServerTag::limit_list:
      return "limit_list";
    case ServerTag::execution_reply:
      return "execution_reply";
    case ServerTag::clipboard_desktop_request:
      return "clipboard_desktop_request";
    case ServerTag::clipboard_desktop_execute:
      return "clipboard_desktop_execute";
    case ServerTag::clipboard_desktop_cancel:
      return "clipboard_desktop_cancel";
    case ServerTag::runtime_clipboard_chunk:
      return "runtime_clipboard_chunk";
    case ServerTag::pane_list:
      return "pane_list";
    case ServerTag::pane_shell:
      return "pane_shell";
    case ServerTag::pane_git:
      return "pane_git";
    case ServerTag::completion_words:
      return "completion_words";
    case ServerTag::pane_blocks:
      return "pane_blocks";
    case ServerTag::command_spec:
      return "command_spec";
    case ServerTag::pane_rows:
      return "pane_rows";
    case ServerTag::pane_scrollback:
      return "pane_scrollback";
    case ServerTag::pane_document:
      return "pane_document";
    case ServerTag::monitor_snapshot:
      return "monitor_snapshot";
    case ServerTag::history_workspaces:
      return "history_workspaces";
    case ServerTag::pane_kind_notice:
      return "pane_kind_notice";
    case ServerTag::nvim_grid:
      return "nvim_grid";
    case ServerTag::nvim_frame:
      return "nvim_frame";
    case ServerTag::nvim_cmdline:
      return "nvim_cmdline";
    case ServerTag::nvim_popup_menu:
      return "nvim_popup_menu";
    case ServerTag::nvim_message_list:
      return "nvim_message_list";
    case ServerTag::nvim_tab_line:
      return "nvim_tab_line";
    case ServerTag::nvim_prompt:
      return "nvim_prompt";
    case ServerTag::nvim_navigated:
      return "nvim_navigated";
    case ServerTag::text_results:
      return "text_results";
    case ServerTag::nvim_pick:
      return "nvim_pick";
    case ServerTag::nvim_link:
      return "nvim_link";
    case ServerTag::pane_theme:
      return "pane_theme";
    }

    return {};
  }

  [[nodiscard]] constexpr std::string_view agentStatusName(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::unknown:
      return "unknown";
    case AgentStatus::working:
      return "working";
    case AgentStatus::blocked:
      return "blocked";
    case AgentStatus::ready:
      return "ready";
    case AgentStatus::failed:
      return "failed";
    case AgentStatus::done:
      return "done";
    }

    return {};
  }

  [[nodiscard]] constexpr std::string_view agentBlockedReasonName(AgentBlockedReason reason) noexcept {
    switch (reason) {
    case AgentBlockedReason::none:
      return "none";
    case AgentBlockedReason::permission:
      return "permission";
    case AgentBlockedReason::question:
      return "question";
    case AgentBlockedReason::plan:
      return "plan";
    case AgentBlockedReason::other:
      return "other";
    }

    return {};
  }

#pragma clang diagnostic pop

  // The status and the reason `name` spells, by the names above; nothing for any other text.
  [[nodiscard]] constexpr ds::Option<AgentStatus> agentStatusNamed(std::string_view name) noexcept {
    for (unsigned value = 0; !name.empty() && value <= std::numeric_limits<Byte>::max(); ++value) {
      if (agentStatusName(static_cast<AgentStatus>(value)) == name) {
        return static_cast<AgentStatus>(value);
      }
    }

    return ds::none;
  }

  [[nodiscard]] constexpr ds::Option<AgentBlockedReason> agentBlockedReasonNamed(std::string_view name) noexcept {
    for (unsigned value = 0; !name.empty() && value <= std::numeric_limits<Byte>::max(); ++value) {
      if (agentBlockedReasonName(static_cast<AgentBlockedReason>(value)) == name) {
        return static_cast<AgentBlockedReason>(value);
      }
    }

    return ds::none;
  }

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
    // Shows the file `text` names in the editor pane of a tab, at line `value` when it is not
    // zero; `target_id` is the pane the command came from, when it came from one.
    editor_open = 34,
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

  inline constexpr std::size_t max_notification_title_bytes = 96;
  inline constexpr std::size_t max_notification_message_bytes = 512;
  inline constexpr std::size_t max_notification_link_bytes = 1024;
  inline constexpr std::string_view notification_link_scheme = "https://";

  tbc::val_a<std::string_view> notificationLinkHost(tbc::val_a<std::string_view> link) noexcept;

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

  // What git says of a path against the checkout's index and head: nothing when it is as
  // committed or outside a repository.
  enum class PathChange : Byte {
    none = 0,
    modified = 1,
    added = 2,
    deleted = 3,
    renamed = 4,
    untracked = 5,
    conflicted = 6,
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

  // An agent session's identity, as the bytes of its UUID.
  inline constexpr std::size_t session_id_bytes = 16;

  struct CoordinatorReference {
    ds::Array<Byte, session_id_bytes> session_id{};
    std::uint64_t pane_id = 0;
    std::uint64_t pane_generation = 0;
  };

  struct PaneForeground {
    std::uint64_t pane_id = 0;
    std::string_view name;
  };

  inline constexpr std::size_t max_listed_ports = 4;

  // A live pane and the process holding its terminal. `shell` is set while the pane's root
  // process holds it and still runs a shell, as at a prompt. `ports` are the lowest TCP ports
  // the foreground process group listens on, ascending.
  struct PaneListEntry {
    std::uint64_t pane_id = 0;
    std::uint64_t pane_generation = 0;
    TabLocation location{};
    std::string_view foreground;
    std::uint32_t foreground_age_s = 0;
    bool shell = false;
    std::span<const std::uint16_t> ports;
  };

  // What a client shows for a pane of a tab it has not loaded. `cwd` is empty until the runtime observes one.
  struct TabPane {
    std::uint64_t pane_id = 0;
    std::string_view foreground;
    std::string_view cwd;
  };

  struct TabDescriptor {
    std::uint64_t tab_id = 0;
    std::uint16_t position = 0;
    std::uint16_t pane_count = 0;
    std::string_view label;
    std::span<const TabPane> panes;
  };

  struct WorkspaceListEntry {
    std::uint64_t workspace = 0;
    std::string_view name;
    std::string_view path;
    std::uint16_t tab_count = 0;
    std::string_view branch;
    bool dirty = false;
  };

  struct WorktreeListEntry {
    std::uint64_t worktree = 0;
    std::uint64_t source = 0;
    ds::Option<std::uint64_t> workspace;
    ds::Option<std::uint64_t> created_by;
    WorktreeOrigin origin = WorktreeOrigin::telar;
    WorktreeState state = WorktreeState::active;
    std::string_view path;
    std::string_view branch;
    std::string_view base;
    std::string_view title;
    std::string_view brief;
    std::string_view dispatched_from;
    ds::Option<CoordinatorReference> coordinator;
    std::uint32_t diff_added = 0;
    std::uint32_t diff_removed = 0;
    std::uint32_t diff_files = 0;
    std::uint32_t commits_ahead = 0;
    std::string_view command_label;
    CommandState command_state = CommandState::none;
    std::int32_t command_exit = 0;
  };

  struct HistoryEntry {
    std::uint64_t id = 0;
    std::uint64_t pane_id = 0;
    std::int64_t started_at_ms = 0;
    std::int64_t duration_ns = 0;
    ds::Option<std::int32_t> exit_code;
    HistoryStatus status = HistoryStatus::completed;
    HistoryAuthor author = HistoryAuthor::human;
    HistoryOrigin origin = HistoryOrigin::pane;
    std::string_view provider;
    std::string_view command;
    std::string_view cwd;
    std::string_view workspace_path;
    bool command_truncated = false;
  };

  struct AgentSnapshotEntry {
    std::uint64_t pane_id = 0;
    std::uint64_t pane_generation = 0;
    TabLocation location{};
    std::uint16_t pane_index = 0;
    std::uint32_t process_id = 0;
    ds::Array<Byte, session_id_bytes> session_id{};
    std::string_view workspace_label;
    std::string_view tab_label;
    std::string_view session_title;
    AgentTitleSource title_source = AgentTitleSource::telar;
    AgentTitleState title_state = AgentTitleState::placeholder;
    std::string_view cwd_label;
    AgentProvider provider = AgentProvider::unknown;
    std::string_view provider_name;
    std::string_view display_name;
    std::string_view icon;
    AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
    AgentStatus status = AgentStatus::unknown;
    AgentBlockedReason blocked_reason = AgentBlockedReason::none;
    std::string_view last_event;
    std::uint32_t status_age_s = 0;
    AgentSource source = AgentSource::screen;
    AgentAuthority authority = AgentAuthority::candidate;
    Byte confidence = 0;
    std::uint64_t sequence = 0;
    std::int64_t observed_at_ms = 0;
    std::int64_t expires_at_ms = 0;
    std::uint64_t work_tree = 0;
    std::string_view final_message;
    std::uint16_t plan_done = 0;
    std::uint16_t plan_total = 0;
    std::string_view plan_step;
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
    std::string_view text;
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
    std::span<const ClientLayoutNode> nodes;
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
  inline constexpr std::uint32_t min_notification_duration_ms = 500;
  inline constexpr std::uint32_t max_notification_duration_ms = 60000;

  struct NotificationBody {
    NotificationLevel level = NotificationLevel::info;
    std::uint32_t duration_ms = default_notification_duration_ms;
    NotificationTarget target{};
    std::string_view title;
    std::string_view message;
    std::string_view link;
  };

  struct PathMatch {
    std::string_view path;
    PathKind kind = PathKind::file;
    std::span<const std::uint16_t> positions;
    PathChange change = PathChange::none;
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

  // The byte and count limits the schemas below put on their fields.
  inline constexpr std::size_t max_path_bytes = 4096;
  inline constexpr std::size_t max_text16_bytes = std::numeric_limits<std::uint16_t>::max();
  inline constexpr std::size_t max_environment_bytes = std::size_t{512} * 1024;
  inline constexpr std::size_t max_launch_arguments = 64;
  inline constexpr std::size_t max_environment_entries = 256;
  inline constexpr std::size_t max_foreground_bytes = 48;
  inline constexpr std::size_t max_tab_panes = 64;
  inline constexpr std::size_t max_tab_label_bytes = 128;
  inline constexpr std::size_t max_workspace_name_bytes = 256;
  inline constexpr std::size_t max_workspace_tabs = 64;
  inline constexpr std::size_t max_branch_bytes = 200;
  inline constexpr std::size_t max_worktree_title_bytes = 96;
  inline constexpr std::size_t max_worktree_brief_bytes = 512;
  inline constexpr std::size_t max_dispatched_from_bytes = 32;
  inline constexpr std::size_t max_command_label_bytes = 48;
  inline constexpr std::size_t max_provider_bytes = 64;
  inline constexpr std::size_t max_history_command_bytes = std::size_t{64} * 1024;
  inline constexpr std::size_t max_workspace_label_bytes = 48;
  inline constexpr std::size_t max_agent_title_bytes = 96;
  inline constexpr std::size_t max_cwd_label_bytes = 48;
  inline constexpr std::size_t max_agent_name_bytes = 32;
  inline constexpr std::size_t max_agent_icon_bytes = 8;
  inline constexpr std::size_t max_agent_event_bytes = 96;
  inline constexpr Byte max_confidence_percent = 100;
  inline constexpr std::size_t max_agent_message_bytes = 2048;
  inline constexpr std::size_t max_plan_step_bytes = 96;
  inline constexpr std::size_t max_client_command_text_bytes = 4096;
  // A split's ratio in ten-thousandths of its extent.
  inline constexpr std::uint16_t min_split_ratio = 1000;
  inline constexpr std::uint16_t max_split_ratio = 9000;
  inline constexpr std::size_t max_tab_layout_nodes = 127;
  inline constexpr std::size_t max_completion_bytes = 256;
  inline constexpr std::size_t max_block_command_bytes = 256;
  inline constexpr std::size_t max_match_path_bytes = 1024;
  inline constexpr std::size_t max_match_positions = 64;
  inline constexpr std::size_t max_limit_name_bytes = 64;
  inline constexpr std::size_t max_limit_noun_bytes = 32;
  inline constexpr std::size_t max_limit_route_bytes = 32;

  template <>
  struct BodySchema<TerminalSize> : MessageSchema<TerminalSize> {
    // Matches frame_support.max_cell_count and its worst-case metadata budget.
    static constexpr std::uint32_t max_cells = 130359;

    static void validate(const TerminalSize& value);
  };

  template <typename Value, Byte Maximum>
  struct TaggedIdSerializer {
    static constexpr std::size_t min_width = 1;
    static constexpr bool fixed_size = false;
    using KindCodec = EnumByte<typename Value::Kind, Maximum>;

    static std::size_t encodedSize(const Value& value) {
      KindCodec::validate(value.kind);
      if (static_cast<Byte>(value.kind) == 0) {
        return 1;
      }

      NonzeroU64::validate(value.id);

      return KindCodec::width + NonzeroU64::width;
    }

    static void encodeBody(const Value& value, std::span<Byte>& output) {
      KindCodec::encode(value.kind, output);
      if (static_cast<Byte>(value.kind) != 0) {
        NonzeroU64::encode(value.id, output);
      }
    }

    static void decodeBody(std::span<const Byte>& input, Value& value, DecodeStorage& /*storage*/) {
      value.kind = KindCodec::decode(input);
      value.id = static_cast<Byte>(value.kind) == 0 ? 0 : NonzeroU64::decode(input);
    }
  };

  template <>
  struct BodySchema<PaneTarget> : TaggedIdSerializer<PaneTarget, 2> {};

  template <>
  struct BodySchema<WorkspaceLocation>
      : Serializer<Field<&WorkspaceLocation::kind, EnumByte<WorkspaceLocation::Kind, 1>, "kind">, Field<&WorkspaceLocation::id, NonzeroU64, "id">> {};

  template <>
  struct BodySchema<TabLocation>
      : Serializer<Field<&TabLocation::workspace, ValueCodec<WorkspaceLocation>, "workspace">, Field<&TabLocation::tab_id, NonzeroU64, "tab_id">> {};

  // HistoryScope is supplied by the containing message, never written twice.
  template <>
  struct BodySchema<HistoryScopeValue> {
    static constexpr std::size_t min_width = 0;
    static constexpr bool fixed_size = false;
    using PathCodec = Text16<max_path_bytes, false>;

    static std::size_t encodedSize(const HistoryScopeValue& value, HistoryScope scope);
    static void encodeBody(const HistoryScopeValue& value, std::span<Byte>& output, HistoryScope scope);
    static void decodeBody(DecodeInput input, tbc::mut_a<HistoryScopeValue> value, DecodeStorage&, HistoryScope scope);
  };

  template <>
  struct BodySchema<ClientRoute>
      : Serializer<Field<&ClientRoute::id, NonzeroU64, "id">, Field<&ClientRoute::generation, NonzeroU64, "generation">> {};

  template <>
  struct BodySchema<CoordinatorReference>
      : Serializer<Field<&CoordinatorReference::session_id, FixedBytes<session_id_bytes>, "session_id">, Field<&CoordinatorReference::pane_id, NonzeroU64, "pane_id">, Field<&CoordinatorReference::pane_generation, NonzeroU64, "pane_generation">> {
    static void validate(const CoordinatorReference& value);
  };

  template <>
  struct BodySchema<EnvironmentEntry>
      : Serializer<Field<&EnvironmentEntry::name, Text16<max_text16_bytes, false>, "name">, Field<&EnvironmentEntry::value, Text32<max_environment_bytes>, "value">> {
    static void validate(const EnvironmentEntry& value);
  };

  template <>
  struct BodySchema<Launch>
      : Serializer<
            Field<&Launch::cwd, Text16<max_path_bytes, false>, "cwd">,
            Field<&Launch::cwd_source, u64, "cwd_source">,
            Field<&Launch::arguments, CountedSpan<u16, Text16<max_text16_bytes>, max_launch_arguments, 1>, "arguments">,
            Field<&Launch::environment_mode, EnumByte<EnvironmentMode, 1>, "environment_mode">,
            Field<&Launch::environment, CountedSpan<u16, ValueCodec<EnvironmentEntry>, max_environment_entries>, "environment">> {
    static constexpr std::size_t maximum_arguments = max_launch_arguments;
    static constexpr std::size_t maximum_environment = max_environment_entries;
    static constexpr std::size_t maximum_argument_bytes = std::size_t{128} * 1024;
    static constexpr std::size_t maximum_environment_bytes = max_environment_bytes;

    static void validate(const Launch& value);
  };

  template <>
  struct BodySchema<TabPane>
      : Serializer<Field<&TabPane::pane_id, NonzeroU64, "pane_id">, Field<&TabPane::foreground, Text16<max_foreground_bytes, false>, "foreground">, Field<&TabPane::cwd, Text16<max_path_bytes>, "cwd">> {};

  template <>
  struct BodySchema<PaneListEntry>
      : Serializer<Field<&PaneListEntry::pane_id, NonzeroU64, "pane_id">, Field<&PaneListEntry::pane_generation, NonzeroU64, "pane_generation">, Field<&PaneListEntry::location, ValueCodec<TabLocation>, "location">, Field<&PaneListEntry::foreground, Text16<max_foreground_bytes, false>, "foreground">, Field<&PaneListEntry::foreground_age_s, u32, "foreground_age_s">, Field<&PaneListEntry::shell, BoolByte, "shell">, Field<&PaneListEntry::ports, CountedSpan<u8, BoundedInteger<u16, 1>, max_listed_ports>, "ports">> {
    static void validate(const PaneListEntry& value);
  };

  template <>
  struct BodySchema<TabDescriptor>
      : Serializer<Field<&TabDescriptor::tab_id, NonzeroU64, "tab_id">, Field<&TabDescriptor::position, u16, "position">, Field<&TabDescriptor::pane_count, BoundedInteger<u16, 0, max_tab_panes>, "pane_count">, Field<&TabDescriptor::label, DisplayText16<max_tab_label_bytes>, "label">, Field<&TabDescriptor::panes, CountedSpan<u16, ValueCodec<TabPane>, max_tab_panes>, "panes">> {
    static void validate(const TabDescriptor& value);
  };

  template <>
  struct BodySchema<WorkspaceListEntry>
      : Serializer<Field<&WorkspaceListEntry::workspace, NonzeroU64, "workspace">, Field<&WorkspaceListEntry::name, Text16<max_workspace_name_bytes, false>, "name">, Field<&WorkspaceListEntry::path, Text16<max_path_bytes, false>, "path">, Field<&WorkspaceListEntry::tab_count, BoundedInteger<u16, 0, max_workspace_tabs>, "tab_count">, Field<&WorkspaceListEntry::branch, Text16<max_branch_bytes>, "branch">, Field<&WorkspaceListEntry::dirty, BoolByte, "dirty">> {};

  template <>
  struct BodySchema<WorktreeListEntry>
      : Serializer<
            Field<&WorktreeListEntry::worktree, NonzeroU64, "worktree">,
            Field<&WorktreeListEntry::source, NonzeroU64, "source">,
            Field<&WorktreeListEntry::workspace, OptionalValue<NonzeroU64>, "workspace">,
            Field<&WorktreeListEntry::created_by, OptionalValue<NonzeroU64>, "created_by">,
            Field<&WorktreeListEntry::origin, EnumByte<WorktreeOrigin, 1>, "origin">,
            Field<&WorktreeListEntry::state, EnumByte<WorktreeState, 2>, "state">,
            Field<&WorktreeListEntry::path, Text16<max_path_bytes, false>, "path">,
            Field<&WorktreeListEntry::branch, DisplayText16<max_branch_bytes, false>, "branch">,
            Field<&WorktreeListEntry::base, DisplayText16<max_branch_bytes>, "base">,
            Field<&WorktreeListEntry::title, DisplayText16<max_worktree_title_bytes>, "title">,
            Field<&WorktreeListEntry::brief, MessageText16<max_worktree_brief_bytes>, "brief">,
            Field<&WorktreeListEntry::dispatched_from, DisplayText16<max_dispatched_from_bytes>, "dispatched_from">,
            Field<&WorktreeListEntry::coordinator, OptionalValue<ValueCodec<CoordinatorReference>>, "coordinator">,
            Field<&WorktreeListEntry::diff_added, u32, "diff_added">,
            Field<&WorktreeListEntry::diff_removed, u32, "diff_removed">,
            Field<&WorktreeListEntry::diff_files, u32, "diff_files">,
            Field<&WorktreeListEntry::commits_ahead, u32, "commits_ahead">,
            Field<&WorktreeListEntry::command_label, DisplayText16<max_command_label_bytes>, "command_label">,
            Field<&WorktreeListEntry::command_state, EnumByte<CommandState, 2>, "command_state">,
            Field<&WorktreeListEntry::command_exit, i32, "command_exit">> {
    static void validate(const WorktreeListEntry& value);
  };

  template <>
  struct BodySchema<HistoryEntry>
      : Serializer<Field<&HistoryEntry::id, NonzeroU64, "id">, Field<&HistoryEntry::pane_id, NonzeroU64, "pane_id">, Field<&HistoryEntry::started_at_ms, i64, "started_at_ms">, Field<&HistoryEntry::duration_ns, i64, "duration_ns">, Field<&HistoryEntry::exit_code, OptionalValue<i32>, "exit_code">, Field<&HistoryEntry::status, EnumByte<HistoryStatus, 2>, "status">, Field<&HistoryEntry::author, EnumByte<HistoryAuthor, 1>, "author">, Field<&HistoryEntry::origin, EnumByte<HistoryOrigin, 2>, "origin">, Field<&HistoryEntry::provider, Text16<max_provider_bytes>, "provider">, Field<&HistoryEntry::command, Text32<max_history_command_bytes, false>, "command">, Field<&HistoryEntry::cwd, Text16<max_path_bytes>, "cwd">, Field<&HistoryEntry::workspace_path, Text16<max_path_bytes>, "workspace_path">, Field<&HistoryEntry::command_truncated, BoolByte, "command_truncated">> {};

  template <>
  struct BodySchema<AgentSnapshotEntry>
      : Serializer<
            Field<&AgentSnapshotEntry::pane_id, NonzeroU64, "pane_id">,
            Field<&AgentSnapshotEntry::pane_generation, NonzeroU64, "pane_generation">,
            Field<&AgentSnapshotEntry::location, ValueCodec<TabLocation>, "location">,
            Field<&AgentSnapshotEntry::pane_index, BoundedInteger<u16, 1>, "pane_index">,
            Field<&AgentSnapshotEntry::process_id, u32, "process_id">,
            Field<&AgentSnapshotEntry::session_id, FixedBytes<session_id_bytes>, "session_id">,
            Field<&AgentSnapshotEntry::workspace_label, DisplayText16<max_workspace_label_bytes>, "workspace_label">,
            Field<&AgentSnapshotEntry::tab_label, DisplayText16<max_tab_label_bytes>, "tab_label">,
            Field<&AgentSnapshotEntry::session_title, DisplayText16<max_agent_title_bytes>, "session_title">,
            Field<&AgentSnapshotEntry::title_source, EnumByte<AgentTitleSource, 4>, "title_source">,
            Field<&AgentSnapshotEntry::title_state, EnumByte<AgentTitleState, 3>, "title_state">,
            Field<&AgentSnapshotEntry::cwd_label, DisplayText16<max_cwd_label_bytes>, "cwd_label">,
            Field<&AgentSnapshotEntry::provider, EnumByte<AgentProvider, max_agent_provider_index>, "provider">,
            Field<&AgentSnapshotEntry::provider_name, DisplayText16<max_agent_name_bytes>, "provider_name">,
            Field<&AgentSnapshotEntry::display_name, DisplayText16<max_agent_name_bytes>, "display_name">,
            Field<&AgentSnapshotEntry::icon, DisplayText16<max_agent_icon_bytes>, "icon">,
            Field<&AgentSnapshotEntry::attachments, EnumByte<AgentAttachmentMarkers, 3>, "attachments">,
            Field<&AgentSnapshotEntry::status, EnumByte<AgentStatus, std::to_underlying(AgentStatus::done)>, "status">,
            Field<&AgentSnapshotEntry::blocked_reason, EnumByte<AgentBlockedReason, 4>, "blocked_reason">,
            Field<&AgentSnapshotEntry::last_event, DisplayText16<max_agent_event_bytes>, "last_event">,
            Field<&AgentSnapshotEntry::status_age_s, u32, "status_age_s">,
            Field<&AgentSnapshotEntry::source, EnumByte<AgentSource, 3, 1>, "source">,
            Field<&AgentSnapshotEntry::authority, EnumByte<AgentAuthority, std::to_underlying(AgentAuthority::stale)>, "authority">,
            Field<&AgentSnapshotEntry::confidence, BoundedInteger<u8, 0, max_confidence_percent>, "confidence">,
            Field<&AgentSnapshotEntry::sequence, NonzeroU64, "sequence">,
            Field<&AgentSnapshotEntry::observed_at_ms, i64, "observed_at_ms">,
            Field<&AgentSnapshotEntry::expires_at_ms, i64, "expires_at_ms">,
            Field<&AgentSnapshotEntry::work_tree, u64, "work_tree">,
            Field<&AgentSnapshotEntry::final_message, MessageText16<max_agent_message_bytes>, "final_message">,
            Field<&AgentSnapshotEntry::plan_done, u16, "plan_done">,
            Field<&AgentSnapshotEntry::plan_total, u16, "plan_total">,
            Field<&AgentSnapshotEntry::plan_step, DisplayText16<max_plan_step_bytes>, "plan_step">> {
    static void validate(const AgentSnapshotEntry& value);
  };

  template <>
  struct BodySchema<ClientDescriptor>
      : Serializer<Field<&ClientDescriptor::id, NonzeroU64, "id">, Field<&ClientDescriptor::generation, NonzeroU64, "generation">, Field<&ClientDescriptor::identity, NonzeroU64, "identity">, Field<&ClientDescriptor::attachments, u16, "attachments">, Field<&ClientDescriptor::last_input_pane, u64, "last_input_pane">, Field<&ClientDescriptor::last_input_sequence, u64, "last_input_sequence">> {};

  template <>
  struct BodySchema<ClientCommand>
      : Serializer<Field<&ClientCommand::request_id, NonzeroU64, "request_id">, Field<&ClientCommand::route, ValueCodec<ClientRoute>, "route">, Field<&ClientCommand::action, EnumByte<ClientAction, std::to_underlying(ClientAction::editor_open)>, "action">, Field<&ClientCommand::status, EnumByte<ClientCommandStatus, 3>, "status">, Field<&ClientCommand::target_id, u64, "target_id">, Field<&ClientCommand::value, i64, "value">, Field<&ClientCommand::text, Utf8Text16<max_client_command_text_bytes>, "text">> {};

  template <>
  struct BodySchema<ClientLayoutPane>
      : Serializer<Field<&ClientLayoutPane::pane_id, NonzeroU64, "pane_id">> {};

  template <>
  struct BodySchema<ClientLayoutSplit>
      : Serializer<Field<&ClientLayoutSplit::axis, EnumByte<ClientLayoutAxis, 1>, "axis">, Field<&ClientLayoutSplit::ratio, BoundedInteger<u16, min_split_ratio, max_split_ratio>, "ratio">> {};

  template <>
  struct BodySchema<ClientLayoutNode> {
    static constexpr std::size_t min_width = 4;
    static constexpr bool fixed_size = false;

    static std::size_t encodedSize(const ClientLayoutNode& value);
    static void encodeBody(const ClientLayoutNode& value, std::span<Byte>& output);
    static void decodeBody(std::span<const Byte>& input, ClientLayoutNode& value, DecodeStorage& storage);
  };

  template <>
  struct BodySchema<ClientTabLayout>
      : Serializer<Field<&ClientTabLayout::location, ValueCodec<TabLocation>, "location">, Field<&ClientTabLayout::focused_pane, NonzeroU64, "focused_pane">, Field<&ClientTabLayout::fullscreen, BoolByte, "fullscreen">, Field<&ClientTabLayout::workspace_active, BoolByte, "workspace_active">, Field<&ClientTabLayout::nodes, CountedSpan<u16, ValueCodec<ClientLayoutNode>, max_tab_layout_nodes, 1>, "nodes">> {
    static constexpr std::size_t maximum_nodes = max_tab_layout_nodes;
    static constexpr std::size_t maximum_panes = 64;

    static void validate(const ClientTabLayout& value);
  };

  template <>
  struct BodySchema<NotificationTarget> : TaggedIdSerializer<NotificationTarget, 3> {};

  template <>
  struct BodySchema<NotificationBody>
      : Serializer<
            Field<&NotificationBody::level, EnumByte<NotificationLevel, 3>, "level">,
            Field<&NotificationBody::duration_ms, BoundedInteger<u32, min_notification_duration_ms, max_notification_duration_ms>, "duration_ms">,
            Field<&NotificationBody::target, ValueCodec<NotificationTarget>, "target">,
            Field<&NotificationBody::title, DisplayText16<max_notification_title_bytes, false>, "title">,
            Field<&NotificationBody::message, DisplayText16<max_notification_message_bytes>, "message">,
            Field<&NotificationBody::link, Text16<max_notification_link_bytes>, "link">> {
    static void validate(const NotificationBody& value);
  };

  // One value a completion provider found.
  struct CompletionWord {
    std::string_view text;
    std::string_view description;
  };

  template <>
  struct BodySchema<CompletionWord>
      : Serializer<Field<&CompletionWord::text, DisplayText16<max_completion_bytes, false>, "text">, Field<&CompletionWord::description, DisplayText16<max_completion_bytes>, "description">> {
    static void validate(const CompletionWord& value);
  };

  enum class CommandBlockState : Byte {
    running = 0,
    succeeded = 1,
    failed = 2,
    interrupted = 3,
    // An ssh whose remote shell has taken over the pane: it ends when that shell does.
    session = 4,
  };

  // Where a command ran: in the pane's own shell, as the ssh that opened a remote shell, or
  // in that remote shell.
  enum class CommandBlockNest : Byte {
    none = 0,
    opens = 1,
    inside = 2,
  };

  // One command an integrated shell ran: the rows its prompt and command line take, from the
  // top of the scrollback as a viewport counts them, its first line and how it ended.
  struct CommandBlock {
    std::uint32_t row = 0;
    std::uint16_t rows = 0;
    // Lines of the command after the first.
    std::uint16_t lines = 0;
    CommandBlockState state{};
    std::int32_t status = 0;
    std::uint32_t duration_ms = 0;
    std::string_view command;
    CommandBlockNest nest{};
  };

  template <>
  struct BodySchema<CommandBlock>
      : Serializer<Field<&CommandBlock::row, u32, "row">, Field<&CommandBlock::rows, u16, "rows">, Field<&CommandBlock::lines, u16, "lines">, Field<&CommandBlock::state, EnumByte<CommandBlockState, 4>, "state">, Field<&CommandBlock::status, i32, "status">, Field<&CommandBlock::duration_ms, u32, "duration_ms">, Field<&CommandBlock::command, DisplayText16<max_block_command_bytes>, "command">, Field<&CommandBlock::nest, EnumByte<CommandBlockNest, 2>, "nest">> {
    static void validate(const CommandBlock& value);
  };

  template <>
  struct BodySchema<PathMatch>
      : Serializer<Field<&PathMatch::path, DisplayText16<max_match_path_bytes, false>, "path">, Field<&PathMatch::kind, EnumByte<PathKind, 1>, "kind">, Field<&PathMatch::positions, CountedSpan<u8, u16, max_match_positions>, "positions">, Field<&PathMatch::change, EnumByte<PathChange, std::to_underlying(PathChange::conflicted)>, "change">> {
    static void validate(const PathMatch& value);
  };

  template <>
  struct BodySchema<LimitReach>
      : Serializer<Field<&LimitReach::name, Text16<max_limit_name_bytes, false>, "name">, Field<&LimitReach::noun, Text16<max_limit_noun_bytes>, "noun">, Field<&LimitReach::value, u64, "value">, Field<&LimitReach::requested, OptionalValue<u64>, "requested">, Field<&LimitReach::route, Text16<max_limit_route_bytes>, "route">> {
    static void validate(const LimitReach& value);
  };

  template <>
  struct BodySchema<LimitListEntry>
      : Serializer<Field<&LimitListEntry::reach, ValueCodec<LimitReach>, "reach">, Field<&LimitListEntry::origin, EnumByte<LimitOrigin, 1>, "origin">, Field<&LimitListEntry::hits, u64, "hits">, Field<&LimitListEntry::last_ms, i64, "last_ms">> {};

  template <>
  struct BodySchema<GraphicsHeader>
      : Serializer<Field<&GraphicsHeader::pane_id, NonzeroU64, "pane_id">, Field<&GraphicsHeader::revision, NonzeroU64, "revision">> {};

  template <>
  struct BodySchema<ImageKey>
      : Serializer<Field<&ImageKey::image_id, BoundedInteger<u32, 1>, "image_id">, Field<&ImageKey::generation, NonzeroU64, "generation">> {};

  template <>
  struct BodySchema<ImageDescription>
      : Serializer<Field<&ImageDescription::key, ValueCodec<ImageKey>, "key">, Field<&ImageDescription::format, EnumChoiceByte<ImageFormat, ImageFormat::rgb, ImageFormat::rgba>, "format">, Field<&ImageDescription::width, BoundedInteger<u32, 1>, "width">, Field<&ImageDescription::height, BoundedInteger<u32, 1>, "height">, Field<&ImageDescription::byte_len, u64, "byte_len">> {
    static void validate(const ImageDescription& value);
  };

  template <>
  struct BodySchema<GraphicsPlacement>
      : Serializer<Field<&GraphicsPlacement::key, ValueCodec<ImageKey>, "key">, Field<&GraphicsPlacement::virtual_id, NonzeroU64, "virtual_id">, Field<&GraphicsPlacement::placement_id, u32, "placement_id">, Field<&GraphicsPlacement::x, i32, "x">, Field<&GraphicsPlacement::y, i32, "y">, Field<&GraphicsPlacement::source_x, u32, "source_x">, Field<&GraphicsPlacement::source_y, u32, "source_y">, Field<&GraphicsPlacement::source_width, u32, "source_width">, Field<&GraphicsPlacement::source_height, u32, "source_height">, Field<&GraphicsPlacement::columns, u32, "columns">, Field<&GraphicsPlacement::rows, u32, "rows">, Field<&GraphicsPlacement::offset_x, u32, "offset_x">, Field<&GraphicsPlacement::offset_y, u32, "offset_y">, Field<&GraphicsPlacement::z_index, i32, "z_index">, Field<&GraphicsPlacement::location, EnumChoiceByte<PlacementLocation, PlacementLocation::cell, PlacementLocation::placeholders>, "location">> {};

  // The sizes of the fixed bodies, pinned so that a field change that moves one fails here.
  namespace fixed_body_bytes {
    inline constexpr std::size_t terminal_size = 8;
    inline constexpr std::size_t workspace_location = 9;
    inline constexpr std::size_t tab_location = 17;
    inline constexpr std::size_t client_route = 16;
    inline constexpr std::size_t coordinator_reference = 32;
    inline constexpr std::size_t client_descriptor = 42;
    inline constexpr std::size_t graphics_header = 16;
    inline constexpr std::size_t image_key = 12;
    inline constexpr std::size_t image_description = 29;
    inline constexpr std::size_t graphics_placement = 69;
  }

  static_assert(BodySchema<TerminalSize>::payload_size == fixed_body_bytes::terminal_size);
  static_assert(BodySchema<WorkspaceLocation>::payload_size == fixed_body_bytes::workspace_location);
  static_assert(BodySchema<TabLocation>::payload_size == fixed_body_bytes::tab_location);
  static_assert(BodySchema<ClientRoute>::payload_size == fixed_body_bytes::client_route);
  static_assert(BodySchema<CoordinatorReference>::payload_size == fixed_body_bytes::coordinator_reference);
  static_assert(BodySchema<ClientDescriptor>::payload_size == fixed_body_bytes::client_descriptor);
  static_assert(BodySchema<GraphicsHeader>::payload_size == fixed_body_bytes::graphics_header);
  static_assert(BodySchema<ImageKey>::payload_size == fixed_body_bytes::image_key);
  static_assert(BodySchema<ImageDescription>::payload_size == fixed_body_bytes::image_description);
  static_assert(BodySchema<GraphicsPlacement>::payload_size == fixed_body_bytes::graphics_placement);

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

  // The shell telar integrated with in a pane; none for any other program.
  enum class IntegratedShell : Byte {
    none = 0,
    zsh = 1,
    bash = 2,
    fish = 3,
  };

  // Where the integrated shell is, from the marks it signed.
  enum class ShellPhase : Byte {
    unknown = 0,
    prompt = 1,
    running = 2,
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

  void validateAgentSession(std::string_view session, bool empty_allowed);

  void validateWorkspaceClosure(const WorkspaceLocation& workspace, bool closed, ds::Option<std::uint64_t> previous);

  void validateSharedImageName(std::string_view name);

  constexpr bool sameWorkspace(const WorkspaceLocation& left, const WorkspaceLocation& right) {
    return left.kind == right.kind && left.id == right.id;
  }

  constexpr bool sameTab(const TabLocation& left, const TabLocation& right) {
    return sameWorkspace(left.workspace, right.workspace) && left.tab_id == right.tab_id;
  }

  void validateLayoutCollection(ds::Option<TabLocation> active, std::span<const ClientTabLayout> tabs);

  struct ScopedHistoryValue {
    using value_type = HistoryScopeValue;
    static constexpr std::size_t min_width = 0;

    static std::size_t encodedSize(const value_type& value, HistoryScope scope);
    static void encode(const value_type& value, std::span<Byte>& output, HistoryScope scope);
    static Decoded<value_type> decode(DecodeInput input, DecodeStorage& storage, HistoryScope scope);
  };

  struct TargetLaunch {
    using value_type = ds::Option<Launch>;
    static constexpr std::size_t min_width = 0;

    static std::size_t encodedSize(const value_type& value, const PaneTarget& target);
    static void encode(const value_type& value, std::span<Byte>& output, const PaneTarget& target);
    static Decoded<value_type> decode(DecodeInput input, DecodeStorage& storage, const PaneTarget& target);
  };

  struct ImportHistoryEntry {
    std::int64_t started_at_ms = 0;
    std::string_view command;
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
    std::string_view command;
  };

  template <>
  struct BodySchema<ImportHistoryEntry>
      : Serializer<Field<&ImportHistoryEntry::started_at_ms, i64, "started_at_ms">, Field<&ImportHistoryEntry::command, Text16<max_text16_bytes, false>, "command">> {};

  template <>
  struct BodySchema<PaneDescriptor>
      : Serializer<Field<&PaneDescriptor::pane_id, NonzeroU64, "pane_id">, Field<&PaneDescriptor::lifecycle, EnumByte<PaneLifecycle, 1>, "lifecycle">, Field<&PaneDescriptor::pane_generation, u64, "pane_generation">> {};

  template <>
  struct BodySchema<PaneMatch> : Serializer<Field<&PaneMatch::x, u16, "x">, Field<&PaneMatch::y, u32, "y">, Field<&PaneMatch::len, BoundedInteger<u16, 1>, "len">> {
  };

  template <>
  struct BodySchema<HistoryStatsEntry>
      : Serializer<Field<&HistoryStatsEntry::count, u64, "count">, Field<&HistoryStatsEntry::command, Text16<max_text16_bytes, false>, "command">> {};

}; // namespace telar
