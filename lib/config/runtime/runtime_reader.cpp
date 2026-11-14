module telar.config.runtime;

import std;
import telar.ghostty.unicode;
import telar.lua;
import telar.tbc;

// Apart from runtime.cpp because an agent icon is measured with libghostty-vt: only the processes
// that read the `runtime` table pull this unit in, and the CLI, which reads the manifests, links no
// libghostty-vt.
namespace telar::runtime::config {

  class AgentReader {
  public:
    // Fills the manifests and tells the notices about limits it reaches, region `a`.
    inline explicit AgentReader(tbc::view<AgentManifests&, tbc::lt::a> manifests, tbc::view<LimitNotices&, tbc::lt::a> limits)
        : manifests_(manifests),
          limits_(limits) {}

    inline void read(const lua::Value& agents) {
      if (!agents.present()) {
        return;
      }

      const auto count = agents.arraySize();
      std::size_t dropped = 0;

      for (std::size_t position = 1; position <= count; ++position) {
        const auto entry = agents.element(static_cast<lua_Integer>(position));

        entry.onlyFields({"name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt", "display_name", "placeholder", "icon", "attachments", "command_tools"});
        auto* manifest = manifests_.tryAdd(entry.field("name").string());
        if (manifest == nullptr) {
          ++dropped;
          continue;
        }

        paths(entry.field("process_names"), manifest->process_names);
        paths(entry.field("process_paths"), manifest->process_paths);
        phrases(entry.field("brand"), manifest->brand);
        phrases(entry.field("identity"), manifest->identity);
        phrases(entry.field("working"), manifest->working);
        phrases(entry.field("blocked"), manifest->blocked);
        phrases(entry.field("ready_prompt"), manifest->ready_prompt);
        commandTools(entry.field("command_tools"), *manifest);
        presentation(entry, *manifest);
      }

      if (dropped != 0) {
        limits_.add({"agent_manifest.max_custom_agents", "agents", 27, 27 + dropped, {}});
      }
    }

  private:
    inline static tbc::view<std::string_view, tbc::lt::a> printable(const lua::Value& value) {
      const auto text = value.string();

      validateUtf8(text);
      if (text.empty() || std::ranges::any_of(text, [](unsigned char byte) {
            return byte < 0x20 || byte == 0x7f;
          })) {
        value.fail("must be a printable string");
      }

      return text;
    }

    template <std::size_t Capacity, std::size_t TextCapacity>
    inline void list(const lua::Value& value, ManifestTextList<Capacity, TextCapacity>& destination, tbc::view<LimitReach, tbc::lt::a> entries_limit, tbc::view<LimitReach, tbc::lt::a> bytes_limit) {
      if (!value.present()) {
        return;
      }

      const auto count = value.arraySize();

      for (std::size_t position = 1; position <= count; ++position) {
        const auto text = printable(value.element(static_cast<lua_Integer>(position)));
        if (text.size() > TextCapacity) {
          bytes_limit.requested = text.size();
          limits_.add(bytes_limit);
        } else if (destination.entries().size() == Capacity) {
          entries_limit.requested = Capacity + count - position + 1;
          limits_.add(entries_limit);
          return;
        } else {
          destination.append(text);
        }
      }
    }

    inline void paths(const lua::Value& value, ManifestTextList<8, 128>& destination) {
      list(value, destination, {"agent_manifest.max_paths", "entries", 8, {}, {}}, {"agent_manifest.max_path_bytes", "bytes", 128, {}, {}});
    }

    inline void phrases(const lua::Value& value, ManifestTextList<16, 64>& destination) {
      list(value, destination, {"agent_manifest.max_phrases", "phrases", 16, {}, {}}, {"agent_manifest.max_phrase_bytes", "bytes", 64, {}, {}});
    }

