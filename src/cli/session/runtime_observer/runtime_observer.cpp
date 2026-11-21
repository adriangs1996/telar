module telar.cli.session.runtime_observer;

import telar.sys.posix;
import telar.base.text.json;
import telar.cli.session.control_session;
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
import telar.base.text;

namespace telar::runtime::cli {

  namespace {

    std::string_view nativeSchemaVersion() {
      return textBytes(handshake::schema_id.view());
    }

    void appendProxyStatusJson(Text& output, const ProxyStatus& status) {
      ds::formatTo(output, R"({{"active":{},"scope":{},"system_trusted":{},"port":{},"preferred_port":{}}})", jsonBoolean(status.active), quoteJson(status.scope == ProxyScope::exact ? "exact" : "wildcard"), jsonBoolean(status.system_trusted), orNull(status.port), orNull(status.preferred_port));
    }

    void appendMetricsJson(Text& output, const SystemMetrics& metrics, bool event) {
      ds::formatTo(output, R"({{"revision":{},"cpu_percent":{},"memory_used_decigib":{},)", metrics.revision, metrics.cpu_percent, metrics.memory_used_decigib);
      if (event) {
        ds::formatTo(output, R"("has_battery":{},"battery_percent":{},"cpu_count":{},"memory_total_decigib":{}}})", jsonBoolean(metrics.has_battery), metrics.battery_percent, metrics.cpu_count, metrics.memory_total_decigib);
      } else {
        ds::formatTo(output, R"("memory_total_decigib":{},"cpu_count":{},"battery_percent":{}}})", metrics.memory_total_decigib, metrics.cpu_count, orNull(metrics.has_battery ? ds::Option{metrics.battery_percent} : ds::none));
      }
    }

    void appendWorkspaceEventJson(Text& output, const WorkspaceList& list) {
      ds::formatTo(output, R"({{"type":"workspace_list","revision":{},"data":[)", list.revision);
      for (const auto& entry : list.entries) {
        if (&entry != list.entries.data()) {
          output.push(',');
        }

        ds::formatTo(output, R"({{"workspace_id":{},"name":{},"path":{},"tab_count":{},"branch":{},"dirty":{}}})", entry.workspace, quoteJson(entry.name), quoteJson(entry.path), entry.tab_count, quoteJson(entry.branch), jsonBoolean(entry.dirty));
      }

      output.append("]}");
    }

    void appendAgentEventEntryJson(Text& output, const AgentSnapshotEntry& agent) {
      constexpr auto escapes = JsonEscapes::control;
      ds::Array<char, 2 * agent.session_id.size()> session{};
      const auto session_text = encodeLowerHex(agent.session_id.view(), session.viewMut());

      ds::formatTo(output, R"({{"pane_id":{},"pane_generation":{},"workspace_id":{},"tab_id":{},"pane_index":{},"provider":{},"provider_index":{},"status":{},"workspace":{},"tab":{},"title":{},"cwd":{},"blocked_reason":{},"status_age_s":{},"worktree_id":{},"last_event":{},"plan":{{"done":{},"total":{},"step":{}}},"final_message":{},"session_id":{}}})", agent.pane_id, agent.pane_generation, agent.location.workspace.id, agent.location.tab_id, agent.pane_index, quoteJson(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes), static_cast<Byte>(agent.provider), quoteJson(agentStatusName(agent.status), escapes), quoteJson(agent.workspace_label, escapes), quoteJson(agent.tab_label, escapes), quoteJson(agent.session_title, escapes), quoteJson(agent.cwd_label, escapes), quoteJson(agentBlockedReasonName(agent.blocked_reason), escapes), agent.status_age_s, agent.work_tree, quoteJson(agent.last_event, escapes), agent.plan_done, agent.plan_total, quoteJson(agent.plan_step, escapes), quoteJson(agent.final_message, escapes), quoteJson(session_text, escapes));
    }

    void appendAgentEventJson(Text& output, const AgentSnapshot& snapshot) {
      ds::formatTo(output, R"({{"type":"agent_snapshot","revision":{},"data":[)", snapshot.revision);
      for (const auto& entry : snapshot.entries) {
        if (&entry != snapshot.entries.data()) {
          output.push(',');
        }

        appendAgentEventEntryJson(output, entry);
      }

      output.append("]}");
    }

  }

}

