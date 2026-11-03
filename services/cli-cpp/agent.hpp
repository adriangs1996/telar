#pragma once

#include "pane_agent_control.hpp"

namespace telar::runtime::cli::pane_agents {

template <Allocator Memory>
void interruptAgent(ControlSession<Memory> &session, const AgentSnapshotEntry &agent) {
  session.template exchange<RequestCompleted>(InterruptAgent{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation});
}

template <Allocator Memory>
int waitAgent(ControlSession<Memory> &session, const Options &options, std::optional<std::uint64_t> worktree, Output<Memory> &out) {
  const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};
  for (;;) {
    const auto agent = resolve(session.template exchange<AgentSnapshot>(QueryAgents{}), options.target, worktree);
    if (options.finished ? agent.status == AgentStatus::done || agent.status == AgentStatus::ready : agent.status == options.until) {
      writeOne(out, agent, options.json);
      return 0;
    }

    if (std::chrono::system_clock::now() >= deadline) {
      std::fprintf(stderr, "telar agent: timed out after %us; agent is %.*s\n", options.timeout, static_cast<int>(status_names[static_cast<std::size_t>(agent.status)].size()), status_names[static_cast<std::size_t>(agent.status)].data());
      return 3;
    }

    std::this_thread::sleep_for(poll_interval);
  }
}

template <Allocator Memory>
void settleAgent(ControlSession<Memory> &session, AgentSnapshotEntry agent) {
  const auto pane = agent.pane_id;
  interruptAgent(session, agent);
  const auto deadline = std::chrono::system_clock::now() + interrupt_settle;
  while (std::chrono::system_clock::now() < deadline) {
    std::this_thread::sleep_for(poll_interval);
    const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
    const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
    if (found == snapshot.entries.end()) {
      throw Failure{"no agent matches that target", 2};
    }

    if (found->status != AgentStatus::working) {
      return;
    }
  }

  throw Failure{"InterruptNotSettled"};
}

template <Allocator Memory>
int promptAgent(ControlSession<Memory> &session, const Options &options, AgentSnapshotEntry agent, Output<Memory> &out) {
  const auto pane = agent.pane_id;
  const auto generation = agent.pane_generation;
  if (options.interrupt && agent.status == AgentStatus::working) {
    settleAgent(session, agent);
  }

  session.template exchange<RequestCompleted>(SendPaneText{.pane_id = pane, .pane_generation = generation, .mode = PaneTextMode::prompt, .text = options.text, .sender = senderPane(options, pane)});
  if (!options.wait) {
    return 0;
  }

  const auto start_deadline = std::chrono::system_clock::now() + start_grace;
  const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds{options.timeout};
  bool started = false;
  for (;;) {
    const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
    const auto found = std::find_if(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
    if (found == snapshot.entries.end() || found->pane_generation != generation) {
      throw Failure{"no agent matches that target", 2};
    }

    agent = *found;
    if (agent.status == AgentStatus::working) {
      started = true;
    } else if (started || agent.status == AgentStatus::blocked || agent.status == AgentStatus::failed) {
      writeOne(out, agent, options.json);
      return agent.status == AgentStatus::failed ? 1 : 0;
    } else if (std::chrono::system_clock::now() >= start_deadline) {
      std::fprintf(stderr, "telar agent: the agent did not start working within 5s\n");
      return 3;
    }

    if (std::chrono::system_clock::now() >= deadline) {
      std::fprintf(stderr, "telar agent: timed out after %us; agent is still working\n", options.timeout);
      return 3;
    }

    std::this_thread::sleep_for(poll_interval);
  }
}

template <Allocator Memory>
void reportAgent(ControlSession<Memory> &session, const Options &options, const std::pair<std::uint64_t, std::uint64_t> &pane, Output<Memory> &out) {
  try {
    session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = pane.first, .pane_generation = pane.second});
  } catch (const std::exception &) {
  }

  validateReport(options);
  const auto report = [&](auto message) {
    message.pane_id = pane.first;
    message.pane_generation = pane.second;
    session.template exchange<RequestCompleted>(message);
  };
  if (options.action == "report-state") {
    report(options.report);
  } else if (options.action == "report-command") {
    report(options.command);
  } else {
    report(ReportAgentTitle{.title = options.text});
  }

  if (options.json) {
    out.text("{\"pane_id\":").number(pane.first).text(",\"pane_generation\":").number(pane.second).text(",\"accepted\":true}\n");
  }
}

