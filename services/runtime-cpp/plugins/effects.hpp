#pragma once

#include "limits.hpp"
#include "telar_client/serializers/telar_messages.hpp"

namespace telar::runtime::plugins {

struct EffectBatch {
  std::array<NotificationBody, Limits::effects> notifications;
  std::uint8_t count = 0;
};

struct EffectReply {
  std::uint64_t event_id = 0;
  EffectBatch batch;
};

struct ErrorReply {
  std::uint64_t event_id = 0;
  std::string_view message{};
};

}
