#pragma once

#include "pane_layout.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>

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

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] std::size_t nodeCount() const noexcept {
    return node_total_;
  }

  void clear() noexcept {
    count_ = 0;
    node_total_ = 0;
  }

  [[nodiscard]] View at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Saved layout row exceeds capacity"};
    }

    const auto &row = rows_[index];

    return {.location = row.location, .pane_id = row.pane_id, .focused_pane = row.focused_pane, .workspace_active = row.workspace_active, .fullscreen = row.fullscreen, .nodes = std::span{nodes_}.subspan(row.start, row.count)};
  }

  [[nodiscard]] std::optional<View> find(TabLocation location) const {
    const auto index = row(location);

    return index && rows_[*index].count != 0 ? std::optional{at(*index)} : std::nullopt;
  }

  bool remember(View saved) noexcept {
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

  void retain(View saved) noexcept {
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

  void forget(TabLocation location) noexcept {
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

  [[nodiscard]] std::optional<std::size_t> row(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (sameTab(rows_[index].location, location)) {
        return index;
      }
    }

    return std::nullopt;
  }

  void remove(std::size_t index) noexcept {
    const auto start = rows_[index].start;
    const auto count = rows_[index].count;
    std::move(nodes_.begin() + start + count, nodes_.begin() + node_total_, nodes_.begin() + start);
    node_total_ -= count;
    std::move(rows_.begin() + index + 1, rows_.begin() + count_, rows_.begin() + index);
    --count_;
    for (auto &moved : std::span{rows_}.subspan(index, count_ - index)) {
      moved.start -= count;
    }
  }

  std::array<Row, capacity> rows_{};
  std::array<ClientLayoutNode, node_capacity> nodes_{};
  std::size_t count_ = 0;
  std::size_t node_total_ = 0;
};

}
