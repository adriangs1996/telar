module;
#include "tbc/view.hpp"

export module telar.gui.layout.snapshots;

import std;

export import telar.gui.layout.geometry;
import telar.base.memory.allocators;
import telar.base.text;
import telar.wire.layout;
import telar.wire.vocabulary;

// Interface: application/layout_token.cppm
export {
  namespace telar::gui {

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
      inline static tbc::view<std::string_view, tbc::lt::a> write(const ClientLayoutSnapshot& snapshot, tbc::view<String<Memory>&, tbc::lt::a> output) {
        std::array<Byte, binary_capacity> binary{};
        const auto encoded = Codec::encode(snapshot, binary);

        output.clear();
        output.reserve(encoded.size() * digits_per_byte);
        runtime::appendLowerHex(output, encoded);

        return output;
      }

      inline static TabLayoutPreset read(std::string_view text) {
        std::array<Byte, binary_capacity> binary{};
        const auto bytes = decodeHexadecimal(text, binary);
        constexpr auto storage_capacity = (PaneLayout::maximum_nodes * sizeof(ClientLayoutNode)) + sizeof(ClientTabLayout) + alignof(ClientLayoutNode) + alignof(ClientTabLayout);
        std::array<Byte, storage_capacity> elements{};
        DecodeStorage storage{elements};
        const auto snapshot = Codec::decode<ClientLayoutSnapshot>(bytes, storage);
        if (!snapshot.restored || !snapshot.active_tab || snapshot.tabs.size() != 1) {
          throw EncodingError{"Layout token must describe one restored tab"};
        }

        const auto& tab = snapshot.tabs.front();
        if (!sameTab(tab.location, *snapshot.active_tab)) {
          throw EncodingError{"Layout token tab does not match its active tab"};
        }

        TabLayoutPreset preset;

        preset.location = tab.location;
        preset.focused_pane = tab.focused_pane;
        preset.fullscreen = tab.fullscreen;
        preset.layout.restore(tab.nodes);

        return preset;
      }

    private:
      inline static tbc::view<std::span<const Byte>, tbc::lt::a> decodeHexadecimal(std::string_view text, tbc::view<std::span<Byte>, tbc::lt::a> output) {
        // Hexadecimal decoding error names, checked in this order.
        if (text.empty() || text.size() % digits_per_byte != 0) {
          throw EncodingError{"InvalidLength"};
        }

        if (text.size() > text_capacity) {
          throw EncodingError{"NoSpaceLeft"};
        }

        constexpr int hexadecimal_base = 16;
        const auto size = text.size() / digits_per_byte;

        for (std::size_t index = 0; index < size; ++index) {
          const auto digits = text.substr(index * digits_per_byte, digits_per_byte);
          unsigned value = 0;
          const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), value, hexadecimal_base);
          if (parsed.ec != std::errc{} || parsed.ptr != digits.data() + digits.size()) {
            throw EncodingError{"InvalidCharacter"};
          }

          output[index] = static_cast<Byte>(value);
        }

        return output.first(size);
      }
    };

  }
}

// Interface: application/navigation_history.cppm
export {
  namespace telar::gui {

    class NavigationHistory {
    public:
      static constexpr std::size_t capacity = 64;

      struct Layout {
        inline explicit Layout(const PaneLayout& layout, std::uint64_t focus) noexcept
            : count(layout.nodes().size()),
              focused_pane(focus) {
          std::ranges::copy(layout.nodes(), nodes.begin());
        }

        inline explicit Layout(std::span<const ClientLayoutNode> input, std::uint64_t focus = 0)
            : count(input.size()),
              focused_pane(focus) {
          if (input.size() > nodes.size()) {
            throw std::length_error{"Navigation layout exceeds capacity"};
          }

          std::ranges::copy(input, nodes.begin());
        }

        [[nodiscard]] inline std::span<const ClientLayoutNode> view() const noexcept {
          return std::span{nodes}.first(count);
        }

        std::array<ClientLayoutNode, PaneLayout::maximum_nodes> nodes{};
        std::size_t count = 0;
        std::uint64_t focused_pane = 0;
      };

      struct Bookmark {
        TabLocation location{};
        std::uint64_t pane_id = 0;
        std::optional<Layout> layout = std::nullopt;
        bool fullscreen = false;
      };

      inline void clear() noexcept {
        for (auto& entry : entries_) {
          entry.reset();
        }
      }

      inline void remember(const Bookmark& bookmark) noexcept {
        std::optional<Bookmark>* free = nullptr;

        for (auto& entry : entries_) {
          if (entry) {
            if (sameWorkspace(entry->location.workspace, bookmark.location.workspace)) {
              entry = bookmark;

              return;
            }
          } else if (free == nullptr) {
            free = std::addressof(entry);
          }
        }

        if (free != nullptr) {
          *free = bookmark;
        }
      }

      [[nodiscard]] inline const Bookmark* find(WorkspaceLocation workspace) const noexcept {
        for (const auto& entry : entries_) {
          if (entry && sameWorkspace(entry->location.workspace, workspace)) {
            return std::addressof(*entry);
          }
        }

        return nullptr;
      }

      inline void forget(WorkspaceLocation workspace) noexcept {
        for (auto& entry : entries_) {
          if (entry && sameWorkspace(entry->location.workspace, workspace)) {
            entry.reset();

            return;
          }
        }
      }

    private:
      std::array<std::optional<Bookmark>, capacity> entries_{};
    };

  }
}

