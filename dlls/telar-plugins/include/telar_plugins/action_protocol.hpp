#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstdint>

namespace telar::runtime::plugins {

enum class ActionTag : Byte {
  split = 1,
  focus = 2,
  sidebar = 3,
  close_pane = 4,
  new_tab = 5,
  tab_offset = 6,
  select_tab = 7,
  rename_tab = 8,
  close_tab = 9,
  move_tab = 10,
  detach = 11,
  resize = 12,
  fullscreen = 13,
  workspace_list = 14,
  new_workspace = 15,
  rename_workspace = 16,
  select_workspace = 17,
  notification = 18,
  resize_sidebar = 19,
  leave_worktree = 20,
};

struct ActionProtocol {
  static constexpr std::size_t maximum_effects = 16;
  static constexpr std::size_t maximum_bytes = sizeof(Byte) + (maximum_effects * (sizeof(Byte) + sizeof(NotificationLevel) + sizeof(std::uint32_t) + sizeof(NotificationTarget::Kind) + sizeof(std::uint64_t) + (sizeof(std::uint16_t) * 2) + max_notification_title_bytes + max_notification_message_bytes));
};

}
