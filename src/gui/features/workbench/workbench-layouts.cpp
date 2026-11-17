module telar.gui.features.workbench;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text;
import telar.wire.layout;
import telar.wire.vocabulary;
import telar.gui.foundation.model;

namespace telar::gui::features::workbench {

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> LayoutToken::write(const ClientLayoutSnapshot& snapshot, tbc::view<String<Memory>&, tbc::lt::a> output) {
    std::array<Byte, binary_capacity> binary{};
    const auto encoded = Codec::encode(snapshot, binary);

    output.clear();
    output.reserve(encoded.size() * digits_per_byte);
    runtime::appendLowerHex(output, encoded);

    return output;
  }

  TabLayoutPreset LayoutToken::read(std::string_view text) {
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

  tbc::view<std::span<const Byte>, tbc::lt::a> LayoutToken::decodeHexadecimal(std::string_view text, tbc::view<std::span<Byte>, tbc::lt::a> output) {
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

  NavigationHistory::Layout::Layout(const PaneLayout& layout, std::uint64_t focus) noexcept
      : count(layout.nodes().size()),
        focused_pane(focus) {
    std::ranges::copy(layout.nodes(), nodes.begin());
  }

  NavigationHistory::Layout::Layout(std::span<const ClientLayoutNode> input, std::uint64_t focus)
      : count(input.size()),
        focused_pane(focus) {
    if (input.size() > nodes.size()) {
      throw std::length_error{"Navigation layout exceeds capacity"};
    }

    std::ranges::copy(input, nodes.begin());
  }

  std::span<const ClientLayoutNode> NavigationHistory::Layout::view() const noexcept {
    return std::span{nodes}.first(count);
  }

  void NavigationHistory::clear() noexcept {
    for (auto& entry : entries_) {
      entry.reset();
    }
  }

  void NavigationHistory::remember(const Bookmark& bookmark) noexcept {
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

  const NavigationHistory::Bookmark* NavigationHistory::find(WorkspaceLocation workspace) const noexcept {
    for (const auto& entry : entries_) {
      if (entry && sameWorkspace(entry->location.workspace, workspace)) {
        return std::addressof(*entry);
      }
    }

    return nullptr;
  }

  void NavigationHistory::forget(WorkspaceLocation workspace) noexcept {
    for (auto& entry : entries_) {
      if (entry && sameWorkspace(entry->location.workspace, workspace)) {
        entry.reset();

        return;
      }
    }
  }

  std::size_t SavedLayouts::size() const noexcept {
    return count_;
  }

  std::size_t SavedLayouts::nodeCount() const noexcept {
    return node_total_;
  }

  void SavedLayouts::clear() noexcept {
    count_ = 0;
    node_total_ = 0;
  }

  SavedLayouts::View SavedLayouts::at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Saved layout row exceeds capacity"};
    }

    const auto& row = rows_[index];

    return {.location = row.location, .pane_id = row.pane_id, .focused_pane = row.focused_pane, .workspace_active = row.workspace_active, .fullscreen = row.fullscreen, .nodes = std::span{nodes_}.subspan(row.start, row.count)};
  }

  std::optional<SavedLayouts::View> SavedLayouts::find(TabLocation location) const {
    const auto index = row(location);

    return index && rows_[*index].count != 0 ? std::optional{at(*index)} : std::nullopt;
  }

  bool SavedLayouts::remember(View saved) noexcept {
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

  void SavedLayouts::retain(View saved) noexcept {
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

  void SavedLayouts::forget(TabLocation location) noexcept {
    if (const auto index = row(location)) {
      remove(*index);
    }
  }

  std::optional<std::size_t> SavedLayouts::row(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (sameTab(rows_[index].location, location)) {
        return index;
      }
    }

    return std::nullopt;
  }

  void SavedLayouts::remove(std::size_t index) noexcept {
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

  template tbc::view<std::string_view, tbc::lt::a> LayoutToken::write<Memory>(const ClientLayoutSnapshot& snapshot, tbc::view<String<Memory>&, tbc::lt::a> output);
  template tbc::view<std::string_view, tbc::lt::a> LayoutToken::write<ConcurrentMemory>(const ClientLayoutSnapshot& snapshot, tbc::view<String<ConcurrentMemory>&, tbc::lt::a> output);

}
