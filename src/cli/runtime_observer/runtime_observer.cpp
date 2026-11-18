module telar.cli.runtime_observer;

import telar.sys.posix;
import telar.base.text.json;
import telar.cli.control_session;
import telar.client;
import telar.platform.error;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime::cli {

  std::string nativeSchemaVersion() {
    return {handshake::schema_id.begin(), handshake::schema_id.end()};
  }

  std::string proxyStatusJson(const ProxyStatus& status) {
    return std::format("{{\"active\":{},\"scope\":{},\"system_trusted\":{},\"port\":{},\"preferred_port\":{}}}", jsonBoolean(status.active), quoteJson(status.scope == ProxyScope::exact ? "exact" : "wildcard"), jsonBoolean(status.system_trusted), status.port ? std::to_string(*status.port) : "null", status.preferred_port ? std::to_string(*status.preferred_port) : "null");
  }

  std::string metricsJson(const SystemMetrics& metrics, bool event) {
    auto result = std::format("{{\"revision\":{},\"cpu_percent\":{},\"memory_used_decigib\":{},", metrics.revision, metrics.cpu_percent, metrics.memory_used_decigib);

    if (event) {
      result += std::format("\"has_battery\":{},\"battery_percent\":{},\"cpu_count\":{},\"memory_total_decigib\":{}}}", jsonBoolean(metrics.has_battery), metrics.battery_percent, metrics.cpu_count, metrics.memory_total_decigib);
    } else {
      result += std::format("\"memory_total_decigib\":{},\"cpu_count\":{},\"battery_percent\":{}}}", metrics.memory_total_decigib, metrics.cpu_count, metrics.has_battery ? std::to_string(metrics.battery_percent) : "null");
    }

    return result;
  }

  std::string workspaceEventJson(const WorkspaceList& list) {
    std::string result = std::format("{{\"type\":\"workspace_list\",\"revision\":{},\"data\":[", list.revision);

    for (const auto& entry : list.entries) {
      if (&entry != list.entries.data()) {
        result += ',';
      }

      result += std::format("{{\"workspace_id\":{},\"name\":{},\"path\":{},\"tab_count\":{},\"branch\":{},\"dirty\":{}}}", entry.workspace, quoteJson(entry.name), quoteJson(entry.path), entry.tab_count, quoteJson(entry.branch), jsonBoolean(entry.dirty));
    }

    return result + "]}";
  }

  std::string agentEventEntryJson(const AgentSnapshotEntry& agent) {
    constexpr ds::Array status_names{"unknown", "working", "blocked", "ready", "failed", "done"};
    constexpr ds::Array reason_names{"none", "permission", "question", "plan", "other"};
    const auto session = lowerHex(agent.session_id);

    constexpr auto escapes = JsonEscapes::control;

    return std::format("{{\"pane_id\":{},\"pane_generation\":{},\"workspace_id\":{},\"tab_id\":{},\"pane_index\":{},\"provider\":{},\"provider_index\":{},\"status\":{},\"workspace\":{},\"tab\":{},\"title\":{},\"cwd\":{},\"blocked_reason\":{},\"status_age_s\":{},\"worktree_id\":{},\"last_event\":{},\"plan\":{{\"done\":{},\"total\":{},\"step\":{}}},\"final_message\":{},\"session_id\":{}}}", agent.pane_id, agent.pane_generation, agent.location.workspace.id, agent.location.tab_id, agent.pane_index, quoteJson(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes), static_cast<Byte>(agent.provider), quoteJson(status_names.at(static_cast<std::size_t>(agent.status)), escapes), quoteJson(agent.workspace_label, escapes), quoteJson(agent.tab_label, escapes), quoteJson(agent.session_title, escapes), quoteJson(agent.cwd_label, escapes), quoteJson(reason_names.at(static_cast<std::size_t>(agent.blocked_reason)), escapes), agent.status_age_s, agent.work_tree, quoteJson(agent.last_event, escapes), agent.plan_done, agent.plan_total, quoteJson(agent.plan_step, escapes), quoteJson(agent.final_message, escapes), quoteJson(session, escapes));
  }

  std::string agentEventJson(const AgentSnapshot& snapshot) {
    std::string result = std::format("{{\"type\":\"agent_snapshot\",\"revision\":{},\"data\":[", snapshot.revision);

    for (const auto& entry : snapshot.entries) {
      if (&entry != snapshot.entries.data()) {
        result += ',';
      }

      result += agentEventEntryJson(entry);
    }

    return result + "]}";
  }

}

