module telar.gui.application;

import std;

import :access;
import telar.gui.features.paths;
import telar.gui.features.prompt;
import telar.wire.editor;
import telar.wire.runtime;
import telar.base.ds;

namespace telar::gui::application::paths {

  namespace {

    // At the line's prompt, the word before the caret, which the search starts from when it is
    // a plain relative path; nothing elsewhere.
    features::paths::PathSeed caretWord(const Session& session, std::uint64_t pane_id) {
      const auto line = prompt::line(session, pane_id);
      if (prompt::surface(session, pane_id) != prompt::Surface::editor || !line) {
        return {};
      }

      const auto before = line->text().substr(0, line->cursor());
      const auto space = before.find_last_of(" \t\n");
      const auto begin = space == std::string_view::npos ? 0 : space + 1;

      return {.pane_id = pane_id, .begin = begin, .text = before.substr(begin)};
    }

    // Writes `path` over the word the search started from, while the editor still holds it.
    bool replaceSeed(Session& session, std::uint64_t pane_id, std::string_view path) {
      const auto seed = features::paths::seed(Access::paths(session));
      if (seed.pane_id != pane_id || seed.text.empty()) {
        return false;
      }

      return features::prompt::replace(Access::prompt(session), pane_id, seed.begin, seed.text, path);
    }

  }

  bool open(Session& session) {
    const auto* pane = session.focusedPane();
    if (!session.ready() || terminal::copy_mode::view(session).active() || pane == nullptr || !pane->attached || pane->exited || !std::string_view{pane->cwd}.starts_with('/')) {
      return false;
    }

    auto& state = Access::paths(session);

    features::paths::open(state, pane->id, pane->cwd, caretWord(session, pane->id));
    search(session, features::paths::seed(state).text);

    return true;
  }

  std::string_view seed(const Session& session) noexcept {
    return features::paths::seed(Access::paths(session)).text;
  }

  bool search(Session& session, std::string_view query) {
    auto& state = Access::paths(session);
    if (!session.ready() || features::paths::page(state).paneId() == 0) {
      return false;
    }

    const auto request = features::paths::search(state, query, Access::nextRequest(session));

    try {
      Access::send(session, request);
    } catch (const std::length_error&) {
      features::paths::report(state, "Path request queue is full; retry");

      return false;
    }

    features::paths::wait(state, request.request_id);

    return true;
  }

  bool descend(Session& session, std::size_t selection) {
    if (!features::paths::descend(Access::paths(session), selection)) {
      return false;
    }

    search(session, {});

    return true;
  }

  bool ascend(Session& session) {
    if (!features::paths::ascend(Access::paths(session))) {
      return false;
    }

    search(session, {});

    return true;
  }

  void close(Session& session) noexcept {
    features::paths::close(Access::paths(session));
  }

  bool insert(Session& session, std::size_t selection, bool absolute) {
    auto& state = Access::paths(session);
    if (!features::paths::insertable(state)) {
      return false;
    }

    const auto* pane = session.focusedPane();
    if (!session.ready() || pane == nullptr || !pane->attached || pane->exited || terminal::copy_mode::view(session).active()) {
      features::paths::report(state, "Input is busy; retry");

      return false;
    }

    const bool editor = prompt::edits(session, pane->id);
    const auto paste = features::paths::insertion(state, {.selection = selection, .absolute = absolute, .bracketed = !editor && pane->screen.modes().bracketed_paste});
    if (!paste) {
      return false;
    }

    try {
      if (!editor) {
        session.input(pane->id, paste->view());
      } else if (!replaceSeed(session, pane->id, paste->view())) {
        prompt::text(session, pane->id, paste->view());
      }
    } catch (const std::length_error&) {
      features::paths::report(state, "Input is busy; retry");

      return false;
    }

    close(session);

    return true;
  }

  PathPickerPage page(const Session& session) noexcept {
    return features::paths::page(Access::paths(session));
  }

  Change receive(Session& session, const PathResults& results) {
    return features::paths::receive(Access::paths(session), results) ? Change::paths : Change::none;
  }

  ds::Option<Change> fail(Session& session, const RequestFailed& failure) {
    const auto changed = features::paths::fail(Access::paths(session), failure);
    if (!changed) {
      return ds::none;
    }

    return *changed ? Change::paths : Change::none;
  }

}
