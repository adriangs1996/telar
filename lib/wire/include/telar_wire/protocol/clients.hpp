#pragma once

#include "../serializers/telar_messages.hpp"

namespace telar {

  struct ShowNotification {
    std::uint64_t request_id{};
    NotificationBody notification{};
  };

  template <>
  struct MessageSchema<ShowNotification>
      : Schema<
            Direction::client,
            ClientTag::show_notification,
            Field<&ShowNotification::request_id, NonzeroU64, "request_id">,
            Field<&ShowNotification::notification, ValueCodec<NotificationBody>, "notification">> {
  };

  struct QueryClients {
    std::uint64_t request_id{};
  };

  template <>
  struct MessageSchema<QueryClients>
      : Schema<Direction::client, ClientTag::query_clients, Field<&QueryClients::request_id, NonzeroU64, "request_id">> {};

  struct DetachClient {
    std::uint64_t request_id{};
    std::uint64_t client_id{};
    std::uint64_t client_generation{};
  };

  template <>
  struct MessageSchema<DetachClient>
      : Schema<Direction::client, ClientTag::detach_client, Field<&DetachClient::request_id, NonzeroU64, "request_id">, Field<&DetachClient::client_id, NonzeroU64, "client_id">, Field<&DetachClient::client_generation, NonzeroU64, "client_generation">> {};

  struct RequestClientCommand : ClientCommand {};

  template <>
  struct MessageSchema<RequestClientCommand> : MessageLayout<Direction::client, ClientTag::request_client_command, BodySchema<ClientCommand>> {};

  struct CompleteClientCommand : ClientCommand {};

  template <>
  struct MessageSchema<CompleteClientCommand> : MessageLayout<Direction::client, ClientTag::complete_client_command, BodySchema<ClientCommand>> {};

  struct Notification : NotificationBody {};

  template <>
  struct MessageSchema<Notification>
      : MessageLayout<Direction::server, ServerTag::notification, BodySchema<NotificationBody>> {};

  struct NotificationShown {
    std::uint64_t request_id{};
    std::uint8_t delivered_clients{};
  };

  template <>
  struct MessageSchema<NotificationShown>
      : Schema<Direction::server, ServerTag::notification_shown, Field<&NotificationShown::request_id, NonzeroU64, "request_id">, Field<&NotificationShown::delivered_clients, u8, "delivered_clients">> {};

  struct ClientList {
    std::uint64_t request_id{};
    std::span<const ClientDescriptor> entries;

    void validate() const;
  };

  template <>
  struct MessageSchema<ClientList>
      : Schema<
            Direction::server,
            ServerTag::client_list,
            Field<&ClientList::request_id, NonzeroU64, "request_id">,
            SpanCountField<&ClientList::entries, u8, ValueCodec<ClientDescriptor>, 32, "count", 0>,
            SpanItemsField<&ClientList::entries, ValueCodec<ClientDescriptor>, "entries">> {};

  template <>
  struct MessageSchema<ClientCommand>
      : MessageLayout<Direction::server, ServerTag::client_command, BodySchema<ClientCommand>> {};

  struct ClientCommandResult : ClientCommand {};

  template <>
  struct MessageSchema<ClientCommandResult> : MessageLayout<Direction::server, ServerTag::client_command_result, BodySchema<ClientCommand>> {};

} // namespace telar
