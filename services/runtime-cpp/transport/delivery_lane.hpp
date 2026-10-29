#pragma once

#include "telar_client/serializers/telar_messages.hpp"

namespace telar::runtime {

enum class DeliveryLane : std::uint8_t {
  stopping,
  management,
  resync,
  clipboard,
  layout,
  proxy,
  cells,
  agents,
  metrics,
  workspaces,
  cwd,
  foreground,
  title,
  progress,
  exit,
  graphics,
  observation,
  count,
};

constexpr DeliveryLane deliveryLane(ServerTag tag) {
  switch (tag) {
  case ServerTag::runtime_stopping:
    return DeliveryLane::stopping;
  case ServerTag::resync_required:
    return DeliveryLane::resync;
  case ServerTag::pane_clipboard:
    return DeliveryLane::clipboard;
  case ServerTag::client_layout_snapshot:
    return DeliveryLane::layout;
  case ServerTag::proxy_status:
    return DeliveryLane::proxy;
  case ServerTag::pane_frame:
    return DeliveryLane::cells;
  case ServerTag::agent_snapshot:
    return DeliveryLane::agents;
  case ServerTag::system_metrics:
    return DeliveryLane::metrics;
  case ServerTag::workspace_list:
    return DeliveryLane::workspaces;
  case ServerTag::pane_cwd:
    return DeliveryLane::cwd;
  case ServerTag::pane_foreground:
    return DeliveryLane::foreground;
  case ServerTag::pane_title:
    return DeliveryLane::title;
  case ServerTag::pane_progress:
    return DeliveryLane::progress;
  case ServerTag::pane_exited:
    return DeliveryLane::exit;
  case ServerTag::history_results:
    return DeliveryLane::observation;
  case ServerTag::graphics_snapshot:
  case ServerTag::graphics_image:
  case ServerTag::graphics_image_chunk:
  case ServerTag::graphics_placement:
  case ServerTag::graphics_delete_image:
  case ServerTag::graphics_delete_placement:
  case ServerTag::graphics_shared_image:
    return DeliveryLane::graphics;
  case ServerTag::pane_opened:
  case ServerTag::request_failed:
  case ServerTag::tab_snapshot:
  case ServerTag::workspace_snapshot:
  case ServerTag::tab_created:
  case ServerTag::tab_renamed:
  case ServerTag::tab_closed:
  case ServerTag::tab_moved:
  case ServerTag::notification:
  case ServerTag::notification_shown:
  case ServerTag::agent_sound:
  case ServerTag::pane_text:
  case ServerTag::request_completed:
  case ServerTag::pane_matches:
  case ServerTag::history_pruned:
  case ServerTag::history_output:
  case ServerTag::history_stats_result:
  case ServerTag::pane_focus_command:
  case ServerTag::pane_focus_result:
  case ServerTag::command_suggestion:
  case ServerTag::client_list:
  case ServerTag::client_command:
  case ServerTag::client_command_result:
  case ServerTag::editor_opened:
  case ServerTag::path_results:
  case ServerTag::worktree_registered:
  case ServerTag::limit_list:
  case ServerTag::execution_reply:
  case ServerTag::clipboard_desktop_request:
  case ServerTag::clipboard_desktop_execute:
  case ServerTag::clipboard_desktop_cancel:
    return DeliveryLane::management;
  }

  throw EncodingError{"Unknown outgoing message tag"};
}

constexpr bool responseLane(DeliveryLane lane) noexcept {
  return lane == DeliveryLane::management || lane == DeliveryLane::observation;
}

}
