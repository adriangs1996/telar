#pragma once

#include "../lua/value.hpp"
#include "agent_reader.hpp"
#include "proxy_reader.hpp"
#include "runtime_values.hpp"

namespace telar::runtime::config {

template <Allocator Memory>
class RuntimeReader {
public:
  explicit RuntimeReader(RuntimeValues<Memory> &values)
      : values_(values) {}

  void read(const lua::Value &runtime) {
    if (!runtime.present()) {
      return;
    }

    runtime.onlyFields({"history", "session", "engine", "agent_descriptions", "graphics", "proxy", "agents"});
    history(runtime.field("history"));
    session(runtime.field("session"));
    helper(runtime.field("engine"), values_.engine, true);
    helper(runtime.field("agent_descriptions"), values_.descriptions, false);
    AgentReader{values_.manifests, values_.limits}.read(runtime.field("agents"));
    graphics(runtime.field("graphics"));
    ProxyReader<Memory>::read(runtime.field("proxy"), values_.proxy);
  }

private:
  void graphics(const lua::Value &table) {
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

  static void path(const lua::Value &field, String<Memory> &destination) {
    if (!field.present()) {
      return;
    }

    const auto text = field.string();
    if (text.empty() || text.size() > 1024 || text.contains('\0')) {
      field.fail("is not a valid path");
    }

    destination = text;
  }

  static void patterns(const lua::Value &field, HistoryPatternList &destination) {
    if (!field.present()) {
      return;
    }

    const auto count = field.arraySize();
    for (std::size_t index = 1; index <= count; ++index) {
      destination.append(field.element(static_cast<lua_Integer>(index)).string());
    }
  }

  void history(const lua::Value &table) {
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

  void session(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"path", "persist", "resume_agents"});
    path(table.field("path"), values_.session_path);
    values_.persist_session = table.field("persist").boolean(values_.persist_session);
    values_.resume_agents = table.field("resume_agents").boolean(values_.resume_agents);
  }

  static void helper(const lua::Value &table, CommandValues<Memory> &destination, bool engine) {
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
    if (count == 0 || count > 32) {
      command.fail("must contain 1..32 arguments");
    }

    destination.arguments.clear();
    auto &memory = destination.arguments.get_allocator().memory();
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

  RuntimeValues<Memory> &values_;
};

template <Allocator Memory>
RuntimeReader(RuntimeValues<Memory> &values) -> RuntimeReader<Memory>;

}
