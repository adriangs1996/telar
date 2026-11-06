#pragma once

#include "../model/runtime_model.hpp"
#include "telar_client/request_error.hpp"

namespace telar::runtime {

template <Allocator Memory>
class ClientControl {
public:
  explicit ClientControl(RuntimeModel<Memory> &model) noexcept
      : model_(model) {}

  void list(ClientSession<Memory> &requester, const QueryClients &request) const {
    std::array<ClientDescriptor, 32> entries;
    std::size_t count = 0;

    for (const auto *client : model_.clients.items()) {
      if (!routable(client)) {
        continue;
      }

      entries[count++] = ClientDescriptor{
          .id = client->id,
          .generation = client->generation,
          .identity = client->identity,
          .attachments = static_cast<std::uint16_t>(client->attachments.size()),
          .last_input_pane = client->last_input_pane,
          .last_input_sequence = client->last_input_sequence,
      };
    }

    requester.connection.send(ClientList{.request_id = request.request_id,
                                         .entries = std::span{entries}.first(count)});
  }

  void detach(ClientSession<Memory> &requester, const DetachClient &request) {
    requireRole(requester, ClientRole::control);
    auto *target = resolve(ClientRoute{request.client_id, request.client_generation});
    if (!routable(target) || target == &requester) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    requester.connection.send(RequestCompleted{.request_id = request.request_id});
    target->connection.closing = true;
  }

  void requestCommand(ClientSession<Memory> &requester, const RequestClientCommand &request) {
    requireRole(requester, ClientRole::control);
    if (request.status != ClientCommandStatus::request || requester.pending_command) {
      throw RequestError{FailureCode::invalid_request, "Invalid or already pending client command"};
    }

    auto *target = resolve(request.route);
    if (!routable(target)) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    ClientCommand forwarded = request;
    forwarded.route = route(requester);
    try {
      target->connection.send(forwarded);
    } catch (const ResponseQueueFull &) {
      throw RequestError{FailureCode::invalid_request, "ResponseQueueFull"};
    }
    requester.pending_command = PendingClientCommand{target->id, request.request_id, request.action, request.target_id};
  }

  void completeCommand(ClientSession<Memory> &sender, const CompleteClientCommand &completion) {
    requireRole(sender, ClientRole::interactive);
    auto *requester = resolve(completion.route);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_command) {
      return;
    }

    const auto &pending = *requester->pending_command;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.action != completion.action || pending.target_id != completion.target_id || completion.status == ClientCommandStatus::request) {
      return;
    }

    ClientCommandResult result;
    static_cast<ClientCommand &>(result) = completion;
    result.route = route(sender);
    requester->connection.send(result);
    requester->pending_command.reset();
  }

  void requestFocus(ClientSession<Memory> &requester, const RequestPaneFocus &request) {
    requireRole(requester, ClientRole::control);
    const auto *pane = model_.panes.find(request.pane_id);
    if (pane == nullptr || pane->generation != request.pane_generation) {
      throw RequestError{FailureCode::pane_not_found, "Pane does not exist or its generation is stale"};
    }

    if (pane->exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (requester.pending_focus) {
      throw RequestError{FailureCode::invalid_request, "A pane focus request is already pending"};
    }

    auto *target = focusOrigin(pane->id);
    if (target == nullptr) {
      throw RequestError{FailureCode::invalid_request, "No interactive client originated input for this pane"};
    }

    target->connection.send(PaneFocusCommand{
        .requester = route(requester),
        .request_id = request.request_id,
        .pane_id = pane->id,
        .pane_generation = pane->generation,
        .direction = request.direction,
    });
    requester.pending_focus = PendingPaneFocus{target->id, request.request_id, pane->id, pane->generation};
  }

  void completeFocus(ClientSession<Memory> &sender, const CompletePaneFocus &completion) {
    requireRole(sender, ClientRole::interactive);
    auto *requester = resolve(completion.requester);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_focus) {
      return;
    }

    const auto &pending = *requester->pending_focus;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.pane_id != completion.pane_id || pending.pane_generation != completion.pane_generation) {
      return;
    }

    requester->connection.send(PaneFocusResult{.request_id = completion.request_id,
                                               .outcome = completion.outcome,
                                               .focused_pane_id = completion.focused_pane_id});
    requester->pending_focus.reset();
    requester->connection.closing = true;
  }

  void notify(ClientSession<Memory> &requester, const ShowNotification &request) {
    requester.connection.sendConfirmation(NotificationShown{.request_id = request.request_id}, [&](NotificationShown &confirmation) {
      confirmation.delivered_clients = publish(request.notification);
    });
  }

  std::uint8_t publish(const NotificationBody &body) {
    std::uint8_t delivered = 0;
    Notification notification;
    static_cast<NotificationBody &>(notification) = body;

    for (auto *client : model_.clients.items()) {
      if (client == nullptr || client->connection.closing || client->role != ClientRole::interactive) {
        continue;
      }

      try {
        delivered += client->connection.trySend(notification);
      } catch (const std::bad_alloc &) {
      }
    }

    return delivered;
  }

  void abandon(std::uint64_t departed) noexcept {
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || client->id == departed) {
        continue;
      }

      if (client->pending_command && client->pending_command->target == departed) {
        failAbandoned(*client, client->pending_command->request_id);
        client->pending_command.reset();
      }

      if (client->pending_focus && client->pending_focus->target == departed) {
        failAbandoned(*client, client->pending_focus->request_id);
        client->pending_focus.reset();
        client->connection.closing = true;
      }
    }
  }

private:
  static void requireRole(const ClientSession<Memory> &client, ClientRole expected) {
    if (client.role != expected) {
      throw RequestError{FailureCode::invalid_request, "Invalid client role"};
    }
  }

  static bool routable(const ClientSession<Memory> *client) noexcept {
    return client != nullptr && !client->connection.closing && client->role == ClientRole::interactive && client->identity != 0;
  }

  ClientSession<Memory> *resolve(ClientRoute target) const noexcept {
    auto *client = model_.clients.find(target.id);
    return client != nullptr && client->generation == target.generation ? client : nullptr;
  }

  ClientRoute route(const ClientSession<Memory> &client) const noexcept {
    return ClientRoute{client.id, client.generation};
  }

  ClientSession<Memory> *focusOrigin(std::uint64_t pane_id) const noexcept {
    ClientSession<Memory> *selected = nullptr;
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || client->connection.closing || client->role != ClientRole::interactive || client->last_input_pane != pane_id || client->attachment(pane_id) == nullptr || client->last_input_sequence == 0) {
        continue;
      }

      if (selected == nullptr || client->last_input_sequence > selected->last_input_sequence) {
        selected = client;
      }
    }

    return selected;
  }

  static void failAbandoned(ClientSession<Memory> &client, std::uint64_t request_id) noexcept {
    try {
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::invalid_request,
                                           .message = "Target client disconnected before confirming the operation"});
    } catch (...) {
      client.connection.closeImmediately();
    }
  }

  RuntimeModel<Memory> &model_;
};

}
