#pragma once

#include "../model/runtime_model.hpp"
#include "line.hpp"
#include "media_queue.hpp"

namespace telar::runtime::diagnostics {

template <Allocator Memory>
void writeRuntimeSample(Line &line, RuntimeModel<Memory> &model) {
  std::size_t tabs = 0;
  std::size_t attachments = 0;
  std::size_t outstanding_frames = 0;
  std::size_t dirty_panes = 0;
  std::size_t response_queue_bytes = 0;
  std::size_t response_queue_depth = 0;
  std::size_t response_queue_high_water = 0;
  std::uint64_t response_queue_dropped = 0;
  std::size_t pane_input_queue_depth = 0;
  std::uint64_t pane_input_dropped_bytes = 0;
  std::size_t pty_response_queue_depth = 0;
  std::size_t pty_response_queue_bytes = 0;
  std::uint64_t pty_response_dropped = 0;
  std::size_t pane_media_used = 0;
  MediaQueue media_queue;
  GraphicsStorageSnapshot graphics_storage;
  TerminalStorageSnapshot terminal_storage;
  for (const auto *workspace : model.workspaces.items()) {
    if (workspace != nullptr) {
      tabs += workspace->tabs.size();
    }
  }

  for (const auto *client : model.clients.items()) {
    if (client == nullptr) {
      continue;
    }

    attachments += client->attachments.size();
    response_queue_bytes += client->connection.queuedBytes();
    response_queue_depth += client->connection.responseDepth();
    response_queue_high_water += client->connection.responseHighWater();
    accumulate(response_queue_dropped, client->connection.droppedResponses());
    for (const auto &attachment : client->attachments) {
      outstanding_frames += attachment->frames.waitingForAck();
      accumulate(graphics_storage.transfer_bytes, attachment->graphics.transferBytes());
    }
  }

  for (auto *pane : model.panes.items()) {
    if (pane == nullptr) {
      continue;
    }

    dirty_panes += pane->terminal.dirty();
    pane_input_queue_depth += pane->input.size();
    accumulate(pane_input_dropped_bytes, pane->input_dropped_bytes);
    const auto responses = pane->pty_responses->snapshot();
    pty_response_queue_depth += responses.messages;
    pty_response_queue_bytes += responses.bytes;
    accumulate(pty_response_dropped, responses.dropped);
    pane_media_used += pane->media->usedBytes();
    media_queue.merge(pane->media->queueMetrics());
    graphics_storage.merge(pane->media->storageMetrics());
    terminal_storage.merge(pane->terminal.storageMetrics());
  }

  line.field("client_count", model.clients.size());
  line.field("workspace_count", model.workspaces.size());
  line.field("tab_count", tabs);
  line.field("pane_count", model.panes.size());
  line.field("attachment_count", attachments);
  line.field("outstanding_frames", outstanding_frames);
  line.field("dirty_panes", dirty_panes);
  line.field("response_queue_bytes", response_queue_bytes);
  line.field("response_queue_depth", response_queue_depth);
  line.field("response_queue_high_water", response_queue_high_water);
  line.field("response_queue_dropped", response_queue_dropped);
  line.field("pane_input_queue_depth", pane_input_queue_depth);
  line.field("pane_input_dropped_bytes", pane_input_dropped_bytes);
  line.field("pty_response_queue_depth", pty_response_queue_depth);
  line.field("pty_response_queue_bytes", pty_response_queue_bytes);
  line.field("pty_response_dropped", pty_response_dropped);
  line.field("graphics_budget_used", model.media_budget.used());
  line.field("pane_media_used", pane_media_used);
  media_queue.write(line);
  graphics_storage.write(line);
  terminal_storage.write(line);
}

}
