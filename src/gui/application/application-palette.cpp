module telar.gui.application;

import std;

import telar.gui.features.palette;
import telar.gui.foundation.keys;
import telar.gui.foundation.model;
import telar.gui.features.history;
import telar.wire.editor;

namespace telar::gui::application::palette {

  Suggestion suggestion(const Session& session) noexcept {
    return features::palette::suggestion(session.palette);
  }

  void suggest(Session& session) noexcept {
    features::palette::suggest(session.palette);
  }

  void discard(Session& session) noexcept {
    features::palette::discard(session.palette);
  }

  bool submit(Session& session, std::string_view task) {
    using Kind = features::palette::Submission::Kind;
    auto& state = session.palette;
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    const auto submission = features::palette::submit(state, task);

    if (submission.kind == Kind::insert) {
      if (!session.ready() || pane == nullptr || !pane->attached || pane->exited || terminal::copy_mode::view(session).active()) {
        return false;
      }

      // The text lives in the palette's state, which writing it into the line may reach.
      const auto pane_id = pane->id;

      if (prompt::edits(session, pane_id)) {
        const ds::String<Memory> text{session.memory, submission.text};

        prompt::text(session, pane_id, text.view());
        return true;
      }

      const auto bracketed = pane->screen.modes().bracketed_paste;

      features::history::HistoryText::validate(submission.text, bracketed);
      const auto encoded = PasteEncoding::encode<SuggestionLimits::text_bytes>(submission.text, bracketed);

      session.input(pane->id, encoded.view());

      return true;
    }

    if (submission.kind == Kind::none) {
      return false;
    }

    if (!session.ready() || pane == nullptr || !pane->attached || pane->exited) {
      features::palette::fail(state);

      return false;
    }

    const SuggestCommand request{.request_id = session.link.nextRequest(), .pane_id = pane->id, .text = submission.text};

    session.link.send(request);
    features::palette::wait(state, request.request_id);

    return false;
  }

  Change receive(Session& session, const CommandSuggestion& suggestion) {
    return features::palette::receive(session.palette, suggestion) ? Change::suggestion : Change::none;
  }

}
