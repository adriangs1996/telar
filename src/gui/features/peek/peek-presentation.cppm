// How a peek shows its agent: the title and facts of its header, and where its parts sit in the
// cells of the workbench.
export module telar.gui.features.peek:presentation;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.foundation.text;

// Interface: presentation/peek_labels.cppm
export {
  namespace telar::gui::features::peek {

    struct PeekLabels {
      static constexpr std::size_t facts_bytes = 256;
      using Facts = BoundedText<facts_bytes>;

      template <Allocator Memory>
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> title(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Facts facts(const Agent<Memory>& agent, const Worktree<Memory>* task);

    private:
      static void append(Facts& storage, std::string_view text);
      static void decimal(Facts& storage, std::uint16_t value);
    };

    extern template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<Memory>(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept;
    extern template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<ConcurrentMemory>(tbc::view<const Agent<ConcurrentMemory>&, tbc::lt::a> agent, tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> task) noexcept;
    extern template PeekLabels::Facts PeekLabels::facts<Memory>(const Agent<Memory>& agent, const Worktree<Memory>* task);
    extern template PeekLabels::Facts PeekLabels::facts<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent, const Worktree<ConcurrentMemory>* task);

    // The last `count` lines of `text`, its trailing blanks left out: what fits the screen of a
    // peek `count` rows high.
    [[nodiscard]] std::string_view lastLines(std::string_view text, std::uint16_t count) noexcept;

  }
}

// Interface: presentation/peek_geometry.cppm
export {
  namespace telar::gui::features::peek {

    struct PeekGeometry {
      static constexpr CellRectangle requested_size{.width = 96, .height = 24};
      static constexpr std::uint16_t chrome_rows = 4;
      static constexpr std::uint16_t field_rows_from_end = 2;

      CellRectangle bounds;
      CellRectangle title;
      CellRectangle facts;
      CellRectangle screen;
      CellRectangle field;
      CellRectangle footer;

      [[nodiscard]] static PeekGeometry measure(CellRectangle host) noexcept;
    };

  }
}
