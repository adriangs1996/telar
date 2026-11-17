module telar.gui.application;

import std;

import :access;
import telar.gui.features.palette;
import telar.gui.foundation.keys;
import telar.gui.foundation.model;
import telar.gui.input.configuration;
import telar.wire.editor;

namespace telar::gui::application::palette {

  Suggestion suggestion(const Session& session) noexcept {
    return features::palette::suggestion(Access::palette(session));
  }

  void suggest(Session& session) noexcept {
    features::palette::suggest(Access::palette(session));
  }

  void discard(Session& session) noexcept {
    features::palette::discard(Access::palette(session));
  }

  bool submit(Session& session, std::string_view task) {
    using Kind = features::palette::Submission::Kind;
    auto& state = Access::palette(session);
    const auto* pane = session.focusedPane();
    const auto submission = features::palette::submit(state, task);

    if (submission.kind == Kind::insert) {
      if (!session.ready() || pane == nullptr || !pane->attached || pane->exited || session.copyMode().active()) {
        return false;
      }

      if (session.editsPrompt(pane->id)) {
        session.promptText(pane->id, submission.text);
        return true;
      }

      const auto bracketed = pane->screen.modes().bracketed_paste;

      HistoryText::validate(submission.text, bracketed);
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

    const SuggestCommand request{.request_id = Access::nextRequest(session), .pane_id = pane->id, .text = submission.text};

    Access::send(session, request);
    features::palette::wait(state, request.request_id);

    return false;
  }

  Change receive(Session& session, const CommandSuggestion& suggestion) {
    return features::palette::receive(Access::palette(session), suggestion) ? Change::suggestion : Change::none;
  }

}