    inline void commandTools(const lua::Value& value, AgentManifest& manifest) {
      if (!value.present()) {
        return;
      }

      const auto count = value.arraySize();

      for (std::size_t position = 1; position <= count; ++position) {
        const auto mapping = value.element(static_cast<lua_Integer>(position));

        mapping.onlyFields({"tool", "field"});
        const auto tool = mapping.field("tool").string();
        const auto field = mapping.field("field").string();
        if (tool.empty() || field.empty()) {
          mapping.fail("requires nonempty tool and field strings");
        }

        if (tool.size() > 64 || field.size() > 32) {
          if (tool.size() > 64) {
            limits_.add({"agent_manifest.max_tool_name_bytes", "bytes", 64, tool.size(), {}});
          }

          if (field.size() > 32) {
            limits_.add({"agent_manifest.max_command_field_bytes", "bytes", 32, field.size(), {}});
          }
        } else if (manifest.tool_count == manifest.command_tools.size()) {
          limits_.add({"agent_manifest.max_command_tools", "command tools", 8, 8 + count - position + 1, {}});
          return;
        } else {
          manifest.addCommandTool(tool, field);
        }
      }
    }

    template <std::size_t Capacity>
    inline static void text(const lua::Value& value, FixedText<Capacity>& destination) {
      if (value.present()) {
        destination.assign(printable(value));
      }
    }

    inline static unsigned iconWidth(std::string_view text) noexcept {
      std::array<std::uint32_t, 8> codepoints;
      std::size_t count = 0;

      for (std::size_t offset = 0; offset < text.size();) {
        const auto lead = static_cast<unsigned char>(text[offset++]);
        const unsigned continuation = lead < 0x80 ? 0 : lead < 0xe0 ? 1
                                                    : lead < 0xf0   ? 2
                                                                    : 3;
        std::uint32_t codepoint = continuation == 0 ? lead : lead & (0x7f >> continuation);

        for (unsigned index = 0; index < continuation; ++index) {
          codepoint = (codepoint << 6) | (static_cast<unsigned char>(text[offset++]) & 0x3f);
        }

        codepoints[count++] = codepoint;
      }

      unsigned width = 0;

      for (std::size_t offset = 0; offset < count;) {
        std::uint8_t cluster_width = 0;

        offset += ghostty_unicode_grapheme_width(codepoints.data() + offset, count - offset, &cluster_width);
        width += std::max<unsigned>(1, cluster_width);
      }

      return width;
    }

    inline static void presentation(const lua::Value& entry, AgentManifest& manifest) {
      text(entry.field("display_name"), manifest.display_name);
      text(entry.field("placeholder"), manifest.placeholder);
      const auto icon = entry.field("icon");
      if (icon.present()) {
        const auto value = printable(icon);
        if (value.size() > 8 || iconWidth(value) != 1) {
          icon.fail("must fit in eight bytes and exactly one cell");
        }

        manifest.icon.assign(value);
      }

      const auto attachments = entry.field("attachments");
      if (!attachments.present()) {
        return;
      }

      const auto policy = printable(attachments);

      for (const auto& [name, kind] : std::array<std::pair<std::string_view, AgentAttachmentMarkers>, 4>{{{"none", AgentAttachmentMarkers::none}, {"ordered", AgentAttachmentMarkers::ordered}, {"stable_number", AgentAttachmentMarkers::stable_number}, {"pasted_path", AgentAttachmentMarkers::pasted_path}}}) {
        if (name == policy) {
          manifest.attachments = kind;
          return;
        }
      }

      attachments.fail("must be none, ordered, stable_number or pasted_path");
    }

    tbc::view<AgentManifests&, tbc::lt::a> manifests_;
    tbc::view<LimitNotices&, tbc::lt::a> limits_;
  };

  template <Allocator Memory>
  RuntimeReader<Memory>::RuntimeReader(RuntimeValues<Memory>& values)
      : values_(values) {}

