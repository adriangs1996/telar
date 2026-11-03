#pragma once

#include "pane_agent_control.hpp"
#include <openssl/sha.h>

namespace telar::runtime::cli::pane_agents {

inline constexpr std::array<std::string_view, 3> focus_outcomes{"focused", "no_neighbor", "source_not_focused"};
inline constexpr std::array<std::string_view, 2> lifecycles{"running", "exited"};

template <Allocator Memory>
void writePane(Output<Memory> &out, const PaneRecord &entry, bool json) {
  const auto &pane = entry.pane;
  const auto lifecycle = lifecycles.at(static_cast<std::size_t>(pane.lifecycle));
  if (json) {
    out.text("{\"workspace_id\":").number(entry.location.workspace.id).text(",\"tab_id\":").number(entry.location.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle, JsonEscapes::standard).text("}");
  } else {
    out.number(entry.location.workspace.id).text("\t").number(entry.location.tab_id).text("\t").number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
  }
}

template <Allocator Memory>
void inspectPanes(Memory &memory, const char *socket, const Options &options, Output<Memory> &out) {
  const auto catalog = paneCatalog(memory, socket, options);
  if (options.action == "get") {
    const auto wanted = paneId(options.target);
    for (const auto &entry : catalog) {
      if (entry.pane.pane_id == wanted) {
        writePane(out, entry, options.json);
        if (options.json) {
          out.text("\n");
        }

        return;
      }
    }

    throw Failure{controlFailureDescription(FailureCode::pane_not_found), 2};
  }

  out.text(options.json ? "[" : "WORKSPACE\tTAB\tPANE\tGENERATION\tLIFECYCLE\n");
  bool first = true;
  for (const auto &entry : catalog) {
    if (options.json && !first) {
      out.text(",");
    }

    writePane(out, entry, options.json);
    first = false;
  }

  if (options.json) {
    out.text("]\n");
  }
}

template <Allocator Memory>
void watchPane(ControlSession<Memory> &session, const Options &options, const PaneDescriptor &pane, Output<Memory> &out) {
  std::optional<std::array<unsigned char, SHA256_DIGEST_LENGTH>> previous;
  bool previous_truncated = false;
  std::uint64_t count = 0;
  for (;;) {
    const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = options.lines, .source = options.source});
    if (reply.pane_id != pane.pane_id) {
      throw Failure{"unexpected reply from the runtime"};
    }

    std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
    SHA256(reinterpret_cast<const unsigned char *>(reply.text.data()), reply.text.size(), digest.data());
    if (!previous || digest != *previous || reply.truncated != previous_truncated) {
      out.text("{\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"truncated\":").boolean(reply.truncated).text(",\"text\":").json(reply.text, JsonEscapes::standard).text("}\n");
      out.flush();
      previous = digest;
      previous_truncated = reply.truncated;
      ++count;
      if (options.count && count >= *options.count) {
        return;
      }
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{options.interval});
  }
}

template <Allocator Memory>
int executePane(Memory &memory, const RuntimePaths<Memory> &paths, Options options, Output<Memory> &out) {
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  String<Memory> input{AllocatorRef<char, Memory>{memory}};
  if (options.stdin_text) {
    input.resize(max_input_bytes + 1);
    const auto count = std::fread(input.data(), 1, input.size(), stdin);
    if (count > max_input_bytes) {
      throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
    }

    input.resize(count);
    while (!input.empty() && (input.back() == '\r' || input.back() == '\n')) {
      input.pop_back();
    }

    if (input.empty()) {
      throw Failure{"send-keys needs text of 1 to 65536 bytes, or --stdin"};
    }

    // Zig passes a zero-terminated pointer to sendText, so embedded NUL ends it.
    options.text = std::string_view{input}.substr(0, input.find('\0'));
  }

  if (options.action == "list" || options.action == "get") {
    inspectPanes(memory, paths.socket.c_str(), options, out);
    return 0;
  }

  const auto wanted = paneId(options.target);
  if (options.action == "watch") {
    const auto catalog = paneCatalog(memory, paths.socket.c_str(), options);
    for (const auto &entry : catalog) {
      if (entry.pane.pane_id == wanted) {
        watchPane(session, options, entry.pane, out);
        return 0;
      }
    }

    throw Failure{controlFailureDescription(FailureCode::pane_not_found), 2};
  }

  if (wanted == 0) {
    throw Failure{"InvalidPaneId"};
  }

  std::uint64_t generation = 0;
  if (options.action == "focus") {
    generation = current("TELAR_PANE_GENERATION", true);
  } else {
    const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
    for (const auto &agent : snapshot.entries) {
      if (agent.pane_id == wanted) {
        generation = agent.pane_generation;
        break;
      }
    }
  }

  if (options.action == "read") {
    const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = wanted, .pane_generation = generation, .rows = options.lines, .source = options.source});
    writeText(out, reply, options.json, false);
  } else if (options.action == "send-keys") {
    validateBytes(options.text, max_input_bytes, false);
    session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw, .text = options.text});
    if (options.enter) {
      std::this_thread::sleep_for(submit_delay);
      session.template exchange<RequestCompleted>(SendPaneText{.pane_id = wanted, .pane_generation = generation, .mode = PaneTextMode::raw_enter});
    }
  } else if (options.action == "search") {
    const auto reply = session.template exchange<PaneMatches>(SearchPane{.pane_id = wanted, .needle = options.text});
    if (reply.pane_id != wanted) {
      throw Failure{"unexpected reply from the runtime"};
    }

    if (options.json) {
      out.text("{\"pane_id\":").number(wanted).text(",\"truncated\":").boolean(reply.truncated).text(",\"matches\":[");
    }

    bool first = true;
    for (const auto &match : reply.matches) {
      if (options.json) {
        out.text(first ? "" : ",").text("{\"x\":").number(match.x).text(",\"y\":").number(match.y).text(",\"len\":").number(match.len).text("}");
      } else {
        out.number(match.y).text(":").number(match.x).text(" length=").number(match.len).text("\n");
      }

      first = false;
    }

    if (options.json) {
      out.text("]}\n");
    }
  } else if (options.action == "focus") {
    const auto reply = session.template exchange<PaneFocusResult>(RequestPaneFocus{.pane_id = wanted, .pane_generation = generation, .direction = *options.direction});
    if (options.json) {
      out.text("{\"changed\":").boolean(reply.outcome == PaneFocusOutcome::focused).text(",\"focused_pane_id\":").number(reply.focused_pane_id).text(",\"reason\":").json(focus_outcomes.at(static_cast<std::size_t>(reply.outcome))).text("}\n");
    }
  }

  return 0;
}

}

namespace telar::runtime::cli {

template <Allocator Memory>
int runPane(Memory &memory, const pane_agents::Options &options) {
  using namespace pane_agents;
  const RuntimePaths paths{memory, socketOptions(options.socket), ProcessEnvironment{}};
  ensureRuntime(memory, paths, options.action == "read" || options.action == "send-keys" || options.action == "focus");
  Output out{memory};
  try {
    const auto result = executePane(memory, paths, options, out);
    out.flush();
    return result;
  } catch (const std::exception &error) {
    out.flush();
    return commandFailure("telar pane", error);
  }
}

}
