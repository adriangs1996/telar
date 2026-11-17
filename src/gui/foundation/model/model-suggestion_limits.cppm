export module telar.gui.foundation.model:suggestion_limits;

import std;

// Interface: suggestions/limits.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct SuggestionLimits {
      static constexpr std::size_t request_bytes = 512;
      static constexpr std::size_t text_bytes = 1024;
    };

  }
}
