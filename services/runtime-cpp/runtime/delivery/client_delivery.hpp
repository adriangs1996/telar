#pragma once

#include "../response_projection.hpp"
#include "attachment_delivery.hpp"

namespace telar::runtime {

template <typename Source, typename Memory>
concept RuntimeStateSource = Allocator<Memory> && requires(Source &source, ClientSession<Memory> &client, const RuntimeModel<Memory> &model, DeliveryLane lane) {
  { source.prepare(client, model, lane) } -> std::same_as<bool>;
};

template <Allocator Memory>
class ClientDelivery {
public:
  using Clock = std::chrono::steady_clock;

  struct Result {
    std::chrono::nanoseconds timeout = std::chrono::nanoseconds::max();
    std::optional<std::uint64_t> detach_pane;
  };

  explicit ClientDelivery(Memory &memory, RuntimeModel<Memory> &model) : memory_(memory), model_(model) {}

  template <RuntimeStateSource<Memory> Source>
  Result write(ClientSession<Memory> &client, Source &source, Clock::time_point now) {
    TELAR_TRACE("runtime.deliverClient");
    Result result;
    if (!client.connection.writing() && !client.connection.closing) {
      prepare(client, source, now, result.timeout);
    }

    if (!client.connection.hasOutput()) {
      return result;
    }

    client.connection.write(ResponseProjection{memory_, model_});
    if (!client.connection.writing()) {
      result.timeout = std::chrono::nanoseconds::zero();
      result.detach_pane = std::exchange(client.completing_exit, std::nullopt);
    }
    return result;
  }

private:
  template <RuntimeStateSource<Memory> Source>
  void prepare(ClientSession<Memory> &client, Source &source, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    const auto queued_lane = client.connection.nextLane();
    if (queued_lane <= DeliveryLane::management) {
      return;
    }

    if (resync(client) || clipboard(client)) {
      return;
    }

    for (const auto lane : {DeliveryLane::layout, DeliveryLane::proxy}) {
      if (queued_lane <= lane || source.prepare(client, model_, lane)) {
        return;
      }
    }

    AttachmentDelivery attachments{model_, client};
    if (queued_lane <= DeliveryLane::cells || attachments.prepare(DeliveryLane::cells, now, timeout)) {
      return;
    }

    for (const auto lane : {DeliveryLane::agents, DeliveryLane::metrics, DeliveryLane::workspaces}) {
      if (queued_lane <= lane || source.prepare(client, model_, lane)) {
        return;
      }
    }

    for (const auto lane : {DeliveryLane::cwd, DeliveryLane::foreground, DeliveryLane::title, DeliveryLane::progress, DeliveryLane::exit, DeliveryLane::graphics}) {
      if (queued_lane <= lane || attachments.prepare(lane, now, timeout)) {
        return;
      }

      if (lane == DeliveryLane::foreground && foreground(client)) {
        return;
      }
    }
  }

  bool resync(ClientSession<Memory> &client) {
    if (!client.workspace_resync) {
      return false;
    }

    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_resyncs));
    auto &change = *client.workspace_resync;
    change.workspace_closed = model_.workspaces.find(change.workspace.id) == nullptr;
    client.connection.send(change);
    client.workspace_resync.reset();
    return true;
  }

  bool clipboard(ClientSession<Memory> &client) {
    if (client.clipboard.pending()) {
      client.connection.send(client.clipboard.message());
      client.clipboard.delivered();
      return true;
    }

    for (const auto &attachment : client.attachments) {
      const auto *pane = model_.panes.find(attachment->pane_id);
      if (pane == nullptr || attachment->clipboard_revision == pane->terminal.effects.clipboard_revision) {
        continue;
      }

      client.connection.send(PaneClipboard{pane->id, pane->terminal.effects.clipboard});
      attachment->clipboard_revision = pane->terminal.effects.clipboard_revision;
      return true;
    }
    return false;
  }

  bool foreground(ClientSession<Memory> &client) {
    if (!client.subscribed) {
      return false;
    }

    const auto panes = model_.panes.items();
    for (std::size_t slot = 0; slot < panes.size(); ++slot) {
      const auto *pane = panes[slot];
      if (pane == nullptr || pane->exit_status || pane->close_requested || (pane->observers & model_.clientBit(client.id)) != 0) {
        continue;
      }

      auto &sent = client.foregrounds[slot];
      if (sent.pane != pane->id || sent.revision != pane->foreground_revision) {
        client.connection.send(PaneForeground{pane->id, pane->foreground.view()});
        sent = {pane->id, pane->foreground_revision};
        return true;
      }
    }
    return false;
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
};

}
