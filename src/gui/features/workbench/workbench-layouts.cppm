// The layouts the workbench keeps: the token a tab's layout travels in, the pane and layout the
// user left each workspace on, and the layouts saved for tabs the session restores.
export module telar.gui.features.workbench:layouts;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.gui.foundation.model;
import telar.wire.layout;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/layout_token.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabLayoutPreset {
      TabLocation location;
      PaneLayout layout;
      std::uint64_t focused_pane = 0;
      bool fullscreen = false;
    };

    class LayoutToken {
    public:
      static constexpr std::size_t text_capacity = 4096;
      static constexpr std::size_t digits_per_byte = 2;
      static constexpr std::size_t binary_capacity = text_capacity / digits_per_byte;

      template <Allocator Memory>
      // The token is written into the output, region `a`.
      static tbc::view<std::string_view, tbc::lt::a> write(const ClientLayoutSnapshot& snapshot, tbc::view<ds::String<Memory>&, tbc::lt::a> output);

      static TabLayoutPreset read(std::string_view text);

    private:
      static tbc::view<std::span<const Byte>, tbc::lt::a> decodeHexadecimal(std::string_view text, tbc::view<std::span<Byte>, tbc::lt::a> output);
    };

    extern template tbc::view<std::string_view, tbc::lt::a> LayoutToken::write<Memory>(const ClientLayoutSnapshot& snapshot, tbc::view<ds::String<Memory>&, tbc::lt::a> output);
    extern template tbc::view<std::string_view, tbc::lt::a> LayoutToken::write<ConcurrentMemory>(const ClientLayoutSnapshot& snapshot, tbc::view<ds::String<ConcurrentMemory>&, tbc::lt::a> output);

  }
}

// Interface: application/navigation_history.cppm
export {
  namespace telar::gui::features::workbench {

    class NavigationHistory {
    public:
      static constexpr std::size_t capacity = 64;

      struct Layout {
        explicit Layout(const PaneLayout& layout, std::uint64_t focus) noexcept;
        explicit Layout(std::span<const ClientLayoutNode> input, std::uint64_t focus = 0);

        [[nodiscard]] std::span<const ClientLayoutNode> view() const noexcept;

        ds::Array<ClientLayoutNode, PaneLayout::maximum_nodes> nodes{};
        std::size_t count = 0;
        std::uint64_t focused_pane = 0;
      };

      struct Bookmark {
        TabLocation location{};
        std::uint64_t pane_id = 0;
        ds::Option<Layout> layout = ds::none;
        bool fullscreen = false;
      };

      void clear() noexcept;
      void remember(const Bookmark& bookmark) noexcept;
      [[nodiscard]] const Bookmark* find(WorkspaceLocation workspace) const noexcept;
      void forget(WorkspaceLocation workspace) noexcept;

    private:
      ds::Array<ds::Option<Bookmark>, capacity> entries_{};
    };

  }
}

// Interface: application/saved_layouts.cppm
export {
  namespace telar::gui::features::workbench {

    class SavedLayouts {
    public:
      static constexpr std::size_t capacity = 256;
      static constexpr std::size_t node_capacity = (capacity * 2) - 1;

      struct View {
        TabLocation location{};
        std::uint64_t pane_id = 0;
        std::uint64_t focused_pane = 0;
        bool workspace_active = false;
        bool fullscreen = false;
        std::span<const ClientLayoutNode> nodes;
      };

      [[nodiscard]] std::size_t size() const noexcept;
      [[nodiscard]] std::size_t nodeCount() const noexcept;
      void clear() noexcept;
      [[nodiscard]] View at(std::size_t index) const;
      [[nodiscard]] ds::Option<View> find(TabLocation location) const;
      bool remember(View saved) noexcept;
      void retain(View saved) noexcept;
      void forget(TabLocation location) noexcept;

    private:
      struct Row {
        TabLocation location{};
        std::uint64_t pane_id = 0;
        std::uint64_t focused_pane = 0;
        bool workspace_active = false;
        bool fullscreen = false;
        std::size_t start = 0;
        std::size_t count = 0;
      };

      [[nodiscard]] ds::Option<std::size_t> row(TabLocation location) const noexcept;
      void remove(std::size_t index) noexcept;

      ds::Array<Row, capacity> rows_{};
      ds::Array<ClientLayoutNode, node_capacity> nodes_{};
      std::size_t count_ = 0;
      std::size_t node_total_ = 0;
    };

  }
}
