module telar.gui.application;

import std;

import :access;
import telar.base.memory.allocators;
import telar.gui.features.history;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application::history {

  namespace {

    // Sends a history request, handing back what the transport threw. A request views the
    // history's state, so the panel fails a refused one only once the request is done with.
    template <typename Request>
    [[nodiscard]] std::exception_ptr refusal(Session::Link& link, const Request& request) noexcept {
      try {
        link.send(request);
      } catch (...) {
        return std::current_exception();
      }

      return nullptr;
    }

    // Fails request `request_id` in the panel when the transport refused it, and throws again.
    void settle(features::history::State& history, std::uint64_t request_id, const std::exception_ptr& refused) {
      if (!refused) {
        return;
      }

      try {
        std::rethrow_exception(refused);
      } catch (const std::exception& error) {
        features::history::fail(history, request_id, error.what());
        throw;
      }
    }

    // Reads the selected command's whole text and its output, when the panel needs them.
    void readDetails(Session& session) {
      auto& state = session.history;

      if (const auto request = features::history::readCommand(state, session.link.nextRequest())) {
        const auto request_id = request->request_id;
        const auto refused = refusal(session.link, *request);

        settle(state, request_id, refused);
      }

      if (const auto request = features::history::readOutput(state, session.link.nextRequest())) {
        const auto request_id = request->request_id;
        const auto refused = refusal(session.link, *request);

        settle(state, request_id, refused);
      }
    }

    // Narrows `request` to the focused pane, its directory or the active workspace's directory,
    // as `scope` asks; it stays global when the scope names nothing.
    // It views what it names in the session's panes and workspaces, and nothing else of it.
    void resolveScope(const Session& session, tbc::mut_a<QueryHistory> request, HistoryScope scope, tbc::ref_a<Panes> panes, tbc::ref_a<WorkspaceReplica<Memory>> workspace_list) {
      if (scope == HistoryScope::pane || scope == HistoryScope::cwd) {
        const auto* pane = focusedPane(panes, session.tabs, session.active_tab);
        if (pane == nullptr) {
          return;
        }

        if (scope == HistoryScope::pane) {
          request.scope = scope;
          request.scope_value = pane->id;
        } else if (!pane->cwd.empty()) {
          request.scope = scope;
          request.scope_value = std::string_view{pane->cwd};
        }
      } else if (const auto& active = session.active_tab; scope == HistoryScope::workspace && active) {
        const auto location = active->workspace;
        const auto& workspaces = workspace_list.entries();
        const auto* const workspace = std::ranges::find_if(workspaces, [&](const auto& entry) {
          return entry.location.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(entry.location, location);
        });
        if (workspace != workspaces.end() && !workspace->path.empty()) {
          request.scope = scope;
          request.scope_value = std::string_view{workspace->path};
        }
      }
    }

  }

  void search(Session& session, std::string_view query) {
    search(session, query, {.author = session.configuration.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  void search(Session& session, std::string_view query, HistoryFilters filters) {
    // Each command once, at its newest run that passes the filters.
    QueryHistory request{.request_id = session.link.nextRequest(), .query = query, .failed_only = filters.failed_only, .author = filters.author, .match = session.configuration.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};

    resolveScope(session, request, filters.scope, session.panes, session.workspace_list);

    const auto searched = features::history::search(session.history, request);
    const auto refused = refusal(session.link, searched);

    settle(session.history, request.request_id, refused);
  }

  bool page(Session& session, HistoryPage direction) {
    if (const auto request = features::history::page(session.history, direction, session.link.nextRequest())) {
      const auto request_id = request->request_id;
      const auto refused = refusal(session.link, *request);

      settle(session.history, request_id, refused);
      return true;
    }

    return false;
  }

  bool loading(const Session& session) noexcept {
    return view(session).state().phase == HistoryPhase::loading;
  }

  HistoryView view(const Session& session) noexcept {
    return features::history::view(session.history);
  }

  void report(Session& session, std::string_view message) {
    features::history::report(session.history, message);
  }

  void select(Session& session, std::size_t row) {
    if (features::history::select(session.history, row)) {
      readDetails(session);
    }
  }

  void inspect(Session& session, bool enabled) {
    features::history::inspect(session.history, enabled);
    readDetails(session);
  }

  void paste(Session& session, std::uint64_t entry_id, bool alternate) {
    // The entry is copied out of the history, which pasting must not be able to reach.
    const ds::String<Memory> entry{session.memory, view(session).command(entry_id)};
    const std::string_view command = entry;
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    if (pane == nullptr || !pane->attached || pane->exited) {
      throw EncodingError{"No terminal is ready for input"};
    }

    const auto runs = session.configuration.history.enter_runs != alternate;

    const auto pane_id = pane->id;
    const bool bracketed = pane->screen.modes().bracketed_paste;

    if (prompt::edits(session, pane_id)) {
      prompt::write(session, pane_id, command);
      if (runs) {
        prompt::key(session, pane_id, prompt::KeyPress{.key = prompt::Key::enter});
      }

      return;
    }

    // Enter runs the command only where the shell waits for one: a program in front, as vim or an
    // agent, would take it as its own key. Without shell integration only a full-screen program
    // tells that the shell is not in front.
    const bool integrated = pane->shell.shell != IntegratedShell::none;
    const bool at_prompt = integrated ? pane->shell.phase == ShellPhase::prompt : !pane->screen.modes().alternate_screen;

    HistoryText::validate(command, bracketed);
    session.paste(pane_id, command);
    if (runs && at_prompt) {
      session.input(pane_id, "\r");
    }
  }

  void copy(Session& session, std::uint64_t entry_id) {
    Access::clipboard(session).assign(view(session).command(entry_id));
  }

  void visit(Session& session, std::uint64_t entry_id) {
    workbench::visit(session, view(session).entry(entry_id).pane_id);
  }

  void remove(Session& session, std::uint64_t entry_id) {
    const auto request = features::history::erase(session.history, entry_id, session.link.nextRequest());
    // The search lists each command once, at its newest run: deleting it deletes every run, or
    // the next older one would take its place. A runtime before cqp00012 deletes the one run.
    const auto refused = session.speaks(ClientTag::delete_history_command) ? refusal(session.link, DeleteHistoryCommand{.request_id = request.request_id, .id = request.id}) : refusal(session.link, request);

    settle(session.history, request.request_id, refused);
    // The row that took the deleted one's place is selected now.
    readDetails(session);
  }

  Change receive(Session& session, const HistoryResults& results) {
    if (!features::history::receive(session.history, results)) {
      return Change::none;
    }

    readDetails(session);

    return Change::history;
  }

  Change receive(Session& session, const HistoryOutput& output) {
    return features::history::receive(session.history, output) ? Change::history : Change::none;
  }

  void refresh(Session& session) {
    auto& state = session.history;
    const auto request = features::history::refresh(state, session.link.nextRequest());
    const auto refused = refusal(session.link, request);

    settle(state, request.request_id, refused);
  }

  Change receive(Session& session, const HistoryPruned& pruned) {
    if (!features::history::receive(session.history, pruned)) {
      return Change::none;
    }

    refresh(session);

    return Change::history;
  }

  ds::Option<Change> fail(Session& session, std::uint64_t request_id, std::string_view message) {
    auto& state = session.history;
    if (!features::history::view(state).owns(request_id)) {
      return ds::none;
    }

    return features::history::fail(state, request_id, message) ? Change::history : Change::none;
  }

}