namespace telar::runtime::cli::api {

  struct NamedValue {
    std::string_view name;
    std::uint64_t value;
  };

  constexpr ds::Array client_requests{
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
      NamedValue{.name = "complete_words", .value = static_cast<std::uint64_t>(ClientTag::complete_words)},
      NamedValue{.name = "request_command_spec", .value = static_cast<std::uint64_t>(ClientTag::request_command_spec)},
      NamedValue{.name = "read_pane_rows", .value = static_cast<std::uint64_t>(ClientTag::read_pane_rows)},
      NamedValue{.name = "search_pane_rows", .value = static_cast<std::uint64_t>(ClientTag::search_pane_rows)},
      NamedValue{.name = "pane_command", .value = static_cast<std::uint64_t>(ClientTag::pane_command)},
      NamedValue{.name = "configure_shell_prompt", .value = static_cast<std::uint64_t>(ClientTag::configure_shell_prompt)},
  };

  constexpr ds::Array server_messages{
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
      NamedValue{.name = "pane_list", .value = static_cast<std::uint64_t>(ServerTag::pane_list)},
      NamedValue{.name = "pane_shell", .value = static_cast<std::uint64_t>(ServerTag::pane_shell)},
      NamedValue{.name = "pane_git", .value = static_cast<std::uint64_t>(ServerTag::pane_git)},
      NamedValue{.name = "completion_words", .value = static_cast<std::uint64_t>(ServerTag::completion_words)},
      NamedValue{.name = "pane_blocks", .value = static_cast<std::uint64_t>(ServerTag::pane_blocks)},
      NamedValue{.name = "command_spec", .value = static_cast<std::uint64_t>(ServerTag::command_spec)},
      NamedValue{.name = "pane_rows", .value = static_cast<std::uint64_t>(ServerTag::pane_rows)},
      NamedValue{.name = "pane_scrollback", .value = static_cast<std::uint64_t>(ServerTag::pane_scrollback)},
      NamedValue{.name = "pane_document", .value = static_cast<std::uint64_t>(ServerTag::pane_document)},
  };

  constexpr ds::Array agent_statuses{
      NamedValue{.name = "unknown", .value = static_cast<std::uint64_t>(AgentStatus::unknown)},
      NamedValue{.name = "working", .value = static_cast<std::uint64_t>(AgentStatus::working)},
      NamedValue{.name = "blocked", .value = static_cast<std::uint64_t>(AgentStatus::blocked)},
      NamedValue{.name = "ready", .value = static_cast<std::uint64_t>(AgentStatus::ready)},
      NamedValue{.name = "failed", .value = static_cast<std::uint64_t>(AgentStatus::failed)},
      NamedValue{.name = "done", .value = static_cast<std::uint64_t>(AgentStatus::done)},
  };

  constexpr ds::Array bounds{
      NamedValue{.name = "max_frame_bytes", .value = max_payload_size},
      NamedValue{.name = "max_agent_snapshot_entries", .value = 64},
      NamedValue{.name = "max_pane_list_entries", .value = max_pane_list_entries},
      NamedValue{.name = "max_pane_text_rows", .value = 2000},
      NamedValue{.name = "max_pane_rows_read", .value = ReadPaneRows::maximum_rows},
      NamedValue{.name = "max_pane_text_bytes", .value = 262144},
      NamedValue{.name = "max_pane_text_input_bytes", .value = 65536},
      NamedValue{.name = "max_history_results", .value = 1000},
      NamedValue{.name = "max_clipboard_capture_bytes", .value = runtime_clipboard_max_bytes},
      NamedValue{.name = "max_clipboard_chunk_bytes", .value = runtime_clipboard_chunk_bytes},
  };

  void appendTable(std::string& output, std::span<const NamedValue> values, bool json) {
    for (const auto& entry : values) {
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

  int run(Arguments words) {
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
      for (const auto& entry : agent_statuses) {
        output += std::format("  {}  {}\n", entry.value, entry.name);
      }

      output += "\nbounds\n";
      for (const auto& entry : bounds) {
        output += std::format("  {} = {}\n", entry.name, entry.value);
      }
    }

    writeText(output);
    return 0;
  }

}

namespace telar::runtime::cli::runtime_clipboard {

