module telar.gui.application;

import std;

import :access;
import telar.base.memory.allocators;
import telar.gui.features.history;
import telar.wire.history;
import telar.wire.vocabulary;

namespace telar::gui::application::history {

  namespace {

    // Sends a history request; one the transport refuses fails in the panel too.
    template <typename Request>
    void send(Session& session, const Request& request) {
      try {
        Access::send(session, request);
      } catch (const std::exception& error) {
        features::history::fail(Access::history(session), request.request_id, error.what());
        throw;
      }
    }

    // Reads the selected command's whole text and its output, when the panel needs them.
    void readDetails(Session& session) {
      auto& state = Access::history(session);

      if (const auto request = features::history::readCommand(state, Access::nextRequest(session))) {
        send(session, *request);
      }

      if (const auto request = features::history::readOutput(state, Access::nextRequest(session))) {
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
    QueryHistory request{.request_id = Access::nextRequest(session), .query = query, .failed_only = filters.failed_only, .author = filters.author, .match = session.configuration().history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};

    resolveScope(session, request, filters.scope);
    send(session, features::history::search(Access::history(session), request));
  }

  bool page(Session& session, HistoryPage direction) {
    if (const auto request = features::history::page(Access::history(session), direction, Access::nextRequest(session))) {
      send(session, *request);

      return true;
    }

    return false;
  }

  bool loading(const Session& session) noexcept {
    return view(session).state().phase == HistoryPhase::loading;
  }

  HistoryView view(const Session& session) noexcept {
    return features::history::view(Access::history(session));
  }

  void report(Session& session, std::string_view message) {
    features::history::report(Access::history(session), message);
  }

  void select(Session& session, std::size_t row) {
    if (features::history::select(Access::history(session), row)) {
      readDetails(session);
    }
  }

  void inspect(Session& session, bool enabled) {
    features::history::inspect(Access::history(session), enabled);
    readDetails(session);
  }

  void paste(Session& session, std::uint64_t entry_id, bool alternate) {
    // The entry is copied out of the history, which pasting must not be able to reach.
    const String<Memory> entry{view(session).command(entry_id), AllocatorRef<char, Memory>{Access::memory(session)}};
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
    Access::clipboard(session) = view(session).command(entry_id);
  }

  void visit(Session& session, std::uint64_t entry_id) {
    session.visitPane(view(session).entry(entry_id).pane_id);
  }

  void remove(Session& session, std::uint64_t entry_id) {
    send(session, features::history::erase(Access::history(session), entry_id, Access::nextRequest(session)));
  }

  Change receive(Session& session, const HistoryResults& results) {
    if (!features::history::receive(Access::history(session), results)) {
      return Change::none;
    }

    readDetails(session);

    return Change::history;
  }

  Change receive(Session& session, const HistoryOutput& output) {
    return features::history::receive(Access::history(session), output) ? Change::history : Change::none;
  }

  Change receive(Session& session, const HistoryPruned& pruned) {
    auto& state = Access::history(session);
    if (!features::history::receive(state, pruned)) {
      return Change::none;
    }

    send(session, features::history::refresh(state, Access::nextRequest(session)));

    return Change::history;
  }

  std::optional<Change> fail(Session& session, std::uint64_t request_id, std::string_view message) {
    auto& state = Access::history(session);
    if (!features::history::view(state).owns(request_id)) {
      return std::nullopt;
    }

    return features::history::fail(state, request_id, message) ? Change::history : Change::none;
  }

}
