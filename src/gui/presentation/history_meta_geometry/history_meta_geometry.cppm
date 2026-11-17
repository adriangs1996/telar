module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.history_meta_geometry;

import std;

import telar.tbc;
import telar.base.memory.containers;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.text;

// Interface: presentation/mode_bar_geometry.cppm
export {
  namespace telar::gui {

    struct ModeBarMeasurements {
      static constexpr std::size_t capacity = 16;
      float title = 0;
      std::array<HistoryHintMeasurements, capacity> hints{};
      std::size_t count = 0;
    };

    // The mode's badge, then its key hints in the history footer's style, as many whole ones as fit.
    struct ModeBarGeometry {
      static constexpr float title_gap = 6;
      static constexpr float hint_gap = 2;

      Rect title;
      std::array<HistoryHintGeometry, ModeBarMeasurements::capacity> hints{};
      std::size_t count = 0;

      [[nodiscard]] static ModeBarGeometry derive(Rect area, ChromeMetrics chrome, const ModeBarMeasurements& measured) noexcept;
    };

  }
}

// Interface: presentation/notification_text.cppm
export {
  namespace telar::gui {

    class NotificationText {
    public:
      static constexpr std::size_t maximum_lines = 3;

      [[nodiscard]] std::size_t count() const noexcept;

      [[nodiscard]] std::string_view line(std::size_t index) const;

      // The lines view the wrapped text, region `a`, but for a shortened last line, which the text owns.
      // Stays here: generic over the caller's measure, which the wrapping calls through a function pointer.
      template <LabelMeasure Measure>
      TBC_GENERIC void wrap(tbc::view<std::string_view, tbc::lt::a> text, float width, Measure& measure) {
        auto call = [&measure](std::string_view part) -> float {
          return measure(part);
        };

        const auto forward = [](void* target, std::string_view part) -> float {
          return (*static_cast<decltype(call)*>(target))(part);
        };

        wrapMeasured(text, width, {.target = &call, .call = forward});
      }

    private:
      static constexpr std::string_view whitespace = " \t\r\n";

      // The caller's measure behind a function pointer.
      struct Measured {
        void* target = nullptr;
        float (*call)(void*, std::string_view) = nullptr;

        float operator()(std::string_view text) const;
      };

      void wrapMeasured(tbc::view<std::string_view, tbc::lt::a> text, float width, Measured measure);

      [[nodiscard]] static std::string_view trimStart(std::string_view text) noexcept;

      [[nodiscard]] static std::size_t wrapEnd(std::string_view paragraph, float width, Measured& measure);

      void fitTail(tbc::view<std::string_view, tbc::lt::a> paragraph, bool following_paragraph, float width, Measured& measure);

      tbc::view<std::array<std::string_view, maximum_lines>, tbc::lt::a> lines_{};
      runtime::FixedText<TextFit::maximum_bytes> tail_;
      std::size_t count_ = 0;
      bool owned_tail_ = false;
    };

  }
}