  int run(Memory& memory, const Options& options) {
    // Text may also contain terminal escape sequences. Reject before capturing.
    if (::isatty(STDOUT_FILENO)) {
      throw std::runtime_error{"Pipe clipboard content to a consumer or redirect stdout to a file"};
    }

    try {
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths paths{memory, server_options, process_environment};
      constexpr std::size_t frame_bytes = runtime_clipboard_chunk_bytes + 1024;
      ControlSession session{memory, paths.socket.data(), frame_bytes, 128};

      session.receiveTimeout(10);
      ReadRuntimeClipboard request;
      std::uint64_t total = 0;
      std::string mime;

      for (;;) {
        const auto chunk = session.template exchange<RuntimeClipboardChunk>(request);
        if (chunk.offset != request.offset) {
          throw std::runtime_error{"Clipboard chunk arrived out of sequence"};
        }

        if (request.transfer_id == 0) {
          request.transfer_id = chunk.transfer_id;
          total = chunk.total_bytes;
          mime = chunk.mime;
        } else if (chunk.transfer_id != request.transfer_id || chunk.total_bytes != total || chunk.mime != mime) {
          throw std::runtime_error{"Clipboard transfer metadata changed"};
        }

        writeBytes(STDOUT_FILENO, chunk.bytes);
        request.offset += chunk.bytes.size();
        if (request.offset == total) {
          return 0;
        }
      }
    } catch (const ControlFailure& error) {
      std::fprintf(stderr, "telar clipboard: %.*s\n", static_cast<int>(error.message().size()), error.message().data());
      return 1;
    }
  }

}

namespace telar::runtime::cli {

  void printRuntimeStatus(const ProxyStatus& status, bool json) {
    if (json) {
      writeText("{\"running\":true,\"schema_version\":" + quoteJson(nativeSchemaVersion()) + ",\"proxy\":" + proxyStatusJson(status) + "}\n");
      return;
    }

    auto output = std::format("Runtime: running\nSchema: {}\nProxy: {}\n", nativeSchemaVersion(), status.active ? "active" : "disabled");

    if (status.port) {
      if (!status.preferred_port) {
        output += std::format("Proxy port: {} (none remembered for this runtime)\n", *status.port);
      } else if (status.port == status.preferred_port) {
        output += std::format("Proxy port: {}\n", *status.port);
      } else {
        output += std::format("Proxy port: {} (warning: remembered port {} was held by another process; processes that inherited it do not reach this runtime)\n", *status.port, *status.preferred_port);
      }
    }

    output += std::format("Proxy scope: {}\nSystem trust: {}\n", status.scope == ProxyScope::exact ? "exact" : "wildcard", status.system_trusted ? "installed" : "absent");
    writeText(output);
  }

  void printRuntimeMetrics(const SystemMetrics& metrics, bool json) {
    if (json) {
      writeText(metricsJson(metrics, false) + "\n");
      return;
    }

    writeText(std::format("CPU: {}% of {}\nMemory: {}.{} of {}.{} GiB\nBattery: {}\n", metrics.cpu_percent, metrics.cpu_count, metrics.memory_used_decigib / 10, metrics.memory_used_decigib % 10, metrics.memory_total_decigib / 10, metrics.memory_total_decigib % 10, metrics.has_battery ? std::to_string(metrics.battery_percent) + "%" : "unavailable"));
  }

  std::string runtimeEventJson(std::span<const Byte> frame, DecodeStorage& storage) {
    switch (static_cast<ServerTag>(frame.front())) {
    case ServerTag::proxy_status:
      return "{\"type\":\"proxy_status\",\"data\":" + proxyStatusJson(Codec::decode<ProxyStatus>(frame, storage)) + "}";
    case ServerTag::system_metrics:
      return "{\"type\":\"system_metrics\",\"data\":" + metricsJson(Codec::decode<SystemMetrics>(frame, storage), true) + "}";
    case ServerTag::workspace_list:
      return workspaceEventJson(Codec::decode<WorkspaceList>(frame, storage));
    case ServerTag::agent_snapshot:
      return agentEventJson(Codec::decode<AgentSnapshot>(frame, storage));
    case ServerTag::runtime_stopping:
      Codec::decode<RuntimeStopping>(frame, storage);
      return "{\"type\":\"runtime_stopping\"}";
    case ServerTag::resync_required:
      Codec::decode<ResyncRequired>(frame, storage);
      return "{\"type\":\"resync_required\"}";
    default:
      return {};
    }
  }

