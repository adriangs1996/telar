#pragma once

#include "pane_layout.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>

namespace telar::gui {

class NavigationHistory {
public:
  static constexpr std::size_t capacity = 64;

  struct Layout {
    explicit Layout(const PaneLayout &layout, std::uint64_t focus) noexcept
        : count(layout.nodes().size()),
          focused_pane(focus) {
      std::ranges::copy(layout.nodes(), nodes.begin());
    }

    explicit Layout(std::span<const ClientLayoutNode> input, std::uint64_t focus = 0)
        : count(input.size()),
          focused_pane(focus) {
      if (input.size() > nodes.size()) {
        throw std::length_error{"Navigation layout exceeds capacity"};
      }

      std::ranges::copy(input, nodes.begin());
    }

    [[nodiscard]] std::span<const ClientLayoutNode> view() const noexcept {
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

  void clear() noexcept {
    for (auto &entry : entries_) {
      entry.reset();
    }
  }

  void remember(const Bookmark &bookmark) noexcept {
    std::optional<Bookmark> *free = nullptr;
    for (auto &entry : entries_) {
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

  [[nodiscard]] const Bookmark *find(WorkspaceLocation workspace) const noexcept {
    for (const auto &entry : entries_) {
      if (entry && sameWorkspace(entry->location.workspace, workspace)) {
        return std::addressof(*entry);
      }
    }

    return nullptr;
  }

  void forget(WorkspaceLocation workspace) noexcept {
    for (auto &entry : entries_) {
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
