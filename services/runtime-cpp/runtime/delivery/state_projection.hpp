#pragma once

#include "../../model/runtime_model.hpp"

namespace telar::runtime {

template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
class StateProjection {
public:
  explicit StateProjection(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy)
      : workspaces_(workspaces), agents_(agents), metrics_(metrics), layouts_(layouts), proxy_(proxy) {}

  template <Allocator Memory>
    requires requires(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy, ClientSession<Memory> &client) {
      workspaces.publishList(client);
      agents.query(client);
      { agents.revision() } -> std::convertible_to<std::uint64_t>;
      metrics.publish(client);
      layouts.publish(client);
      { proxy.status() } -> std::convertible_to<ProxyStatus>;
    }
  bool prepare(ClientSession<Memory> &client, const RuntimeModel<Memory> &model, DeliveryLane lane) {
    switch (lane) {
    case DeliveryLane::layout:
      if (client.subscribed && !client.layout_sent) {
        layouts_.publish(client);
        client.layout_sent = true;
        return true;
      }
      return false;
    case DeliveryLane::proxy:
      if (client.subscribed && !client.proxy_status_sent) {
        client.connection.send(proxy_.status());
        client.proxy_status_sent = true;
        return true;
      }
      return false;
    case DeliveryLane::agents:
      if (client.agent_snapshot_requested || (client.subscribed && (client.agent_revision != agents_.revision() || client.agent_workspace_revision != model.workspace_revision))) {
        agents_.query(client);
        client.agent_snapshot_requested = false;
        return true;
      }
      return false;
    case DeliveryLane::metrics: {
      const auto queued = client.connection.queuedBytes();
      metrics_.publish(client);
      return queued != client.connection.queuedBytes();
    }
    case DeliveryLane::workspaces:
      if (client.subscribed && client.workspace_revision != model.workspace_revision) {
        workspaces_.publishList(client);
        return true;
      }
      return false;
    default:
      return false;
    }
  }

private:
  Workspaces &workspaces_;
  Agents &agents_;
  Metrics &metrics_;
  Layouts &layouts_;
  const Proxy &proxy_;
};

template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
StateProjection(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy) -> StateProjection<Workspaces, Agents, Metrics, Layouts, Proxy>;

}
