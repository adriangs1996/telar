export module telar.gui.suggestions.state;

import std;

import telar.base.memory.containers;
import telar.wire.editor;
import telar.wire.vocabulary;

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
}
