#pragma once

#include "runtime_model.hpp"
#include "telar_base/request_error.hpp"
#include <algorithm>

namespace telar::runtime {

template <Allocator Memory>
class ClientLayouts {
public:
  explicit ClientLayouts(Memory &memory, const RuntimeModel<Memory> &model)
      : model_(model),
        records_(AllocatorRef<Record, Memory>{memory}) {
    records_.reserve(maximum_identities);
  }

  void retain(std::uint64_t identity, const UpdateClientLayout &update) {
    if (identity == 0) {
      throw RequestError{FailureCode::invalid_request, "Client layout requires a subscribed identity"};
    }

    bool active_valid = false;
    for (const auto &tab : update.tabs) {
      if (sameLocation(tab.location, update.active_tab)) {
        active_valid = current(tab);
      }
    }

    if (!active_valid) {
      return;
    }

    auto *existing = find(identity);
    Record replacement;
    replacement.identity = identity;
    replacement.last_used = clock_ + 1;
    replacement.sidebar_visible = update.sidebar_visible;
    replacement.sidebar_width = update.sidebar_width;
    replacement.workspace_list_collapsed = update.workspace_list_collapsed;
    replacement.active_tab = update.active_tab;

    if (existing != nullptr) {
      for (std::size_t index = 0; index < existing->tab_count; ++index) {
        auto tab = existing->tabAt(index);
        if (!current(tab) || std::ranges::any_of(update.tabs, [&](const auto &incoming) { return current(incoming) && sameLocation(incoming.location, tab.location); })) {
          continue;
        }

        if (std::ranges::any_of(update.tabs, [&](const auto &incoming) { return incoming.workspace_active && sameWorkspace(incoming.location.workspace, tab.location.workspace) && current(incoming); })) {
          tab.workspace_active = false;
        }

        replacement.append(tab);
      }
    }

    for (const auto &tab : update.tabs) {
      if (current(tab)) {
        replacement.append(tab);
      }
    }

    if (existing == nullptr) {
      if (records_.size() < maximum_identities) {
        records_.emplace_back();
        existing = &records_.back();
      } else {
        existing = &*std::ranges::min_element(records_, {}, &Record::last_used);
        ++evictions_;
      }
    }

    *existing = replacement;
    ++clock_;
  }

  void publish(ClientSession<Memory> &client) {
    auto *record = find(client.identity);
    if (record == nullptr) {
      client.connection.send(ClientLayoutSnapshot{});
      return;
    }

    std::array<ClientTabLayout, maximum_tabs> tabs;
    std::size_t count = 0;
    std::optional<TabLocation> active;
    for (std::size_t index = 0; index < record->tab_count; ++index) {
      const auto tab = record->tabAt(index);
      if (!current(tab)) {
        continue;
      }

      tabs[count++] = tab;
      if (sameLocation(tab.location, record->active_tab)) {
        active = tab.location;
      }
    }

    record->last_used = ++clock_;
    client.connection.send(ClientLayoutSnapshot{
        .restored = true,
        .sidebar_visible = record->sidebar_visible,
        .sidebar_width = record->sidebar_width,
        .workspace_list_collapsed = record->workspace_list_collapsed,
        .active_tab = active,
        .tabs = std::span{tabs}.first(count),
    });
  }

  std::optional<std::uint64_t> focusedPane(std::uint64_t identity) const noexcept {
    for (const auto &record : records_) {
      if (record.identity != identity) {
        continue;
      }

      for (std::size_t index = 0; index < record.tab_count; ++index) {
        const auto &tab = record.tabs[index];
        if (sameLocation(tab.location, record.active_tab)) {
          return tab.focused_pane;
        }
      }
    }

    return std::nullopt;
  }

  std::uint64_t evictions() const noexcept {
    return evictions_;
  }

  std::uint64_t revision() const noexcept {
    return clock_;
  }

  template <typename Consumer>
  void exportRecords(Consumer &&consume) const {
    std::array<ClientTabLayout, maximum_tabs> tabs;
    for (const auto &record : records_) {
      std::size_t count = 0;
      bool active_valid = false;
      for (std::size_t index = 0; index < record.tab_count; ++index) {
        const auto tab = record.tabAt(index);
        if (!current(tab)) {
          continue;
        }

        tabs[count++] = tab;
        active_valid |= sameLocation(tab.location, record.active_tab);
      }
      if (!active_valid) {
        continue;
      }

      consume(record.identity, record.last_used, UpdateClientLayout{record.sidebar_visible, record.sidebar_width, record.workspace_list_collapsed, record.active_tab, std::span{tabs}.first(count)});
    }
  }

private:
  static constexpr std::size_t maximum_identities = 16;
  static constexpr std::size_t maximum_tabs = 256;
  static constexpr std::size_t maximum_nodes = 511;

  struct StoredTab {
    TabLocation location;
    std::uint64_t focused_pane;
    bool fullscreen;
    bool workspace_active;
    std::uint16_t node_start;
    std::uint16_t node_count;
  };

  struct Record {
    std::uint64_t identity = 0;
    std::uint64_t last_used = 0;
    bool sidebar_visible = true;
    std::uint16_t sidebar_width = 0;
    bool workspace_list_collapsed = false;
    TabLocation active_tab{};
    std::array<StoredTab, maximum_tabs> tabs{};
    std::array<ClientLayoutNode, maximum_nodes> nodes{};
    std::size_t tab_count = 0;
    std::size_t node_count = 0;

    ClientTabLayout tabAt(std::size_t index) const noexcept {
      const auto &tab = tabs[index];
      return ClientTabLayout{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, std::span{nodes}.subspan(tab.node_start, tab.node_count)};
    }

    void append(const ClientTabLayout &tab) {
      if (tab_count == maximum_tabs || tab.nodes.size() > maximum_nodes - node_count) {
        throw std::bad_alloc{};
      }

      tabs[tab_count++] = StoredTab{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, static_cast<std::uint16_t>(node_count), static_cast<std::uint16_t>(tab.nodes.size())};
      std::copy(tab.nodes.begin(), tab.nodes.end(), nodes.begin() + node_count);
      node_count += tab.nodes.size();
    }
  };

  static bool sameWorkspace(WorkspaceLocation left, WorkspaceLocation right) noexcept {
    return left.kind == right.kind && left.id == right.id;
  }

  static bool sameLocation(TabLocation left, TabLocation right) noexcept {
    return sameWorkspace(left.workspace, right.workspace) && left.tab_id == right.tab_id;
  }

  bool current(const ClientTabLayout &layout) const noexcept {
    auto *workspace = model_.workspaces.find(layout.location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(layout.location.tab_id);
    if (layout.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      return false;
    }

    std::size_t pane_count = 0;
    for (const auto &node : layout.nodes) {
      const auto *leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf == nullptr) {
        continue;
      }

      if (model_.panes.find(leaf->pane_id) == nullptr || std::ranges::find(tab->panes, leaf->pane_id) == tab->panes.end()) {
        return false;
      }

      ++pane_count;
    }

    return pane_count == tab->panes.size();
  }

  Record *find(std::uint64_t identity) noexcept {
    for (auto &record : records_) {
      if (record.identity == identity) {
        return &record;
      }
    }

    return nullptr;
  }

  const RuntimeModel<Memory> &model_;
  Vector<Record, Memory> records_;
  std::uint64_t clock_ = 0;
  std::uint64_t evictions_ = 0;
};

}
