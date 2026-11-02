#pragma once

#include "limits.hpp"
#include "memory/fixed_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class SuggestionPhase : std::uint8_t {
  idle,
  waiting,
  ready,
  failed,
};

class SuggestionState {
public:
  void begin() noexcept {
    pending_request_ = 0;
    phase_ = SuggestionPhase::idle;
    text_ = {};
    ++revision_;
  }

  void expect(std::uint64_t request_id) noexcept {
    pending_request_ = request_id;
    phase_ = SuggestionPhase::waiting;
    text_ = {};
    ++revision_;
  }

  void invalidate() noexcept {
    if (phase_ == SuggestionPhase::idle) {
      return;
    }

    begin();
  }

  bool receive(const CommandSuggestion &suggestion) {
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

  [[nodiscard]] SuggestionPhase phase() const noexcept {
    return phase_;
  }

  [[nodiscard]] SuggestionStatus status() const noexcept {
    return status_;
  }

  [[nodiscard]] std::uint64_t pendingRequest() const noexcept {
    return pending_request_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::string_view text() const noexcept {
    return text_.view();
  }

private:
  runtime::FixedText<SuggestionLimits::text_bytes> text_;
  std::uint64_t revision_ = 0;
  std::uint64_t pending_request_ = 0;
  SuggestionPhase phase_ = SuggestionPhase::idle;
  SuggestionStatus status_ = SuggestionStatus::ready;
};

}
