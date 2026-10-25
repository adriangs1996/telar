#include "check.hpp"
#include "protocol_peer.hpp"
#include <chrono>

using namespace telar;

static void exercise(const char *socket, const char *dump_path) {
  ProtocolPeer observer{socket};
  observer.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  observer.receive<WorkspaceList>();
  ProtocolPeer requester{socket};
  const std::string text(512, 'n');
  bool dropped = false;
  std::size_t accepted = 0;
  for (unsigned index = 0; index < 4096; ++index) {
    const auto reply = requester.exchange<NotificationShown>(ShowNotification{
        .request_id = index + 1,
        .notification = NotificationBody{.title = "Capacity", .message = text},
    });
    check(reply.delivered_clients <= 1);
    accepted += reply.delivered_clients;
    dropped |= reply.delivered_clients == 0;
  }

  const auto clients = requester.exchange<ClientList>(QueryClients{.request_id = 4097});
  check(clients.entries.size() == 1);
  const auto target = clients.entries.front();
  RequestClientCommand command;
  command.request_id = 4098;
  command.route = ClientRoute{target.id, target.generation};
  command.action = ClientAction::sidebar_resize;
  command.value = 40;
  requester.send(command);
  const auto failure = requester.receive<RequestFailed>();
  check(failure.code == FailureCode::invalid_request && failure.message == "ResponseQueueFull");
  check(requester.exchange<ClientList>(QueryClients{.request_id = 4099}).entries.size() == 1);
  std::ofstream output{dump_path, std::ios::binary};
  output << "notification-dropped:" << dropped << '\n';
  output << "saturated-command-refused:1\n";
  output << "observer-connected:" << (clients.entries.size() == 1) << '\n';
  output << "notifications-accepted:" << (accepted != 0) << '\n';
  for (std::size_t index = 0; index < accepted; ++index) {
    check(observer.receive<Notification>().message == text);
  }
  check(observer.exchange<ClientList>(QueryClients{.request_id = 4100}).entries.size() == 1);
  output << "observer-recovered:1\n";
  check(output.good());
}

static void mandatoryReplies(const char *socket, const char *dump_path) {
  ProtocolPeer observer{socket};
  observer.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  observer.receive<WorkspaceList>();
  ProtocolPeer slow{socket};
  const timeval timeout{.tv_sec = 5, .tv_usec = 0};
  check(::setsockopt(slow.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
  check(::setsockopt(slow.descriptor(), SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0);
  try {
    for (unsigned index = 0; index < 4096; ++index) {
      slow.send(QueryClients{.request_id = index + 1});
    }
  } catch (const SocketError &) {
    check(errno == EPIPE || errno == ECONNRESET);
  }

  std::array<Byte, 4096> bytes;
  for (;;) {
    const auto count = ::recv(slow.descriptor(), bytes.data(), bytes.size(), 0);
    if (count > 0 || (count < 0 && errno == EINTR)) {
      continue;
    }
    check(count == 0 || (count < 0 && errno == ECONNRESET));
    break;
  }
  check(observer.exchange<ClientList>(QueryClients{.request_id = 1}).entries.size() == 1);
  std::ofstream output{dump_path, std::ios::binary};
  output << "mandatory-full-disconnected:1\nhealthy-observer-connected:1\n";
  check(output.good());
}

static void roundtrips(const char *socket, unsigned iterations, const char *dump_path) {
  ProtocolPeer observer{socket};
  observer.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  observer.receive<WorkspaceList>();
  ProtocolPeer requester{socket};
  const std::string text(512, 'n');
  std::ofstream output{dump_path, std::ios::binary};
  for (unsigned index = 0; index < iterations; ++index) {
    const auto reply = requester.exchange<NotificationShown>(ShowNotification{
        .request_id = index + 1,
        .notification = NotificationBody{.title = "Roundtrip", .message = text},
    });
    check(reply.delivered_clients == 1);
    check(observer.receive<Notification>().message == text);
    requester.record(output, reply);
  }
  check(output.good());
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    const auto started = std::chrono::steady_clock::now();
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    if (std::string_view{argv[2]} == "response-queue") {
      exercise(argv[1], argv[4]);
    } else if (std::string_view{argv[2]} == "response-mandatory") {
      mandatoryReplies(argv[1], argv[4]);
    } else if (std::string_view{argv[2]} == "response-roundtrip") {
      roundtrips(argv[1], iterations, argv[4]);
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
