module;
#include <cstring>
#include <cstdio>

#include <cstddef>

#include <cstdint>

export module telar.gui.suggestions.state;

import std;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;


// Interface: suggestions/limits.cppm
export {
namespace telar::gui {

struct SuggestionLimits {
  static constexpr std::size_t request_bytes = 512;
  static constexpr std::size_t text_bytes = 1024;
};

}
}

// Interface: suggestions/state.cppm
export {
namespace telar::gui {

enum class SuggestionPhase : std::uint8_t {
  idle,
  waiting,
  ready,
  failed,
};

class SuggestionState {
public:
  inline void begin() noexcept {
    pending_request_ = 0;
    phase_ = SuggestionPhase::idle;
    text_ = {};
    ++revision_;
  }

  inline void expect(std::uint64_t request_id) noexcept {
    pending_request_ = request_id;
    phase_ = SuggestionPhase::waiting;
    text_ = {};
    ++revision_;
  }

  inline void invalidate() noexcept {
    if (phase_ == SuggestionPhase::idle) {
      return;
    }

    begin();
  }

  inline bool receive(const CommandSuggestion &suggestion) {
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

  [[nodiscard]] inline SuggestionPhase phase() const noexcept {
    return phase_;
  }

  [[nodiscard]] inline SuggestionStatus status() const noexcept {
    return status_;
  }

  [[nodiscard]] inline std::uint64_t pendingRequest() const noexcept {
    return pending_request_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::string_view text() const noexcept {
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
}
