#pragma once

#include "../model/runtime_model.hpp"

namespace telar::runtime {

template <Allocator Memory>
void notifyWorkspaceObservers(RuntimeModel<Memory> &model, std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous = {}) noexcept {
  for (auto *client : model.clients.items()) {
    if (client != nullptr && client->id != origin && client->connection.negotiated && !client->connection.closing && client->workspace == workspace) {
      client->workspace_resync = ResyncRequired{.workspace = {.id = workspace}, .previous_workspace = previous};
    }
  }
}

template <Allocator Memory>
std::optional<std::uint64_t> previousWorkspace(const RuntimeModel<Memory> &model, std::uint64_t identity) noexcept {
  const auto items = model.workspaces.items();
  for (std::size_t index = 0; index < items.size(); ++index) {
    if (items[index] == nullptr || items[index]->id != identity) {
      continue;
    }

    for (std::size_t offset = 1; offset < items.size(); ++offset) {
      const auto *previous = items[(index + items.size() - offset) % items.size()];
      if (previous != nullptr) {
        return previous->id;
      }
    }
    break;
  }

  return std::nullopt;
}

}