namespace telar::runtime::cli::api {

  namespace {

    struct NamedValue {
      std::string_view name;
      std::uint64_t value;
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

    // Every value of `Enum` the wire names, with its name: `name` is the wire's own function, so
    // the contract this prints cannot differ from the protocol.
    template <typename Enum, typename Name, typename Row>
    void eachNamed(Name name, Row row) {
      for (unsigned value = 0; value <= std::numeric_limits<Byte>::max(); ++value) {
        if (const auto text = name(static_cast<Enum>(value)); !text.empty()) { // NOLINT(clang-analyzer-optin.core.EnumCastOutOfRange): every byte is tried, and `name` tells the ones the wire names
          row(text, value);
        }
      }
    }

    template <typename Enum, typename Name>
    void appendNames(Text& output, Name name, bool json) {
      bool first = true;

      eachNamed<Enum>(name, [&](std::string_view text, unsigned value) {
        if (json) {
          if (!std::exchange(first, false)) {
            output.push(',');
          }

          ds::formatTo(output, "{}:{}", quoteJson(text, JsonEscapes::control), value);
        } else {
          ds::formatTo(output, "  0x{:02x}  {}\n", value, text);
        }
      });
    }

  }

  int run(Memory& memory, Arguments words) {
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

    const auto fingerprint = lowerHex(handshake::schema_id.view());
    Text output{memory};

    if (json) {
      ds::formatTo(output, R"({{"schema_version":{},"fingerprint":"{}","client_requests":{{)", quoteJson(nativeSchemaVersion()), fingerprint);
      appendNames<ClientTag>(output, clientTagName, true);
      output.append("},\"server_messages\":{");
      appendNames<ServerTag>(output, serverTagName, true);
      output.append("},\"agent_statuses\":{");
      appendNames<AgentStatus>(output, agentStatusName, true);
      output.append("},\"bounds\":{");
      for (const auto& entry : bounds) {
        if (&entry != bounds.data()) {
          output.push(',');
        }

        ds::formatTo(output, "{}:{}", quoteJson(entry.name, JsonEscapes::control), entry.value);
      }

      output.append("}}\n");
    } else {
      ds::formatTo(output, "schema {} fingerprint {}\n\nclient requests\n", nativeSchemaVersion(), fingerprint);
      appendNames<ClientTag>(output, clientTagName, false);
      output.append("\nserver messages\n");
      appendNames<ServerTag>(output, serverTagName, false);
      output.append("\nagent statuses\n");
      eachNamed<AgentStatus>(agentStatusName, [&](std::string_view text, unsigned value) {
        ds::formatTo(output, "  {}  {}\n", value, text);
      });

      output.append("\nbounds\n");
      for (const auto& entry : bounds) {
        ds::formatTo(output, "  {} = {}\n", entry.name, entry.value);
      }
    }

    writeText(output);
    return 0;
  }

}

namespace telar::runtime::cli::runtime_clipboard {

  int run(Memory& memory, const Options& options) {
    // Text may also contain terminal escape sequences. Reject before capturing.
    if (::isatty(STDOUT_FILENO) != 0) {
      throw std::runtime_error{"Pipe clipboard content to a consumer or redirect stdout to a file"};
    }

    try {
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};
      constexpr std::size_t frame_bytes = runtime_clipboard_chunk_bytes + 1024;
      constexpr std::size_t request_bytes = 128;
      constexpr unsigned reply_timeout_seconds = 10;
      ControlSession session{memory, paths.socket.data(), frame_bytes, request_bytes};

      session.receiveTimeout(reply_timeout_seconds);
      ReadRuntimeClipboard request;
      std::uint64_t total = 0;
      Text mime{memory};

      for (;;) {
        const auto chunk = session.template exchange<RuntimeClipboardChunk>(request);
        if (chunk.offset != request.offset) {
          throw std::runtime_error{"Clipboard chunk arrived out of sequence"};
        }

        if (request.transfer_id == 0) {
          request.transfer_id = chunk.transfer_id;
          total = chunk.total_bytes;
          mime.assign(chunk.mime);
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
      writeText(ds::format(memory, "telar clipboard: {}\n", error.message()), STDERR_FILENO);
      return 1;
    }
  }

}

namespace telar::runtime::cli {