template <Allocator Memory>
int executeAgent(Memory &memory, const RuntimePaths<Memory> &paths, const Options &options, Output<Memory> &out) {
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  const bool report = options.action == "report-title" || options.action == "report-state" || options.action == "report-command";
  std::optional<std::uint64_t> tree;
  constexpr std::string_view prefix = "worktree:";
  if (options.target.starts_with(prefix) && options.target.size() > prefix.size()) {
    if (report) {
      ControlSession catalog{memory, paths.socket.c_str()};
      catalog.receiveTimeout(30);
      runtimeList(catalog);
    } else {
      tree = worktreeId(memory, paths.socket.c_str(), options.target.substr(prefix.size()));
    }
  }

  if (report && options.target == "--current") {
    reportAgent(session, options, {current("TELAR_PANE_ID"), current("TELAR_PANE_GENERATION", true)}, out);
    return 0;
  }

  const auto snapshot = session.template exchange<AgentSnapshot>(QueryAgents{});
  if (options.action == "list") {
    if (options.json) {
      out.text("{\"revision\":").number(snapshot.revision).text(",\"agents\":[");
    } else {
      out.text(agent_header);
    }

    bool first = true;
    for (const auto &agent : snapshot.entries) {
      if (options.json && !first) {
        out.text(",");
      }

      writeAgent(out, agent, options.json);
      first = false;
    }

    if (options.json) {
      out.text("]}\n");
    }

    return 0;
  }

  // Manual reports resolve the agent snapshot without a worktree catalog.
  if (report && options.target.starts_with(prefix) && options.target.size() > prefix.size()) {
    throw Failure{"WorktreeCatalogMissing"};
  }

  if (options.action == "wait") {
    return waitAgent(session, options, tree, out);
  }

  if (options.action == "prompt") {
    const auto again = resolve(session.template exchange<AgentSnapshot>(QueryAgents{}), options.target, tree);
    return promptAgent(session, options, again, out);
  }

  const auto agent = resolve(snapshot, options.target, tree);
  if (report) {
    reportAgent(session, options, {agent.pane_id, agent.pane_generation}, out);
  } else if (options.action == "get") {
    writeOne(out, agent, options.json);
  } else if (options.action == "read") {
    const auto reply = session.template exchange<PaneText>(ReadPane{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .rows = options.lines, .source = options.source});
    writeText(out, reply, options.json, true);
  } else if (options.action == "interrupt") {
    Output saved{memory};
    writeOne(saved, agent, options.json);
    interruptAgent(session, agent);
    out.text(saved.data);
  } else if (options.action == "acknowledge") {
    const auto pane = agent.pane_id;
    const auto generation = agent.pane_generation;
    session.send(AcknowledgeAgent{.pane_id = pane, .pane_generation = generation});
    const auto updated = session.template exchange<AgentSnapshot>(QueryAgents{});
    const auto found = std::find_if(updated.entries.begin(), updated.entries.end(), [&](const auto &entry) { return entry.pane_id == pane; });
    if (found == updated.entries.end() || found->pane_generation != generation) {
      throw Failure{"no agent matches that target", 2};
    }

    if (found->status == AgentStatus::done) {
      throw Failure{"AgentAcknowledgementNotApplied"};
    }

    writeOne(out, *found, options.json);
  } else if (options.action == "report-session") {
    validateSession(options.text);
    session.template exchange<RequestCompleted>(ReportAgentSession{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .session = options.text});
  }

  return 0;
}

}

namespace telar::runtime::cli {

template <Allocator Memory>
int runAgent(Memory &memory, const pane_agents::Options &options) {
  using namespace pane_agents;
  const RuntimePaths paths{memory, socketOptions(options.socket), ProcessEnvironment{}};
  connectRuntime(memory, paths, options.action != "acknowledge" && options.action != "report-title" && options.action != "report-state" && options.action != "report-command");
  Output out{memory};
  try {
    const auto result = executeAgent(memory, paths, options, out);
    out.flush();
    return result;
  } catch (const std::exception &error) {
    out.flush();
    return commandFailure("telar agent", error);
  }
}

}
