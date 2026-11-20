module telar.gui.application;

import std;

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
      const auto seed = features::paths::seed(session.paths);
      if (seed.pane_id != pane_id || seed.text.empty()) {
        return false;
      }

      return features::prompt::replace(session.prompt, session.prompt_lines, {.pane_id = pane_id, .begin = seed.begin, .text = seed.text}, path);
    }

  }

  bool open(Session& session) {
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    if (!session.ready() || terminal::copy_mode::view(session).active() || pane == nullptr || !pane->attached || pane->exited || !std::string_view{pane->cwd}.starts_with('/')) {
      return false;
    }

    auto& state = session.paths;

    features::paths::open(state, pane->id, pane->cwd, caretWord(session, pane->id));
    search(session, features::paths::seed(state).text);

    return true;
  }

  std::string_view seed(const Session& session) noexcept {
    return features::paths::seed(session.paths).text;
  }

  bool search(Session& session, std::string_view query) {
    auto& state = session.paths;
    if (!session.ready() || features::paths::page(state).paneId() == 0) {
      return false;
    }

    const auto request = features::paths::search(state, query, session.link.nextRequest());

    try {
      session.link.send(request);
    } catch (const std::length_error&) {
      features::paths::report(state, "Path request queue is full; retry");

      return false;
    }

    features::paths::wait(state, request.request_id);

    return true;
  }

  bool descend(Session& session, std::size_t selection) {
    if (!features::paths::descend(session.paths, selection)) {
      return false;
    }

    search(session, {});

    return true;
  }

  bool ascend(Session& session) {
    if (!features::paths::ascend(session.paths)) {
      return false;
    }

    search(session, {});

    return true;
  }

  void close(Session& session) noexcept {
    features::paths::close(session.paths);
  }

  bool insert(Session& session, std::size_t selection, bool absolute) {
    auto& state = session.paths;
    if (!features::paths::insertable(state)) {
      return false;
    }

    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    if (!session.ready() || pane == nullptr || !pane->attached || pane->exited || terminal::copy_mode::view(session).active()) {
      features::paths::report(state, "Input is busy; retry");

      return false;
    }

    const bool editor = prompt::edits(session, pane->id);
    const auto paste = features::paths::insertion(state, {.selection = selection, .absolute = absolute, .bracketed = !editor && pane->screen.modes().bracketed_paste});
    if (!paste) {
      return false;
    }

    // The paste lives in the picker's state, which writing it into the line may reach.
    const auto pane_id = pane->id;
    const ds::String<Memory> text{session.memory, paste->view()};

    try {
      if (!editor) {
        session.input(pane_id, text.view());
      } else if (!replaceSeed(session, pane_id, text.view())) {
        prompt::text(session, pane_id, text.view());
      }
    } catch (const std::length_error&) {
      features::paths::report(state, "Input is busy; retry");

      return false;
    }

    close(session);

    return true;
  }

  PathPickerPage page(const Session& session) noexcept {
    return features::paths::page(session.paths);
  }

  Change receive(Session& session, const PathResults& results) {
    return features::paths::receive(session.paths, results) ? Change::paths : Change::none;
  }

  ds::Option<Change> fail(Session& session, const RequestFailed& failure) {
    const auto changed = features::paths::fail(session.paths, failure);
    if (!changed) {
      return ds::none;
    }

    return *changed ? Change::paths : Change::none;
  }

}