  template <Allocator Memory>
  void RuntimeReader<Memory>::read(const lua::Value& runtime) {
    if (!runtime.present()) {
      return;
    }

    runtime.onlyFields({"history", "session", "engine", "agent_descriptions", "graphics", "proxy", "agents", "control_queries", "shell_integration", "ssh_integration"});
    values_.shell_integration = runtime.field("shell_integration").boolean(values_.shell_integration);
    values_.ssh_integration = runtime.field("ssh_integration").boolean(values_.ssh_integration);
    history(runtime.field("history"));
    session(runtime.field("session"));
    helper(runtime.field("engine"), values_.engine, true);
    helper(runtime.field("agent_descriptions"), values_.descriptions, false);
    AgentReader{values_.manifests, values_.limits}.read(runtime.field("agents"));
    graphics(runtime.field("graphics"));
    readControlPolicy(runtime.field("control_queries"), values_.control_policy);
    ProxyReader<Memory>::read(runtime.field("proxy"), values_.proxy);
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::graphics(const lua::Value& table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"pane_mib", "global_mib"});
    values_.graphics.pane_bytes = table.field("pane_mib").boundedInteger(values_.graphics.pane_bytes / GraphicsLimits::mebibyte, 2, 256) * GraphicsLimits::mebibyte;
    values_.graphics.global_bytes = table.field("global_mib").boundedInteger(values_.graphics.global_bytes / GraphicsLimits::mebibyte, 2, 512) * GraphicsLimits::mebibyte;
    if (values_.graphics.global_bytes < values_.graphics.pane_bytes) {
      table.fail("global memory must cover the pane memory limit");
    }
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::path(const lua::Value& field, String<Memory>& destination) {
    if (!field.present()) {
      return;
    }

    const auto text = field.string();
    if (text.empty() || text.size() > 1024 || text.contains('\0')) {
      field.fail("is not a valid path");
    }

    destination = text;
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::patterns(const lua::Value& field, HistoryPatternList& destination) {
    if (!field.present()) {
      return;
    }

    const auto count = field.arraySize();

    for (std::size_t index = 1; index <= count; ++index) {
      destination.append(field.element(static_cast<lua_Integer>(index)).string());
    }
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::history(const lua::Value& table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"path", "secrets_filter", "command_filters", "cwd_filters", "output"});
    path(table.field("path"), values_.history_path);
    values_.history_filters.secrets = table.field("secrets_filter").boolean(values_.history_filters.secrets);
    patterns(table.field("command_filters"), values_.history_filters.commands);
    patterns(table.field("cwd_filters"), values_.history_filters.directories);
    const auto output = table.field("output");
    if (output.present()) {
      const auto mode = output.string();
      if (mode != "off" && mode != "bounded") {
        output.fail("must be off or bounded");
      }

      values_.capture_output = mode == "bounded";
    }
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::session(const lua::Value& table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"path", "persist", "resume_agents"});
    path(table.field("path"), values_.session_path);
    values_.persist_session = table.field("persist").boolean(values_.persist_session);
    values_.resume_agents = table.field("resume_agents").boolean(values_.resume_agents);
  }

  template <Allocator Memory>
  void RuntimeReader<Memory>::helper(const lua::Value& table, CommandValues<Memory>& destination, bool engine) {
    if (!table.present()) {
      return;
    }

    if (engine) {
      table.onlyFields({"command", "timeout_ms", "idle_timeout_ms"});
    } else {
      table.onlyFields({"command", "timeout_ms"});
    }

    const auto command = table.field("command");
    const auto count = command.arraySize();
    static_assert(CommandValues<Memory>::maximum_arguments == 32, "the message names the limit");

    if (count == 0 || count > CommandValues<Memory>::maximum_arguments) {
      command.fail("must contain 1..32 arguments");
    }

    destination.arguments.clear();
    auto& memory = destination.arguments.get_allocator().memory();
    std::size_t bytes = 0;

    for (std::size_t index = 1; index <= count; ++index) {
      const auto argument = command.element(static_cast<lua_Integer>(index));
      const auto text = argument.string();
      if ((index == 1 && text.empty()) || text.size() > 4096 - bytes || text.contains('\0')) {
        argument.fail("exceeds the helper command bounds");
      }

      bytes += text.size();
      destination.arguments.emplace_back(text, AllocatorRef<char, Memory>{memory});
    }

    destination.timeout = std::chrono::milliseconds{table.field("timeout_ms").boundedInteger(15'000, 1000, 60'000)};
    if (engine) {
      destination.idle_timeout = std::chrono::milliseconds{table.field("idle_timeout_ms").boundedInteger(300'000, 10'000, 3'600'000)};
    }
  }

  template class RuntimeReader<Memory>;
  template class RuntimeReader<ConcurrentMemory>;

}
