#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>

namespace telar::gui {

template <typename Handler>
concept ClientCommandHandler = requires(Handler &handler, const ClientCommand &message, CompleteClientCommand &reply) {
  { handler(message, reply) } -> std::same_as<void>;
};

struct UnsupportedClientCommand {
  void operator()([[maybe_unused]] const ClientCommand &message, CompleteClientCommand &reply) const {
    reply.status = ClientCommandStatus::failed;
    reply.text = "Command is not supported by this client";
  }
};

}
