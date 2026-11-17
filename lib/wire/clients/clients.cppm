module;
#include "telar_wire/protocol/clients.hpp"

export module telar.wire.clients;

// Connected clients, the commands sent between them and notifications.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.
//
// The vocabulary declares `ClientCommand`. This module carries its schema and exports the
// name too, so the units that send or decode it import this module.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::ClientCommand;
  using telar::ClientCommandResult;
  using telar::ClientList;
  using telar::CompleteClientCommand;
  using telar::DetachClient;
  using telar::Notification;
  using telar::NotificationShown;
  using telar::QueryClients;
  using telar::RequestClientCommand;
  using telar::ShowNotification;
}
