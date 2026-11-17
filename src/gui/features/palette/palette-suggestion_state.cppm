// The suggestion being asked for or shown. Nothing here is exported: only the feature's own
// units name it, through State.
export module telar.gui.features.palette:suggestion_state;

import std;

import :suggestion;
import telar.base.memory.containers;
import telar.gui.foundation.model;
import telar.wire.editor;
import telar.wire.vocabulary;

namespace telar::gui::features::palette {

  class SuggestionState {
  public:
    void begin() noexcept;
    void expect(std::uint64_t request_id) noexcept;
    void invalidate() noexcept;
    bool receive(const CommandSuggestion& suggestion);

    [[nodiscard]] SuggestionPhase phase() const noexcept;
    [[nodiscard]] SuggestionStatus status() const noexcept;
    [[nodiscard]] std::uint64_t pendingRequest() const noexcept;
    [[nodiscard]] std::uint64_t revision() const noexcept;
    [[nodiscard]] std::string_view text() const noexcept;

  private:
    runtime::FixedText<SuggestionLimits::text_bytes> text_;
    std::uint64_t revision_ = 0;
    std::uint64_t pending_request_ = 0;
    SuggestionPhase phase_ = SuggestionPhase::idle;
    SuggestionStatus status_ = SuggestionStatus::ready;
  };

}