// Interface: application/saved_layouts.cppm
export {
  namespace telar::gui {

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

      [[nodiscard]] inline std::size_t size() const noexcept {
        return count_;
      }

      [[nodiscard]] inline std::size_t nodeCount() const noexcept {
        return node_total_;
      }

      inline void clear() noexcept {
        count_ = 0;
        node_total_ = 0;
      }

      [[nodiscard]] inline View at(std::size_t index) const {
        if (index >= count_) {
          throw std::out_of_range{"Saved layout row exceeds capacity"};
        }

        const auto& row = rows_[index];

        return {.location = row.location, .pane_id = row.pane_id, .focused_pane = row.focused_pane, .workspace_active = row.workspace_active, .fullscreen = row.fullscreen, .nodes = std::span{nodes_}.subspan(row.start, row.count)};
      }

      [[nodiscard]] inline std::optional<View> find(TabLocation location) const {
        const auto index = row(location);

        return index && rows_[*index].count != 0 ? std::optional{at(*index)} : std::nullopt;
      }

      inline bool remember(View saved) noexcept {
        const auto existing = row(saved.location);
        const auto freed_rows = existing ? std::size_t{1} : 0;
        const auto freed_nodes = existing ? rows_[*existing].count : 0;
        if (count_ - freed_rows == capacity || saved.nodes.size() > nodes_.size() - node_total_ + freed_nodes || saved.nodes.size() > PaneLayout::maximum_nodes) {
          return false;
        }

        std::array<ClientLayoutNode, PaneLayout::maximum_nodes> captured{};

        std::ranges::copy(saved.nodes, captured.begin());
        if (existing) {
          remove(*existing);
        }

        rows_[count_] = {.location = saved.location, .pane_id = saved.pane_id, .focused_pane = saved.focused_pane, .workspace_active = saved.workspace_active, .fullscreen = saved.fullscreen, .start = node_total_, .count = saved.nodes.size()};
        std::copy_n(captured.begin(), saved.nodes.size(), nodes_.begin() + node_total_);
        node_total_ += saved.nodes.size();
        ++count_;

        return true;
      }

      inline void retain(View saved) noexcept {
        if (saved.nodes.size() > PaneLayout::maximum_nodes) {
          return;
        }

        std::array<ClientLayoutNode, PaneLayout::maximum_nodes> captured{};

        std::ranges::copy(saved.nodes, captured.begin());
        saved.nodes = std::span{captured}.first(saved.nodes.size());
        while (!remember(saved)) {
          if (count_ == 0) {
            return;
          }

          remove(0);
        }
      }

      inline void forget(TabLocation location) noexcept {
        if (const auto index = row(location)) {
          remove(*index);
        }
      }

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

      [[nodiscard]] inline std::optional<std::size_t> row(TabLocation location) const noexcept {
        for (std::size_t index = 0; index < count_; ++index) {
          if (sameTab(rows_[index].location, location)) {
            return index;
          }
        }

        return std::nullopt;
      }

      inline void remove(std::size_t index) noexcept {
        const auto start = rows_[index].start;
        const auto count = rows_[index].count;

        std::move(nodes_.begin() + start + count, nodes_.begin() + node_total_, nodes_.begin() + start);
        node_total_ -= count;
        std::move(rows_.begin() + index + 1, rows_.begin() + count_, rows_.begin() + index);
        --count_;
        for (auto& moved : std::span{rows_}.subspan(index, count_ - index)) {
          moved.start -= count;
        }
      }

      std::array<Row, capacity> rows_{};
      std::array<ClientLayoutNode, node_capacity> nodes_{};
      std::size_t count_ = 0;
      std::size_t node_total_ = 0;
    };

  }
}
