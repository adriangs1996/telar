module telar.gui.application;

import std;

import :access;
import telar.base.memory.allocators;
import telar.gui.features.history;
import telar.gui.foundation.system;
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
      // The inspector's context asks with the page's request of cqp00015, its statistics with a
      // request of their own.
      const bool reads_context = session.speaks(ClientTag::watch_history);
      const bool reads_stats = session.speaks(ClientTag::query_history_command_stats);
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

      if (reads_stats) {
        if (const auto request = features::history::readRuns(state, session.link.nextRequest(), system::WallClock::sample())) {
          const auto request_id = request->request_id;
          const auto refused = refusal(session.link, *request);

          settle(state, request_id, refused);
        }
      }

      if (!reads_context) {
        return;
      }

      if (const auto request = features::history::readContext(state, session.link.nextRequest())) {
        const auto request_id = request->request_id;
        const auto refused = refusal(session.link, *request);

        settle(state, request_id, refused);
      }
    }

    // The panel follows the runtime's changes while it shows the history. The session asks the
    // runtime to tell of them once, as it connects, for the prompt and the panel alike.
    void startWatching(Session& session) {
      static_cast<void>(features::history::watch(session.history, true));
    }

    // The search lists each command once, at its newest run: deleting it deletes every run, or
    // the next older one would take its place. A runtime before cqp00012 deletes the one run.
    void sendDelete(Session& session, const DeleteHistory& request) {
      const auto refused = session.speaks(ClientTag::delete_history_command) ? refusal(session.link, DeleteHistoryCommand{.request_id = request.request_id, .id = request.id}) : refusal(session.link, request);

      settle(session.history, request.request_id, refused);
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

  void search(Session& session, std::string_view query, HistoryFilters filters, CalendarSample sampled) {
    // Each command once, at its newest run that passes the filters.
    QueryHistory request{.request_id = session.link.nextRequest(), .query = query, .failed_only = filters.failed_only, .author = filters.author, .match = session.configuration.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};

    resolveScope(session, request, filters.scope, session.panes, session.workspace_list);
    // The pane's commands, and those from before it started, as its shell's own history.
    request.preload = filters.preload && request.scope == HistoryScope::pane;
    // The pane and the directory that ask weigh the ranking.
    if (const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab)) {
      request.origin_pane = pane->id;
      request.origin_cwd = pane->cwd;
    }

    features::history::HistoryTyping::narrow(request, filters.chips, sampled);

    // A typed directory or workspace narrows the search as its scope would. The directory joins
    // the focused pane's when it is relative; a workspace is named or given by its path.
    ds::String<Memory> directory{session.memory};

    if (const auto typed = filters.chips.value(features::history::HistoryFilterKey::cwd)) {
      const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
      const auto relative = !typed->starts_with('/') && !typed->starts_with('~') && pane != nullptr && !pane->cwd.empty();

      if (relative) {
        directory.assign(pane->cwd);
        if (*typed != ".") {
          directory.append("/");
          directory.append(*typed);
        }
      } else {
        directory.assign(*typed);
      }

      request.scope = HistoryScope::cwd;
      request.scope_value = std::string_view{directory};
    } else if (const auto named = filters.chips.value(features::history::HistoryFilterKey::workspace)) {
      const auto& workspaces = session.workspace_list.entries();
      const auto* const workspace = std::ranges::find_if(workspaces, [&](const auto& entry) {
        return entry.name == *named;
      });

      request.scope = HistoryScope::workspace;
      request.scope_value = workspace != workspaces.end() && !workspace->path.empty() ? std::string_view{workspace->path} : *named;
    }

    startWatching(session);
    const auto searched = features::history::search(session.history, request);
    const auto refused = refusal(session.link, searched);

    settle(session.history, request.request_id, refused);
  }

  void watch(Session& session, bool watching) {
    // The runtime keeps telling the session: the prompt's suggestions still read the changes.
    static_cast<void>(features::history::watch(session.history, watching));
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

  namespace {

    // Writes `command` at the focused pane, and runs it when `runs` and the shell waits for one.
    void write(Session& session, std::string_view command, bool runs) {
      const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
      if (pane == nullptr || !pane->attached || pane->exited) {
        throw EncodingError{"No terminal is ready for input"};
      }

      const auto pane_id = pane->id;
      const bool bracketed = pane->screen.modes().bracketed_paste;

      if (prompt::edits(session, pane_id)) {
        prompt::write(session, pane_id, command);
        if (runs) {
          prompt::key(session, pane_id, prompt::KeyPress{.key = prompt::Key::enter});
        }

        return;
      }

      // Enter runs the command only where the shell waits for one: a program in front, as vim or
      // an agent, would take it as its own key. Without shell integration only a full-screen
      // program tells that the shell is not in front.
      const bool integrated = pane->shell.shell != IntegratedShell::none;
      const bool at_prompt = integrated ? pane->shell.phase == ShellPhase::prompt : !pane->screen.modes().alternate_screen;

      HistoryText::validate(command, bracketed);
      session.paste(pane_id, command);
      if (runs && at_prompt) {
        session.input(pane_id, "\r");
      }
    }

    // `text` as one word of a POSIX shell: in single quotes, each of its own closed, escaped and
    // opened again.
    void appendQuoted(ds::String<Memory>& destination, std::string_view text) {
      destination.append("'");
      for (auto rest = text; !rest.empty();) {
        const auto quote = rest.find('\'');

        destination.append(rest.substr(0, quote));
        if (quote == std::string_view::npos) {
          break;
        }

        destination.append("'\\''");
        rest.remove_prefix(quote + 1);
      }

      destination.append("'");
    }

  }

  void paste(Session& session, std::uint64_t entry_id, bool alternate) {
    // The rows shown answer a query older than the one typed: what runs is the new one's.
    if (view(session).state().load == HistoryLoad::search) {
      throw EncodingError{"History search is still loading"};
    }

    // The entry is copied out of the history, which pasting must not be able to reach.
    const ds::String<Memory> entry{session.memory, view(session).command(entry_id)};

    write(session, entry, session.configuration.history.enter_runs != alternate);
    // The runtime ranks a command chosen higher once the pane runs it. Only a hint: the command
    // is written whether or not the runtime hears of the choice.
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    if (pane != nullptr && session.speaks(ClientTag::choose_history_entry)) {
      static_cast<void>(refusal(session.link, ChooseHistoryEntry{.request_id = session.link.nextRequest(), .id = entry_id, .pane_id = pane->id}));
    }
  }

  void pasteCommand(Session& session, std::string_view command, bool alternate) {
    // Copied: writing at the prompt line may reach what the caller views.
    const ds::String<Memory> copied{session.memory, command};

    write(session, copied, session.configuration.history.enter_runs != alternate);
  }

  void pasteMarked(Session& session, bool alternate) {
    const auto browser = view(session);
    const auto runs = session.configuration.history.enter_runs != alternate;
    // Run, one line that stops at the first command that fails; written, one command a line.
    const std::string_view separator = runs ? " && " : "\n";
    ds::String<Memory> joined{session.memory};

    for (std::size_t index = 0; index < browser.markCount(); ++index) {
      if (index != 0) {
        joined.append(separator);
      }

      joined.append(browser.markedCommand(index));
    }

    if (joined.size() > HistoryText::maximum_bytes) {
      throw EncodingError{"The commands marked exceed what one paste holds"};
    }

    write(session, joined, runs);
    features::history::clearMarks(session.history);
  }

  void mark(Session& session, std::uint64_t entry_id) {
    static_cast<void>(features::history::toggleMark(session.history, entry_id));
  }

  void clearMarks(Session& session) noexcept {
    features::history::clearMarks(session.history);
  }

  void enter(Session& session, std::uint64_t entry_id) {
    const auto& entry = view(session).entry(entry_id);
    if (entry.cwd.empty()) {
      throw EncodingError{"The command's directory is unknown"};
    }

    ds::String<Memory> command{session.memory, "cd -- "};

    appendQuoted(command, entry.cwd);
    write(session, command, true);
  }

  void open(Session& session, std::uint64_t entry_id) {
    // Copied: splitting changes the session the entry lies in.
    const ds::String<Memory> directory{session.memory, view(session).entry(entry_id).cwd};
    if (directory.empty()) {
      throw EncodingError{"The command's directory is unknown"};
    }

    if (!workbench::splitAt(session, ClientLayoutAxis::horizontal, directory)) {
      throw EncodingError{"No pane can be split here"};
    }
  }

  void copy(Session& session, std::uint64_t entry_id) {
    Access::clipboard(session).assign(view(session).command(entry_id));
  }

  void visit(Session& session, std::uint64_t entry_id) {
    workbench::visit(session, view(session).entry(entry_id).pane_id);
  }

  void remove(Session& session, std::uint64_t entry_id) {
    sendDelete(session, features::history::erase(session.history, entry_id, session.link.nextRequest()));
    // The row that took the deleted one's place is selected now.
    readDetails(session);
  }

  void hide(Session& session, std::uint64_t entry_id) {
    if (const auto previous = features::history::hide(session.history, entry_id, session.link.nextRequest())) {
      sendDelete(session, *previous);
    }

    // The row that took the hidden one's place is selected now.
    readDetails(session);
  }

  void undo(Session& session) {
    if (features::history::unhide(session.history)) {
      refresh(session);
    }
  }

  void commit(Session& session) {
    if (const auto request = features::history::commitHidden(session.history, session.link.nextRequest())) {
      sendDelete(session, *request);
    }
  }

  Change receive(Session& session, const HistoryResults& results) {
    if (!features::history::receive(session.history, results)) {
      return Change::none;
    }

    readDetails(session);
    // Changes that came while a refresh was on its way are read now, once for them all.
    if (features::history::refreshDue(session.history)) {
      refresh(session);
    }

    return Change::history;
  }

  Change receive(Session& session, const HistoryOutput& output) {
    return features::history::receive(session.history, output) ? Change::history : Change::none;
  }

  Change receive(Session& session, const HistoryCommandStats& stats) {
    return features::history::receive(session.history, stats) ? Change::history : Change::none;
  }

  void refresh(Session& session) {
    startWatching(session);
    auto& state = session.history;
    const auto request = features::history::refresh(state, session.link.nextRequest());
    if (!request) {
      return;
    }

    const auto refused = refusal(session.link, *request);

    settle(state, request->request_id, refused);
  }

  Change receive(Session& session, const HistoryChanged& changed) {
    static_cast<void>(changed);
    // Whatever changed, the page shown is read anew; a search or a page on its way already
    // reads the history as it is now.
    if (!view(session).watching()) {
      return Change::none;
    }

    refresh(session);

    return Change::history;
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

    const auto failure = features::history::fail(state, request_id, message);
    // The row of a delete that failed left the page when it was sent: the page read anew shows
    // it again.
    if (failure == features::history::HistoryFailure::erase) {
      refresh(session);
    }

    return failure == features::history::HistoryFailure::none ? Change::none : Change::history;
  }

}
