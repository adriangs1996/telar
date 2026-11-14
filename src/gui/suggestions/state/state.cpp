module telar.gui.suggestions.state;

import telar.base.diagnostics;

namespace telar::gui {

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

}
