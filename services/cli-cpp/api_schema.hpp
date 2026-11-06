#pragma once

#include "command_io.hpp"
#include "runtime_event_output.hpp"
#include <array>

namespace telar::runtime::cli::api {

struct NamedValue {
  std::string_view name;
  std::uint64_t value;
};

inline constexpr std::array client_requests{
    NamedValue{.name = "open_pane", .value = static_cast<std::uint64_t>(ClientTag::open_pane)},
    NamedValue{.name = "pane_input", .value = static_cast<std::uint64_t>(ClientTag::pane_input)},
    NamedValue{.name = "pane_resize", .value = static_cast<std::uint64_t>(ClientTag::pane_resize)},
    NamedValue{.name = "frame_ack", .value = static_cast<std::uint64_t>(ClientTag::frame_ack)},
    NamedValue{.name = "request_snapshot", .value = static_cast<std::uint64_t>(ClientTag::request_snapshot)},
    NamedValue{.name = "detach_pane", .value = static_cast<std::uint64_t>(ClientTag::detach_pane)},
    NamedValue{.name = "runtime_stop", .value = static_cast<std::uint64_t>(ClientTag::runtime_stop)},
    NamedValue{.name = "request_tab_snapshot", .value = static_cast<std::uint64_t>(ClientTag::request_tab_snapshot)},
    NamedValue{.name = "create_pane", .value = static_cast<std::uint64_t>(ClientTag::create_pane)},
    NamedValue{.name = "close_pane", .value = static_cast<std::uint64_t>(ClientTag::close_pane)},
    NamedValue{.name = "query_history", .value = static_cast<std::uint64_t>(ClientTag::query_history)},
    NamedValue{.name = "request_workspace_snapshot", .value = static_cast<std::uint64_t>(ClientTag::request_workspace_snapshot)},
    NamedValue{.name = "create_tab", .value = static_cast<std::uint64_t>(ClientTag::create_tab)},
    NamedValue{.name = "rename_tab", .value = static_cast<std::uint64_t>(ClientTag::rename_tab)},
    NamedValue{.name = "close_tab", .value = static_cast<std::uint64_t>(ClientTag::close_tab)},
    NamedValue{.name = "move_tab", .value = static_cast<std::uint64_t>(ClientTag::move_tab)},
    NamedValue{.name = "request_graphics_snapshot", .value = static_cast<std::uint64_t>(ClientTag::request_graphics_snapshot)},
    NamedValue{.name = "graphics_credit", .value = static_cast<std::uint64_t>(ClientTag::graphics_credit)},
    NamedValue{.name = "configure_graphics", .value = static_cast<std::uint64_t>(ClientTag::configure_graphics)},
    NamedValue{.name = "request_runtime_state", .value = static_cast<std::uint64_t>(ClientTag::request_runtime_state)},
    NamedValue{.name = "create_workspace", .value = static_cast<std::uint64_t>(ClientTag::create_workspace)},
    NamedValue{.name = "rename_workspace", .value = static_cast<std::uint64_t>(ClientTag::rename_workspace)},
    NamedValue{.name = "set_pane_viewport", .value = static_cast<std::uint64_t>(ClientTag::set_pane_viewport)},
    NamedValue{.name = "copy_selection", .value = static_cast<std::uint64_t>(ClientTag::copy_selection)},
    NamedValue{.name = "show_notification", .value = static_cast<std::uint64_t>(ClientTag::show_notification)},
    NamedValue{.name = "update_client_layout", .value = static_cast<std::uint64_t>(ClientTag::update_client_layout)},
    NamedValue{.name = "acknowledge_agent", .value = static_cast<std::uint64_t>(ClientTag::acknowledge_agent)},
    NamedValue{.name = "query_agents", .value = static_cast<std::uint64_t>(ClientTag::query_agents)},
    NamedValue{.name = "read_pane", .value = static_cast<std::uint64_t>(ClientTag::read_pane)},
    NamedValue{.name = "send_pane_text", .value = static_cast<std::uint64_t>(ClientTag::send_pane_text)},
    NamedValue{.name = "report_agent_session", .value = static_cast<std::uint64_t>(ClientTag::report_agent_session)},
    NamedValue{.name = "report_agent", .value = static_cast<std::uint64_t>(ClientTag::report_agent)},
    NamedValue{.name = "search_pane", .value = static_cast<std::uint64_t>(ClientTag::search_pane)},
    NamedValue{.name = "import_history", .value = static_cast<std::uint64_t>(ClientTag::import_history)},
    NamedValue{.name = "delete_history", .value = static_cast<std::uint64_t>(ClientTag::delete_history)},
    NamedValue{.name = "prune_history", .value = static_cast<std::uint64_t>(ClientTag::prune_history)},
    NamedValue{.name = "read_history_output", .value = static_cast<std::uint64_t>(ClientTag::read_history_output)},
    NamedValue{.name = "history_stats", .value = static_cast<std::uint64_t>(ClientTag::history_stats)},
    NamedValue{.name = "request_pane_focus", .value = static_cast<std::uint64_t>(ClientTag::request_pane_focus)},
    NamedValue{.name = "complete_pane_focus", .value = static_cast<std::uint64_t>(ClientTag::complete_pane_focus)},
    NamedValue{.name = "suggest_command", .value = static_cast<std::uint64_t>(ClientTag::suggest_command)},
    NamedValue{.name = "report_agent_command", .value = static_cast<std::uint64_t>(ClientTag::report_agent_command)},
    NamedValue{.name = "report_agent_title", .value = static_cast<std::uint64_t>(ClientTag::report_agent_title)},
    NamedValue{.name = "configure_terminal_colors", .value = static_cast<std::uint64_t>(ClientTag::configure_terminal_colors)},
    NamedValue{.name = "query_clients", .value = static_cast<std::uint64_t>(ClientTag::query_clients)},
    NamedValue{.name = "detach_client", .value = static_cast<std::uint64_t>(ClientTag::detach_client)},
    NamedValue{.name = "request_client_command", .value = static_cast<std::uint64_t>(ClientTag::request_client_command)},
    NamedValue{.name = "complete_client_command", .value = static_cast<std::uint64_t>(ClientTag::complete_client_command)},
    NamedValue{.name = "open_editor", .value = static_cast<std::uint64_t>(ClientTag::open_editor)},
    NamedValue{.name = "find_paths", .value = static_cast<std::uint64_t>(ClientTag::find_paths)},
    NamedValue{.name = "register_worktree", .value = static_cast<std::uint64_t>(ClientTag::register_worktree)},
    NamedValue{.name = "launch_worktree", .value = static_cast<std::uint64_t>(ClientTag::launch_worktree)},
    NamedValue{.name = "forget_worktree", .value = static_cast<std::uint64_t>(ClientTag::forget_worktree)},
    NamedValue{.name = "interrupt_agent", .value = static_cast<std::uint64_t>(ClientTag::interrupt_agent)},
    NamedValue{.name = "report_agent_progress", .value = static_cast<std::uint64_t>(ClientTag::report_agent_progress)},
    NamedValue{.name = "launch_tab", .value = static_cast<std::uint64_t>(ClientTag::launch_tab)},
    NamedValue{.name = "verify_pane_descent", .value = static_cast<std::uint64_t>(ClientTag::verify_pane_descent)},
    NamedValue{.name = "report_limit", .value = static_cast<std::uint64_t>(ClientTag::report_limit)},
    NamedValue{.name = "query_limits", .value = static_cast<std::uint64_t>(ClientTag::query_limits)},
    NamedValue{.name = "configure_frame_interval", .value = static_cast<std::uint64_t>(ClientTag::configure_frame_interval)},
    NamedValue{.name = "hold_tab", .value = static_cast<std::uint64_t>(ClientTag::hold_tab)},
    NamedValue{.name = "execution_request", .value = static_cast<std::uint64_t>(ClientTag::execution_request)},
    NamedValue{.name = "configure_pane_desktop", .value = static_cast<std::uint64_t>(ClientTag::configure_pane_desktop)},
    NamedValue{.name = "complete_clipboard_desktop", .value = static_cast<std::uint64_t>(ClientTag::complete_clipboard_desktop)},
    NamedValue{.name = "paste_pane_clipboard", .value = static_cast<std::uint64_t>(ClientTag::paste_pane_clipboard)},
    NamedValue{.name = "read_runtime_clipboard", .value = static_cast<std::uint64_t>(ClientTag::read_runtime_clipboard)},
};

inline constexpr std::array server_messages{
    NamedValue{.name = "pane_opened", .value = static_cast<std::uint64_t>(ServerTag::pane_opened)},
    NamedValue{.name = "pane_frame", .value = static_cast<std::uint64_t>(ServerTag::pane_frame)},
    NamedValue{.name = "pane_exited", .value = static_cast<std::uint64_t>(ServerTag::pane_exited)},
    NamedValue{.name = "request_failed", .value = static_cast<std::uint64_t>(ServerTag::request_failed)},
    NamedValue{.name = "runtime_stopping", .value = static_cast<std::uint64_t>(ServerTag::runtime_stopping)},
    NamedValue{.name = "tab_snapshot", .value = static_cast<std::uint64_t>(ServerTag::tab_snapshot)},
    NamedValue{.name = "history_results", .value = static_cast<std::uint64_t>(ServerTag::history_results)},
    NamedValue{.name = "workspace_snapshot", .value = static_cast<std::uint64_t>(ServerTag::workspace_snapshot)},
    NamedValue{.name = "tab_created", .value = static_cast<std::uint64_t>(ServerTag::tab_created)},
    NamedValue{.name = "tab_renamed", .value = static_cast<std::uint64_t>(ServerTag::tab_renamed)},
    NamedValue{.name = "tab_closed", .value = static_cast<std::uint64_t>(ServerTag::tab_closed)},
    NamedValue{.name = "tab_moved", .value = static_cast<std::uint64_t>(ServerTag::tab_moved)},
    NamedValue{.name = "graphics_snapshot", .value = static_cast<std::uint64_t>(ServerTag::graphics_snapshot)},
    NamedValue{.name = "graphics_image", .value = static_cast<std::uint64_t>(ServerTag::graphics_image)},
    NamedValue{.name = "graphics_image_chunk", .value = static_cast<std::uint64_t>(ServerTag::graphics_image_chunk)},
    NamedValue{.name = "graphics_placement", .value = static_cast<std::uint64_t>(ServerTag::graphics_placement)},
    NamedValue{.name = "graphics_delete_image", .value = static_cast<std::uint64_t>(ServerTag::graphics_delete_image)},
    NamedValue{.name = "graphics_delete_placement", .value = static_cast<std::uint64_t>(ServerTag::graphics_delete_placement)},
    NamedValue{.name = "resync_required", .value = static_cast<std::uint64_t>(ServerTag::resync_required)},
    NamedValue{.name = "graphics_shared_image", .value = static_cast<std::uint64_t>(ServerTag::graphics_shared_image)},
    NamedValue{.name = "proxy_status", .value = static_cast<std::uint64_t>(ServerTag::proxy_status)},
    NamedValue{.name = "agent_snapshot", .value = static_cast<std::uint64_t>(ServerTag::agent_snapshot)},
    NamedValue{.name = "system_metrics", .value = static_cast<std::uint64_t>(ServerTag::system_metrics)},
    NamedValue{.name = "workspace_list", .value = static_cast<std::uint64_t>(ServerTag::workspace_list)},
    NamedValue{.name = "pane_cwd", .value = static_cast<std::uint64_t>(ServerTag::pane_cwd)},
    NamedValue{.name = "pane_clipboard", .value = static_cast<std::uint64_t>(ServerTag::pane_clipboard)},
    NamedValue{.name = "notification", .value = static_cast<std::uint64_t>(ServerTag::notification)},
    NamedValue{.name = "notification_shown", .value = static_cast<std::uint64_t>(ServerTag::notification_shown)},
    NamedValue{.name = "pane_foreground", .value = static_cast<std::uint64_t>(ServerTag::pane_foreground)},
    NamedValue{.name = "agent_sound", .value = static_cast<std::uint64_t>(ServerTag::agent_sound)},
    NamedValue{.name = "client_layout_snapshot", .value = static_cast<std::uint64_t>(ServerTag::client_layout_snapshot)},
    NamedValue{.name = "pane_text", .value = static_cast<std::uint64_t>(ServerTag::pane_text)},
    NamedValue{.name = "request_completed", .value = static_cast<std::uint64_t>(ServerTag::request_completed)},
    NamedValue{.name = "pane_title", .value = static_cast<std::uint64_t>(ServerTag::pane_title)},
    NamedValue{.name = "pane_matches", .value = static_cast<std::uint64_t>(ServerTag::pane_matches)},
    NamedValue{.name = "history_pruned", .value = static_cast<std::uint64_t>(ServerTag::history_pruned)},
    NamedValue{.name = "history_output", .value = static_cast<std::uint64_t>(ServerTag::history_output)},
    NamedValue{.name = "history_stats_result", .value = static_cast<std::uint64_t>(ServerTag::history_stats_result)},
    NamedValue{.name = "pane_focus_command", .value = static_cast<std::uint64_t>(ServerTag::pane_focus_command)},
    NamedValue{.name = "pane_focus_result", .value = static_cast<std::uint64_t>(ServerTag::pane_focus_result)},
    NamedValue{.name = "command_suggestion", .value = static_cast<std::uint64_t>(ServerTag::command_suggestion)},
    NamedValue{.name = "pane_progress", .value = static_cast<std::uint64_t>(ServerTag::pane_progress)},
    NamedValue{.name = "client_list", .value = static_cast<std::uint64_t>(ServerTag::client_list)},
    NamedValue{.name = "client_command", .value = static_cast<std::uint64_t>(ServerTag::client_command)},
    NamedValue{.name = "client_command_result", .value = static_cast<std::uint64_t>(ServerTag::client_command_result)},
    NamedValue{.name = "editor_opened", .value = static_cast<std::uint64_t>(ServerTag::editor_opened)},
    NamedValue{.name = "path_results", .value = static_cast<std::uint64_t>(ServerTag::path_results)},
    NamedValue{.name = "worktree_registered", .value = static_cast<std::uint64_t>(ServerTag::worktree_registered)},
    NamedValue{.name = "limit_list", .value = static_cast<std::uint64_t>(ServerTag::limit_list)},
    NamedValue{.name = "execution_reply", .value = static_cast<std::uint64_t>(ServerTag::execution_reply)},
    NamedValue{.name = "clipboard_desktop_request", .value = static_cast<std::uint64_t>(ServerTag::clipboard_desktop_request)},
    NamedValue{.name = "clipboard_desktop_execute", .value = static_cast<std::uint64_t>(ServerTag::clipboard_desktop_execute)},
    NamedValue{.name = "clipboard_desktop_cancel", .value = static_cast<std::uint64_t>(ServerTag::clipboard_desktop_cancel)},
    NamedValue{.name = "runtime_clipboard_chunk", .value = static_cast<std::uint64_t>(ServerTag::runtime_clipboard_chunk)},
};

inline constexpr std::array agent_statuses{
    NamedValue{.name = "unknown", .value = static_cast<std::uint64_t>(AgentStatus::unknown)},
    NamedValue{.name = "working", .value = static_cast<std::uint64_t>(AgentStatus::working)},
    NamedValue{.name = "blocked", .value = static_cast<std::uint64_t>(AgentStatus::blocked)},
    NamedValue{.name = "ready", .value = static_cast<std::uint64_t>(AgentStatus::ready)},
    NamedValue{.name = "failed", .value = static_cast<std::uint64_t>(AgentStatus::failed)},
    NamedValue{.name = "done", .value = static_cast<std::uint64_t>(AgentStatus::done)},
};

inline constexpr std::array bounds{
    NamedValue{.name = "max_frame_bytes", .value = max_payload_size},
    NamedValue{.name = "max_agent_snapshot_entries", .value = 64},
    NamedValue{.name = "max_pane_text_rows", .value = 2000},
    NamedValue{.name = "max_pane_text_bytes", .value = 262144},
    NamedValue{.name = "max_pane_text_input_bytes", .value = 65536},
    NamedValue{.name = "max_history_results", .value = 1000},
    NamedValue{.name = "max_clipboard_capture_bytes", .value = runtime_clipboard_max_bytes},
    NamedValue{.name = "max_clipboard_chunk_bytes", .value = runtime_clipboard_chunk_bytes},
};

inline void appendTable(std::string &output, std::span<const NamedValue> values, bool json) {
  for (const auto &entry : values) {
    if (json) {
      if (&entry != values.data()) {
        output += ',';
      }

      output += quoteJson(entry.name, JsonEscapes::control) + ':' + std::to_string(entry.value);
    } else {
      output += std::format("  0x{:02x}  {}\n", entry.value, entry.name);
    }
  }
}

inline int run(Arguments words) {
  if (words.empty() || std::string_view{words.front()} != "schema") {
    throw std::invalid_argument{"UnknownApiAction"};
  }

  bool json = false;
  for (const std::string_view word : words.subspan(1)) {
    if (word != "--json") {
      throw std::invalid_argument{"UnknownApiOption"};
    }

    json = true;
  }

  std::string fingerprint;
  for (const auto byte : handshake::schema_id) {
    fingerprint += std::format("{:02x}", byte);
  }

  std::string output;
  if (json) {
    output = "{\"schema_version\":" + quoteJson(nativeSchemaVersion()) + ",\"fingerprint\":" + quoteJson(fingerprint) + ",\"client_requests\":{";
    appendTable(output, client_requests, true);
    output += "},\"server_messages\":{";
    appendTable(output, server_messages, true);
    output += "},\"agent_statuses\":{";
    appendTable(output, agent_statuses, true);
    output += "},\"bounds\":{";
    appendTable(output, bounds, true);
    output += "}}\n";
  } else {
    output = std::format("schema {} fingerprint {}\n\nclient requests\n", nativeSchemaVersion(), fingerprint);
    appendTable(output, client_requests, false);
    output += "\nserver messages\n";
    appendTable(output, server_messages, false);
    output += "\nagent statuses\n";
    for (const auto &entry : agent_statuses) {
      output += std::format("  {}  {}\n", entry.value, entry.name);
    }

    output += "\nbounds\n";
    for (const auto &entry : bounds) {
      output += std::format("  {} = {}\n", entry.name, entry.value);
    }
  }

  writeText(output);
  return 0;
}

}
