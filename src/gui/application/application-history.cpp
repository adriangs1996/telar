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

    // Sends a history request; one the transport refuses fails in the panel too.
    template <typename Request>
    void send(Session& session, const Request& request) {
      try {
        session.link.send(request);
      } catch (const std::exception& error) {
        features::history::fail(session.history, request.request_id, error.what());
        throw;
      }
    }

    // Reads the selected command's whole text and its output, when the panel needs them.
    void readDetails(Session& session) {
      auto& state = session.history;

      if (const auto request = features::history::readCommand(state, session.link.nextRequest())) {
        send(session, *request);
      }

      if (const auto request = features::history::readOutput(state, session.link.nextRequest())) {
        send(session, *request);
      }
    }

    // Narrows `request` to the focused pane, its directory or the active workspace's directory,
    // as `scope` asks; it stays global when the scope names nothing.
    void resolveScope(const Session& session, QueryHistory& request, HistoryScope scope) {
      if (scope == HistoryScope::pane || scope == HistoryScope::cwd) {
        const auto* pane = session.focusedPane();
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
      } else if (const auto& active = Access::activeTab(session); scope == HistoryScope::workspace && active) {
        const auto location = active->workspace;
        const auto& workspaces = session.workspaces();
        const auto workspace = std::ranges::find_if(workspaces, [&](const auto& entry) {
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
    search(session, query, {.author = session.configuration().history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  void search(Session& session, std::string_view query, HistoryFilters filters) {
    // Each command once, at its newest run that passes the filters.
    QueryHistory request{.request_id = session.link.nextRequest(), .query = query, .failed_only = filters.failed_only, .author = filters.author, .match = session.configuration().history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};

    resolveScope(session, request, filters.scope);
    send(session, features::history::search(session.history, request));
  }

  bool page(Session& session, HistoryPage direction) {
    if (const auto request = features::history::page(session.history, direction, session.link.nextRequest())) {
      send(session, *request);

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
    const ds::String<Memory> entry{Access::memory(session), view(session).command(entry_id)};
    const std::string_view command = entry;
    const auto* pane = session.focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      throw EncodingError{"No terminal is ready for input"};
    }

    const auto runs = session.configuration().history.enter_runs != alternate;

    if (prompt::edits(session, pane->id)) {
      prompt::write(session, pane->id, command);
      if (runs) {
        prompt::key(session, pane->id, prompt::KeyPress{prompt::Key::enter});
      }

      return;
    }

    HistoryText::validate(command, pane->screen.modes().bracketed_paste);
    session.paste(pane->id, command);
    if (runs) {
      session.input(pane->id, "\r");
    }
  }

  void copy(Session& session, std::uint64_t entry_id) {
    Access::clipboard(session).assign(view(session).command(entry_id));
  }

  void visit(Session& session, std::uint64_t entry_id) {
    workbench::visit(session, view(session).entry(entry_id).pane_id);
  }

  void remove(Session& session, std::uint64_t entry_id) {
    send(session, features::history::erase(session.history, entry_id, session.link.nextRequest()));
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

  Change receive(Session& session, const HistoryPruned& pruned) {
    auto& state = session.history;
    if (!features::history::receive(state, pruned)) {
      return Change::none;
    }

    send(session, features::history::refresh(state, session.link.nextRequest()));

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
