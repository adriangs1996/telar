module;

module telar.runtime.runtime.client_control;

import telar.runtime.transport.connection;
import telar.base.ds;

namespace telar::runtime {

  void ClientControl::list(ClientStore& clients, std::uint64_t requester_id, const QueryClients& request) {
    ds::Array<ClientDescriptor, client_capacity> entries;
    std::size_t count = 0;

    for (const auto* client : clients.items()) {
      if (!routable(client)) {
        continue;
      }

      entries.atMut(count++) = ClientDescriptor{
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

  void ClientControl::detach(ClientStore& clients, std::uint64_t requester_id, const DetachClient& request) {
    auto& requester = requireClient(clients, requester_id);

    requireRole(requester, ClientRole::control);
    const ClientRoute route{.id = request.client_id, .generation = request.client_generation};
    if (const auto* target = resolve(clients, route); !routable(target) || target == &requester) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    requester.connection.send(RequestCompleted{.request_id = request.request_id});
    // Found again: answering the requester borrowed the store both clients lie in.
    resolve(clients, route)->connection.closing = true;
  }

  void ClientControl::requestCommand(ClientStore& clients, std::uint64_t requester_id, const RequestClientCommand& request) {
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

    requester.pending_command = PendingClientCommand{.target = target->id, .request_id = request.request_id, .action = request.action, .target_id = request.target_id};
  }

  void ClientControl::completeCommand(ClientStore& clients, std::uint64_t sender_id, const CompleteClientCommand& completion) {
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

  void ClientControl::requestFocus(const PaneStore& panes, ClientStore& clients, std::uint64_t requester_id, const RequestPaneFocus& request) {
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

    requester.pending_focus = PendingPaneFocus{.target = target->id, .request_id = request.request_id, .pane_id = pane->id, .pane_generation = pane->generation};
  }

  void ClientControl::completeFocus(ClientStore& clients, std::uint64_t sender_id, const CompletePaneFocus& completion) {
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

  void ClientControl::notify(ClientStore& clients, std::uint64_t requester_id, const ShowNotification& request) {
    NotificationShown confirmation{.request_id = request.request_id};
    const auto offset = requireClient(clients, requester_id).connection.reserve(confirmation);

    confirmation.delivered_clients = publish(clients, request.notification);
    requireClient(clients, requester_id).connection.complete(offset, confirmation);
  }

  std::uint8_t ClientControl::publish(ClientStore& clients, const NotificationBody& body) {
    Notification notification;

    static_cast<NotificationBody&>(notification) = body;
    return static_cast<std::uint8_t>(broadcast(clients, [](const ClientSession& client) {
      return client.role == ClientRole::interactive;
    },
        notification));
  }

  void ClientControl::abandon(ClientStore& clients, std::uint64_t departed) noexcept {
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

  void ClientControl::requireRole(const ClientSession& client, ClientRole expected) {
    if (client.role != expected) {
      throw RequestError{FailureCode::invalid_request, "Invalid client role"};
    }
  }

  bool ClientControl::routable(const ClientSession* client) noexcept {
    return client != nullptr && !client->connection.closing && client->role == ClientRole::interactive && client->identity != 0;
  }

  ClientSession* ClientControl::resolve(ClientStore& clients, ClientRoute target) noexcept {
    auto* client = clients.find(target.id);

    return client != nullptr && client->generation == target.generation ? client : nullptr;
  }

  ClientRoute ClientControl::route(const ClientSession& client) noexcept {
    return ClientRoute{.id = client.id, .generation = client.generation};
  }

  ClientSession* ClientControl::focusOrigin(ClientStore& clients, std::uint64_t pane_id) noexcept {
    ClientSession* selected = nullptr;

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

  void ClientControl::failAbandoned(ClientSession& client, std::uint64_t request_id) noexcept {
    try {
      client.connection.send(RequestFailed{.request_id = request_id, .code = FailureCode::invalid_request, .message = "Target client disconnected before confirming the operation"});
    } catch (...) {
      client.connection.closeImmediately();
    }
  }

  RuntimeClipboardReader::Result RuntimeClipboardReader::observe(const Request&) noexcept {
    return clipboard::read(runtime_clipboard_max_bytes);
  }

  void RuntimeClipboardReader::stop() noexcept {}

}