  template <Allocator Memory>
  void observeRuntime(Memory& memory, const RuntimeOptions& options) {
    ServerOptions server_options{};

    server_options.socket = options.socket.valueOr("");
    const RuntimePaths paths{memory, server_options, process_environment};
    RuntimeConnection connection{paths.socket.data()};

    if (options.action != RuntimeOptions::Action::watch) {
      connection.receiveTimeout(30);
    }

    ds::Array<Byte, 32> outgoing;

    connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing.viewMut());
    ds::Vec<Byte, Memory> incoming{memory};

    incoming.resize(max_payload_size, Byte{});
    ds::Vec<Byte, Memory> decoded{memory};

    decoded.resize(max_payload_size, Byte{});
    std::uint64_t count = 0;

    for (;;) {
      const auto frame = connection.receive(incoming.viewMut());
      DecodeStorage storage{decoded.viewMut()};
      const auto tag = static_cast<ServerTag>(frame.front());
      if (tag == ServerTag::request_failed) {
        const auto failure = Codec::decode<RequestFailed>(frame, storage);

        throw ControlFailure{failure.code, failure.message};
      }

      if (options.action == RuntimeOptions::Action::watch) {
        const bool selected = !options.proxy_only || tag == ServerTag::proxy_status || tag == ServerTag::runtime_stopping || tag == ServerTag::resync_required;
        if (selected) {
          const auto event = runtimeEventJson(frame, storage);
          if (!event.empty()) {
            writeText(event + "\n");
            ++count;
          }
        }

        if (tag == ServerTag::resync_required) {
          throw std::runtime_error{"RuntimeResyncRequired"};
        }

        if (tag == ServerTag::runtime_stopping || (options.count && count >= *options.count)) {
          return;
        }
      } else if (tag == ServerTag::proxy_status && options.action == RuntimeOptions::Action::status) {
        printRuntimeStatus(Codec::decode<ProxyStatus>(frame, storage), options.json);
        return;
      } else if (tag == ServerTag::system_metrics && options.action == RuntimeOptions::Action::metrics) {
        printRuntimeMetrics(Codec::decode<SystemMetrics>(frame, storage), options.json);
        return;
      } else if (tag == ServerTag::runtime_stopping) {
        throw std::runtime_error{"RuntimeStopping"};
      }
    }
  }

  int runRuntime(Memory& memory, const RuntimeOptions& options) {
    try {
      observeRuntime(memory, options);
      return 0;
    } catch (const SystemError& error) {
      const bool timeout = error.code() == EAGAIN || error.code() == ETIMEDOUT;

      writeText(std::string{"telar runtime: "} + (timeout ? "RuntimeTimeout" : sys::errorName(error.code())) + "\n", STDERR_FILENO);
      return timeout ? 3 : 1;
    } catch (const std::exception& error) {
      const auto reason = commandErrorName(error);

      writeText("telar runtime: " + std::string{reason} + "\n", STDERR_FILENO);
      return reason == "RuntimeTimeout" ? 3 : 1;
    }
  }

}

namespace telar::runtime::cli::runtime_clipboard {

  Options Options::parse(Arguments words) {
    if (words.empty() || std::string_view{words.front()} != "get") {
      throw std::invalid_argument{"UnknownClipboardAction"};
    }

    Options options;
    Cursor cursor{words.subspan(1)};

    while (const auto word = cursor.next()) {
      if (*word == "--socket" && !options.socket) {
        options.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownClipboardOption"};
      }
    }

    return options;
  }

}

namespace telar::runtime::cli {

  RuntimeOptions RuntimeOptions::parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

    const std::string_view action = words.front();
    if (action != "status" && action != "metrics" && action != "watch") {
      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

    RuntimeOptions self{.action = action == "status" ? Action::status : action == "metrics" ? Action::metrics
                                                                                            : Action::watch};
    Cursor cursor{words.subspan(1)};

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json" || (self.action == Action::watch && arg == "--jsonl")) {
        if (self.json) {
          throw std::invalid_argument{"DuplicateJsonOption"};
        }

        self.json = true;
      } else if (arg == "--count" && self.action == Action::watch) {
        if (self.count) {
          throw std::invalid_argument{"DuplicateCountOption"};
        }

        self.count = number<std::uint32_t>(cursor.take("MissingCount"), "InvalidCount");
        if (*self.count == 0) {
          throw std::invalid_argument{"InvalidCount"};
        }
      } else if (arg == "--socket") {
        if (self.socket) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownRuntimeOption"};
      }
    }

    return self;
  }

}
