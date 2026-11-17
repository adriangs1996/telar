module telar.gui.application;

import std;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.history.browser;
import telar.gui.links.path_expansion;
import telar.gui.paths.label;
import telar.gui.peek.screen;
import telar.config.client;
import telar.config.runtime;
import telar.gui.prompt.layout;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.gui.prompt.routing;
import telar.gui.prompt.editor;
import telar.shell.syntax;

namespace telar::gui::application {

  void Session::reportHistoryError(std::string_view message) {
    history_.setError(message);
  }

  void Session::visitHistory(std::uint64_t entry_id) {
    visitPane(history_.entry(entry_id).pane_id);
  }

  void Session::deleteHistory(std::uint64_t entry_id) {
    sendHistory(history_.erase(entry_id, nextRequest()));
  }

  void Session::selectHistoryRow(std::size_t row) {
    if (history_.select(row)) {
      refreshHistoryDetails();
    }
  }

  void Session::inspectHistory(bool enabled) {
    history_.setInspecting(enabled);
    refreshHistoryDetails();
  }

  void Session::queryHistory(std::string_view query) {
    queryHistory(query, {.author = configuration_.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  void Session::queryHistory(std::string_view query, HistoryFilters filters) {
    const auto parsed = HistorySearch::parse(query, filters.failed_only);
    // Each command once, at its newest run that passes the filters.
    QueryHistory request{.request_id = nextRequest(), .query = parsed.query, .failed_only = parsed.failed_only, .author = filters.author, .match = configuration_.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};

    resolveHistoryScope(request, filters.scope);
    sendHistory(history_.begin(request));
  }

  bool Session::pageHistory(HistoryPage direction) {
    if (const auto request = history_.page(direction, nextRequest())) {
      sendHistory(*request);

      return true;
    }

    return false;
  }

  bool Session::historyLoading() const noexcept {
    return history_.state().phase == HistoryPhase::loading;
  }

  const HistoryBrowser<Memory>& Session::historyBrowser() const noexcept {
    return history_;
  }

  template <typename Request>
  void Session::sendHistory(const Request& request) {
    try {
      send(request);
    } catch (const std::exception& error) {
      history_.fail(request.request_id, error.what());
      throw;
    }
  }

  void Session::refreshHistoryDetails() {
    if (const auto request = history_.readCommand(nextRequest())) {
      sendHistory(*request);
    }

    if (const auto request = history_.readOutput(nextRequest())) {
      sendHistory(*request);
    }
  }

  void Session::resolveHistoryScope(tbc::view<QueryHistory&, tbc::lt::a> request, HistoryScope scope) const {
    if (scope == HistoryScope::pane || scope == HistoryScope::cwd) {
      const auto* pane = focusedPane();
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
    } else if (scope == HistoryScope::workspace && active_tab_) {
      const auto location = active_tab_->workspace;
      const auto workspace = std::ranges::find_if(workspaces_, [&](const auto& entry) {
        return entry.location.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(entry.location, location);
      });
      if (workspace != workspaces_.end() && !workspace->path.empty()) {
        request.scope = scope;
        request.scope_value = std::string_view{workspace->path};
      }
    }
  }

  Change Session::apply(const HistoryResults& message) {
    if (message.request_id == prompt_history_request_ && prompt_history_request_ != 0) {
      prompt_history_request_ = 0;
      prompt_history_.clear();
      for (const auto& entry : message.entries) {
        if (!entry.command_truncated && !entry.command.empty()) {
          prompt_history_.emplace_back(entry.command);
        }
      }

      return Change::none;
    }

    if (!history_.apply(message)) {
      return Change::none;
    }

    refreshHistoryDetails();

    return Change::history;
  }

  Change Session::apply(const HistoryOutput& message) {
    return history_.apply(message) ? Change::history : Change::none;
  }

  Change Session::apply(const HistoryPruned& message) {
    if (!history_.apply(message)) {
      return Change::none;
    }

    sendHistory(history_.refresh(nextRequest()));

    return Change::history;
  }

}
