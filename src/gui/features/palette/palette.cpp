module telar.gui.features.palette;

import std;

import telar.gui.foundation.model;
import telar.wire.editor;
import telar.wire.vocabulary;

namespace telar::gui::features::palette {

  void SuggestionState::begin() noexcept {
    pending_request_ = 0;
    phase_ = SuggestionPhase::idle;
    text_ = {};
    ++revision_;
  }

  void SuggestionState::expect(std::uint64_t request_id) noexcept {
    pending_request_ = request_id;
    phase_ = SuggestionPhase::waiting;
    text_ = {};
    ++revision_;
  }

  void SuggestionState::invalidate() noexcept {
    if (phase_ == SuggestionPhase::idle) {
      return;
    }

    begin();
  }

  bool SuggestionState::receive(const CommandSuggestion& suggestion) {
    if (suggestion.request_id == 0 || suggestion.request_id != pending_request_) {
      return false;
    }

    if (suggestion.text.size() > SuggestionLimits::text_bytes) {
      throw EncodingError{"Suggestion exceeds its wire capacity"};
    }

    text_.assign(suggestion.text);
    pending_request_ = 0;
    status_ = suggestion.status;
    phase_ = status_ == SuggestionStatus::ready && !text_.view().empty() ? SuggestionPhase::ready : SuggestionPhase::failed;
    ++revision_;

    return true;
  }

  void SuggestionState::fail() noexcept {
    text_ = {};
    pending_request_ = 0;
    status_ = SuggestionStatus::failed;
    phase_ = SuggestionPhase::failed;
    ++revision_;
  }

  SuggestionPhase SuggestionState::phase() const noexcept {
    return phase_;
  }

  SuggestionStatus SuggestionState::status() const noexcept {
    return status_;
  }

  std::uint64_t SuggestionState::pendingRequest() const noexcept {
    return pending_request_;
  }

  std::uint64_t SuggestionState::revision() const noexcept {
    return revision_;
  }

  std::string_view SuggestionState::text() const noexcept {
    return text_.view();
  }

  Suggestion suggestion(const State& state) noexcept {
    const auto& current = Access::suggestion(state);

    return {.phase = current.phase(), .status = current.status(), .text = current.text(), .revision = current.revision(), .pending_request = current.pendingRequest()};
  }

  void suggest(State& state) noexcept {
    Access::suggestion(state).begin();
  }

  void discard(State& state) noexcept {
    Access::suggestion(state).invalidate();
  }

  tbc::view<Submission, tbc::lt::a> submit(tbc::view<const State&, tbc::lt::a> state, tbc::view<std::string_view, tbc::lt::a> task) noexcept {
    const auto& current = Access::suggestion(state);
    if (current.phase() == SuggestionPhase::ready) {
      return {.kind = Submission::Kind::insert, .text = current.text()};
    }

    if (task.empty() || current.phase() == SuggestionPhase::waiting) {
      return {};
    }

    return {.kind = Submission::Kind::ask, .text = task};
  }

  void wait(State& state, std::uint64_t request_id) noexcept {
    Access::suggestion(state).expect(request_id);
  }

  void fail(State& state) noexcept {
    Access::suggestion(state).fail();
  }

  bool receive(State& state, const CommandSuggestion& suggestion) {
    return Access::suggestion(state).receive(suggestion);
  }

}
