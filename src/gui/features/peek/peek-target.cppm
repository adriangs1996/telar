// What a peek points at and what its field may ask for.
export module telar.gui.features.peek:target;

import std;

import telar.gui.foundation.model;

import telar.wire.vocabulary;

// Interface: peek/command.cppm
export {
  namespace telar::gui::features::peek {

    enum class PeekCommand : std::uint8_t {
      open,
      stop,
      diff,
      message,
    };

  }
}

// Interface: peek/limits.cppm
export {
  namespace telar::gui::features::peek {

    struct PeekLimits {
      static constexpr std::uint16_t rows = 16;
      static constexpr std::size_t row_cells = 256;
      static constexpr std::size_t cell_bytes = 4;
      static constexpr std::size_t text_bytes = rows * row_cells * cell_bytes;
      static constexpr std::size_t message_bytes = SuggestionLimits::request_bytes;
    };

  }
}

// Interface: peek/target.cppm
export {
  namespace telar::gui::features::peek {

    struct PeekTarget {
      AgentNavigationTarget agent;
      decltype(AgentSnapshotEntry::session_id) session{};

      bool operator==(const PeekTarget&) const noexcept = default;
    };

  }
}