  namespace {

    void printRuntimeStatus(Memory& memory, const ProxyStatus& status, bool json) {
      Text output{memory};

      if (json) {
        ds::formatTo(output, R"({{"running":true,"schema_version":{},"proxy":)", quoteJson(nativeSchemaVersion()));
        appendProxyStatusJson(output, status);
        output.append("}\n");
        writeText(output);
        return;
      }

      ds::formatTo(output, "Runtime: running\nSchema: {}\nProxy: {}\n", nativeSchemaVersion(), status.active ? "active" : "disabled");
      if (status.port) {
        if (!status.preferred_port) {
          ds::formatTo(output, "Proxy port: {} (none remembered for this runtime)\n", *status.port);
        } else if (status.port == status.preferred_port) {
          ds::formatTo(output, "Proxy port: {}\n", *status.port);
        } else {
          ds::formatTo(output, "Proxy port: {} (warning: remembered port {} was held by another process; processes that inherited it do not reach this runtime)\n", *status.port, *status.preferred_port);
        }
      }

      ds::formatTo(output, "Proxy scope: {}\nSystem trust: {}\n", status.scope == ProxyScope::exact ? "exact" : "wildcard", status.system_trusted ? "installed" : "absent");
      writeText(output);
    }

    void printRuntimeMetrics(Memory& memory, const SystemMetrics& metrics, bool json) {
      Text output{memory};

      if (json) {
        appendMetricsJson(output, metrics, false);
        output.push('\n');
        writeText(output);
        return;
      }

      constexpr std::uint32_t decigib_per_gib = 10;

      ds::formatTo(output, "CPU: {}% of {}\nMemory: {}.{} of {}.{} GiB\nBattery: ", metrics.cpu_percent, metrics.cpu_count, metrics.memory_used_decigib / decigib_per_gib, metrics.memory_used_decigib % decigib_per_gib, metrics.memory_total_decigib / decigib_per_gib, metrics.memory_total_decigib % decigib_per_gib);
      if (metrics.has_battery) {
        ds::formatTo(output, "{}%\n", metrics.battery_percent);
      } else {
        output.append("unavailable\n");
      }

      writeText(output);
    }

    // Appends the frame as one JSON event line, and says whether the frame is one the watch reports.
    bool appendRuntimeEventJson(Text& output, std::span<const Byte> frame, DecodeStorage& storage) {
      const auto tag = static_cast<ServerTag>(frame.front());
      if (tag == ServerTag::proxy_status) {
        output.append(R"({"type":"proxy_status","data":)");
        appendProxyStatusJson(output, Codec::decode<ProxyStatus>(frame, storage));
        output.push('}');
        return true;
      }

      if (tag == ServerTag::system_metrics) {
        output.append(R"({"type":"system_metrics","data":)");
        appendMetricsJson(output, Codec::decode<SystemMetrics>(frame, storage), true);
        output.push('}');
        return true;
      }

      if (tag == ServerTag::workspace_list) {
        appendWorkspaceEventJson(output, Codec::decode<WorkspaceList>(frame, storage));
        return true;
      }

      if (tag == ServerTag::agent_snapshot) {
        appendAgentEventJson(output, Codec::decode<AgentSnapshot>(frame, storage));
        return true;
      }

      if (tag == ServerTag::runtime_stopping) {
        Codec::decode<RuntimeStopping>(frame, storage);
        output.append(R"({"type":"runtime_stopping"})");
        return true;
      }

      if (tag == ServerTag::resync_required) {
        Codec::decode<ResyncRequired>(frame, storage);
        output.append(R"({"type":"resync_required"})");
        return true;
      }

      return false;
    }

