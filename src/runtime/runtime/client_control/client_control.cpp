module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.runtime.client_control;

namespace telar::runtime {

  template <Allocator Memory>
  void ClientControl<Memory>::list(ClientStore<Memory>& clients, std::uint64_t requester_id, const QueryClients& request) {
    std::array<ClientDescriptor, client_capacity> entries;
    std::size_t count = 0;

    for (const auto* client : clients.items()) {
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

    requireClient(clients, requester_id).connection.send(ClientList{.request_id = request.request_id, .entries = std::span{entries}.first(count)});
  }

  template <Allocator Memory>
  void ClientControl<Memory>::detach(ClientStore<Memory>& clients, std::uint64_t requester_id, const DetachClient& request) {
    auto& requester = requireClient(clients, requester_id);

    requireRole(requester, ClientRole::control);
    auto* target = resolve(clients, ClientRoute{request.client_id, request.client_generation});
    if (!routable(target) || target == &requester) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    requester.connection.send(RequestCompleted{.request_id = request.request_id});
    target->connection.closing = true;
  }

  template <Allocator Memory>
  void ClientControl<Memory>::requestCommand(ClientStore<Memory>& clients, std::uint64_t requester_id, const RequestClientCommand& request) {
    auto& requester = requireClient(clients, requester_id);

    requireRole(requester, ClientRole::control);
    if (request.status != ClientCommandStatus::request || requester.pending_command) {
      throw RequestError{FailureCode::invalid_request, "Invalid or already pending client command"};
    }

    auto* target = resolve(clients, request.route);
    if (!routable(target)) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    ClientCommand forwarded = request;

    forwarded.route = route(requester);
    try {
      target->connection.send(forwarded);
    } catch (const ResponseQueueFull&) {
      throw RequestError{FailureCode::invalid_request, "ResponseQueueFull"};
    }

    requester.pending_command = PendingClientCommand{target->id, request.request_id, request.action, request.target_id};
  }

  template <Allocator Memory>
  void ClientControl<Memory>::completeCommand(ClientStore<Memory>& clients, std::uint64_t sender_id, const CompleteClientCommand& completion) {
    const auto& sender = requireClient(clients, sender_id);

    requireRole(sender, ClientRole::interactive);
    auto* requester = resolve(clients, completion.route);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_command) {
      return;
    }

    const auto& pending = *requester->pending_command;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.action != completion.action || pending.target_id != completion.target_id || completion.status == ClientCommandStatus::request) {
      return;
    }

    ClientCommandResult result;

    static_cast<ClientCommand&>(result) = completion;
    result.route = route(sender);
    requester->connection.send(result);
    requester->pending_command.reset();
  }

  template <Allocator Memory>
  void ClientControl<Memory>::requestFocus(const PaneStore<Memory>& panes, ClientStore<Memory>& clients, std::uint64_t requester_id, const RequestPaneFocus& request) {
    auto& requester = requireClient(clients, requester_id);

    requireRole(requester, ClientRole::control);
    const auto* pane = findPane(panes, request.pane_id, request.pane_generation);
    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Pane does not exist or its generation is stale"};
    }

    if (pane->exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (requester.pending_focus) {
      throw RequestError{FailureCode::invalid_request, "A pane focus request is already pending"};
    }

    auto* target = focusOrigin(clients, pane->id);
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

  template <Allocator Memory>
  void ClientControl<Memory>::completeFocus(ClientStore<Memory>& clients, std::uint64_t sender_id, const CompletePaneFocus& completion) {
    const auto& sender = requireClient(clients, sender_id);

    requireRole(sender, ClientRole::interactive);
    auto* requester = resolve(clients, completion.requester);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_focus) {
      return;
    }

    const auto& pending = *requester->pending_focus;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.pane_id != completion.pane_id || pending.pane_generation != completion.pane_generation) {
      return;
    }

    requester->connection.send(PaneFocusResult{.request_id = completion.request_id, .outcome = completion.outcome, .focused_pane_id = completion.focused_pane_id});
    requester->pending_focus.reset();
    requester->connection.closing = true;
  }

  template <Allocator Memory>
  void ClientControl<Memory>::notify(ClientStore<Memory>& clients, std::uint64_t requester_id, const ShowNotification& request) {
    NotificationShown confirmation{.request_id = request.request_id};
    const auto offset = requireClient(clients, requester_id).connection.reserve(confirmation);

    confirmation.delivered_clients = publish(clients, request.notification);
    requireClient(clients, requester_id).connection.complete(offset, confirmation);
  }

  template <Allocator Memory>
  std::uint8_t ClientControl<Memory>::publish(ClientStore<Memory>& clients, const NotificationBody& body) {
    Notification notification;

    static_cast<NotificationBody&>(notification) = body;
    return static_cast<std::uint8_t>(broadcast(clients, [](const ClientSession<Memory>& client) {
      return client.role == ClientRole::interactive;
    },
        notification));
  }

  template <Allocator Memory>
  void ClientControl<Memory>::abandon(ClientStore<Memory>& clients, std::uint64_t departed) noexcept {
    for (auto* client : clients.items()) {
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

  template <Allocator Memory>
  void ClientControl<Memory>::requireRole(const ClientSession<Memory>& client, ClientRole expected) {
    if (client.role != expected) {
      throw RequestError{FailureCode::invalid_request, "Invalid client role"};
    }
  }

  template <Allocator Memory>
  bool ClientControl<Memory>::routable(const ClientSession<Memory>* client) noexcept {
    return client != nullptr && !client->connection.closing && client->role == ClientRole::interactive && client->identity != 0;
  }

  template <Allocator Memory>
  ClientSession<Memory>* ClientControl<Memory>::resolve(ClientStore<Memory>& clients, ClientRoute target) noexcept {
    auto* client = clients.find(target.id);

    return client != nullptr && client->generation == target.generation ? client : nullptr;
  }

  template <Allocator Memory>
  ClientRoute ClientControl<Memory>::route(const ClientSession<Memory>& client) noexcept {
    return ClientRoute{client.id, client.generation};
  }

  template <Allocator Memory>
  ClientSession<Memory>* ClientControl<Memory>::focusOrigin(ClientStore<Memory>& clients, std::uint64_t pane_id) noexcept {
    ClientSession<Memory>* selected = nullptr;

    for (auto* client : clients.items()) {
      if (client == nullptr || client->connection.closing || client->role != ClientRole::interactive || client->last_input_pane != pane_id || client->attachment(pane_id) == nullptr || client->last_input_sequence == 0) {
        continue;
      }

      if (selected == nullptr || client->last_input_sequence > selected->last_input_sequence) {
        selected = client;
      }
    }

    return selected;
  }

  template <Allocator Memory>
  void ClientControl<Memory>::failAbandoned(ClientSession<Memory>& client, std::uint64_t request_id) noexcept {
    try {
      client.connection.send(RequestFailed{.request_id = request_id, .code = FailureCode::invalid_request, .message = "Target client disconnected before confirming the operation"});
    } catch (...) {
      client.connection.closeImmediately();
    }
  }

  template class ClientControl<ConcurrentMemory>;

  RuntimeClipboardReader::Result RuntimeClipboardReader::observe(const Request&) noexcept {
    return clipboard::read(runtime_clipboard_max_bytes);
  }

  void RuntimeClipboardReader::stop() noexcept {}

}
