// Where an agent card's rows, mark and badge go, and when its status pulses next.
export module telar.gui.features.activity:presentation;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.wire.vocabulary;

// Interface: presentation/agent_card_geometry.cppm
export {
  namespace telar::gui::features::activity {

    struct AgentCardGeometry {
      static constexpr float horizontal_padding = 8;
      static constexpr float vertical_padding = 8;
      static constexpr float task_indent = 12;
      static constexpr float spacing = 3;
      static constexpr float radius = ChromeStyle::surface_radius;
      static constexpr float gap = 6;
      static constexpr float mark_side = 14;
      static constexpr float tile_width = 18;
      static constexpr float tile_height = 14;
      // Every card keeps its mark in this column, so titles and details share one left edge.
      static constexpr float mark_column = 24;
      static constexpr float project_label_gap = 4;
      static constexpr float title_gap = 4;
      static constexpr float total_row_spacing = 6;
      static constexpr float group_gap = 8;
      static constexpr float scrollbar_width = 3;
      static constexpr float icon_size_ratio = 0.85F;
      static constexpr float provider_alpha = 0.6F;
      // The badge that carries an agent's state on the lower right corner of its tile.
      static constexpr float badge_side = 11;
      // The plan's progress line under an agent card's rows.
      static constexpr float plan_bar_height = 2;
      // The tint and ring of a card whose agent waits on the person.
      static constexpr float attention_alpha = 0.075F;
      static constexpr float attention_outline_alpha = 0.22F;

      enum class Row : std::uint8_t {
        context,
        title,
        detail,
      };

      float small_row = 0;
      float title_row = 0;
      float scale = 1;

      [[nodiscard]] static AgentCardGeometry derive(const ChromeMetrics& chrome) noexcept;
      [[nodiscard]] float px(float logical) const noexcept;
      // Where a card's text starts: past its inset, its mark column and the gap after it.
      [[nodiscard]] float textInset() const noexcept;
      [[nodiscard]] float height() const noexcept;
      [[nodiscard]] float agentHeight() const noexcept;
      [[nodiscard]] float cardWidth(float list_width) const noexcept;
      // The list width whose cards are `card_width` wide.
      [[nodiscard]] float listWidth(float card_width) const noexcept;
      [[nodiscard]] Rect row(Rect bounds, Row role) const noexcept;
    };

  }
}

// Interface: presentation/agent_animation.cppm
export {
  namespace telar::gui::features::activity {

    struct AgentAnimation {
      static constexpr std::uint64_t pulse_interval_ns = 120'000'000;

      [[nodiscard]] static float alpha(std::uint64_t now_ns) noexcept;
      [[nodiscard]] static std::optional<std::uint64_t> deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept;
    };

  }
}