    // Reports a frame the watch receives, and says whether the watch ends with it.
    template <Allocator Memory>
    bool watchFrame(Memory& memory, const RuntimeOptions& options, std::span<const Byte> frame, DecodeStorage& storage, std::uint64_t& count) {
      const auto tag = static_cast<ServerTag>(frame.front());
      const bool selected = !options.proxy_only || tag == ServerTag::proxy_status || tag == ServerTag::runtime_stopping || tag == ServerTag::resync_required;
      if (selected) {
        Text event{memory};
        if (appendRuntimeEventJson(event, frame, storage)) {
          event.push('\n');
          writeText(event);
          ++count;
        }
      }

      if (tag == ServerTag::resync_required) {
        throw std::runtime_error{"RuntimeResyncRequired"};
      }

      return tag == ServerTag::runtime_stopping || (options.count && count >= *options.count);
    }

    // Answers a status or metrics query from a frame, and says whether the frame answered it.
    template <Allocator Memory>
    bool answerFrame(Memory& memory, const RuntimeOptions& options, std::span<const Byte> frame, DecodeStorage& storage) {
      const auto tag = static_cast<ServerTag>(frame.front());
      if (tag == ServerTag::proxy_status && options.action == RuntimeOptions::Action::status) {
        printRuntimeStatus(memory, Codec::decode<ProxyStatus>(frame, storage), options.json);
        return true;
      }

      if (tag == ServerTag::system_metrics && options.action == RuntimeOptions::Action::metrics) {
        printRuntimeMetrics(memory, Codec::decode<SystemMetrics>(frame, storage), options.json);
        return true;
      }

      if (tag == ServerTag::runtime_stopping) {
        throw std::runtime_error{"RuntimeStopping"};
      }

      return false;
    }

    template <Allocator Memory>
    void observeRuntime(Memory& memory, const RuntimeOptions& options) {
      constexpr unsigned reply_timeout_seconds = 30;
      constexpr std::size_t request_bytes = 32;
      ServerOptions server_options{};

      server_options.socket = options.socket.valueOr("");
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};
      RuntimeConnection connection{paths.socket.data()};

      if (options.action != RuntimeOptions::Action::watch) {
        connection.receiveTimeout(reply_timeout_seconds);
      }

      ds::Array<Byte, request_bytes> outgoing{};

      connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing.viewMut());
      ds::Vec<Byte, Memory> incoming{memory};

      incoming.resize(max_payload_size, Byte{});
      ds::Vec<Byte, Memory> decoded{memory};

      decoded.resize(max_payload_size, Byte{});
      std::uint64_t count = 0;

      for (;;) {
        const auto frame = connection.receive(incoming.viewMut());
        DecodeStorage storage{decoded.viewMut()};

        if (static_cast<ServerTag>(frame.front()) == ServerTag::request_failed) {
          const auto failure = Codec::decode<RequestFailed>(frame, storage);

          throw ControlFailure{failure.code, failure.message};
        }

        const bool done = options.action == RuntimeOptions::Action::watch ? watchFrame(memory, options, frame, storage, count) : answerFrame(memory, options, frame, storage);
        if (done) {
          return;
        }
      }
    }

  }

  int runRuntime(Memory& memory, const RuntimeOptions& options) {
    try {
      observeRuntime(memory, options);
      return 0;
    } catch (const SystemError& error) {
      const bool timeout = error.code() == EAGAIN || error.code() == ETIMEDOUT;

      writeText(ds::format(memory, "telar runtime: {}\n", timeout ? std::string_view{"RuntimeTimeout"} : std::string_view{sys::errorName(error.code())}), STDERR_FILENO);
      return timeout ? 3 : 1;
    } catch (const std::exception& error) {
      const auto reason = commandErrorName(error);

      writeText(ds::format(memory, "telar runtime: {}\n", reason), STDERR_FILENO);
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

  namespace {

    RuntimeOptions::Action parseRuntimeAction(std::string_view action) {
      if (action == "status") {
        return RuntimeOptions::Action::status;
      }

      if (action == "metrics") {
        return RuntimeOptions::Action::metrics;
      }

      if (action == "watch") {
        return RuntimeOptions::Action::watch;
      }

      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

  }

  RuntimeOptions RuntimeOptions::parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

    RuntimeOptions self{.action = parseRuntimeAction(words.front())};
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
