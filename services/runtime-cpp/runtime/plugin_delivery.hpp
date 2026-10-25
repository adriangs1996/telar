#pragma once

#include "../plugins/event_source.hpp"
#include "client_control.hpp"
#include "limit_service.hpp"

namespace telar::runtime {

template <Allocator Memory>
class PluginDelivery {
public:
  explicit PluginDelivery(ClientControl<Memory> &clients, LimitService<Memory> &limits) noexcept
      : clients_(clients), limits_(limits) {}

  template <plugins::EventSource Source>
  void collect(Source &source) {
    source.collect([this](const plugins::EffectBatch &batch) {
      for (const auto &notification : std::span{batch.notifications}.first(batch.count)) {
        publish(notification);
      }
    });
    const auto now = source.metrics();
    reportGrowth(now.dropped_queue, previous_.dropped_queue, {"plugins.tap.queue_depth", "exchanges", plugins::Limits::queue_depth});
    reportGrowth(now.dropped_bytes, previous_.dropped_bytes, {"plugins.tap.max_held_bytes", "bytes", plugins::Limits::held_bytes});
    reportGrowth(now.timeouts, previous_.timeouts, {"plugins.tap.reply_timeout_ms", "ms", std::chrono::duration_cast<std::chrono::milliseconds>(plugins::Limits::reply_deadline).count()});
    reportGrowth(now.disabled, previous_.disabled, {"plugins.tap.restart_limit", "restarts in 10 min", plugins::Limits::restarts});
    previous_ = now;
  }

private:
  void publish(const NotificationBody &body) {
    const Notification notification{body};
    std::array<Byte, validation_bytes> validation;
    std::span<Byte> remaining{validation};
    try {
      Codec::encode(notification, remaining);
    } catch (const EncodingError &) {
      return;
    }
    clients_.publish(notification);
  }

  void reportGrowth(std::uint64_t current, std::uint64_t previous, const LimitReach &reach) {
    if (current > previous) {
      limits_.report(reach);
    }
  }

  static constexpr std::size_t validation_bytes = 512;
  ClientControl<Memory> &clients_;
  LimitService<Memory> &limits_;
  plugins::TapMetrics previous_;
};

template <Allocator Memory>
PluginDelivery(ClientControl<Memory> &clients, LimitService<Memory> &limits) -> PluginDelivery<Memory>;

}
