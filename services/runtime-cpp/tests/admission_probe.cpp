#include <csignal>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <cerrno>
#include <cstdio>
#include <sys/time.h>
#include <unistd.h>

import std;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

using namespace telar;
using namespace telar::runtime;

class NegotiatingPeer {
public:
  explicit NegotiatingPeer(const char *path)
      : descriptor_(::socket(AF_UNIX, SOCK_STREAM, 0)) {
    check(static_cast<bool>(descriptor_));
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    check(std::strlen(path) < sizeof(address.sun_path));
    std::strcpy(address.sun_path, path);
    check(::connect(descriptor_.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
    const timeval timeout{.tv_sec = 5, .tv_usec = 0};
    check(::setsockopt(descriptor_.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
  }

  void hello(bool incompatible = false, bool malformed = false) {
    ClientHello message;
    if (incompatible) {
      message.schema.front() ^= 1;
    }
    auto payload = HandshakeCodec::encode(message);
    if (malformed) {
      payload.front() ^= 1;
    }
    sendPayload(payload);
  }

  void accept() {
    const auto payload = receive();
    check(HandshakeCodec::decode<ServerAccept>(payload).schema == handshake::schema_id);
  }

  void reject(HandshakeRejectReason reason) {
    const auto payload = receive();
    const auto reply = HandshakeCodec::decode<ServerReject>(payload);
    check(reply.reason == reason && reply.expected_schema == handshake::schema_id);
  }

  void activate(std::uint64_t identity) {
    std::array<Byte, 256> storage;
    sendPayload(Codec::encode(RequestRuntimeState{.client_identity = identity, .interactive = true}, storage));
    for (;;) {
      const auto payload = receive();
      if (payload.front() == static_cast<Byte>(ServerTag::workspace_list)) {
        return;
      }
    }
  }

  void expectSilent() {
    pollfd pending{.fd = descriptor_.get(), .events = POLLIN, .revents = 0};
    check(::poll(&pending, 1, 30) == 0);
  }

  void expectClosed() {
    Byte byte = 0;
    const auto result = ::read(descriptor_.get(), &byte, 1);
    check(result == 0 || (result < 0 && errno == ECONNRESET));
  }

private:
  void sendPayload(std::span<const Byte> payload) {
    std::array<Byte, frame_prefix_size> prefix;
    std::span<Byte> output = prefix;
    u32::encode(payload.size(), output);
    writeAll(prefix);
    writeAll(payload);
  }

  void writeAll(std::span<const Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      check(count > 0);
      bytes = bytes.subspan(count);
    }
  }

  void readAll(std::span<Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::read(descriptor_.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      check(count > 0);
      bytes = bytes.subspan(count);
    }
  }

  std::vector<Byte> receive() {
    std::array<Byte, frame_prefix_size> prefix;
    readAll(prefix);
    std::span<const Byte> input = prefix;
    const auto length = u32::decode(input);
    check(length != 0 && length <= max_payload_size);
    std::vector<Byte> payload(length);
    readAll(payload);
    return payload;
  }

  FileDescriptor descriptor_;
};

static void checkIdentities(const char *socket, unsigned iterations, std::ostream &dump) {
  ProtocolPeer control{socket};
  NegotiatingPeer original{socket};
  original.hello();
  original.accept();
  original.activate(101);
  const auto initial = control.exchange<ClientList>(QueryClients{.request_id = 1});
  check(initial.entries.size() == 1 && initial.entries[0].identity == 101);
  const auto first_id = initial.entries[0].id;
  const auto first_generation = initial.entries[0].generation;
  NegotiatingPeer incomplete{socket};
  for (unsigned index = 0; index < iterations; ++index) {
    NegotiatingPeer rejected{socket};
    rejected.hello(true);
    rejected.reject(HandshakeRejectReason::incompatible_schema);
    rejected.expectClosed();
    NegotiatingPeer malformed{socket};
    malformed.hello(false, true);
    malformed.expectClosed();
  }

  NegotiatingPeer delayed{socket};
  NegotiatingPeer immediate{socket};
  immediate.hello();
  immediate.accept();
  immediate.activate(202);
  delayed.hello();
  delayed.activate(201);
  const auto clients = control.exchange<ClientList>(QueryClients{.request_id = 2});
  check(clients.entries.size() == 3);
  for (const auto &entry : clients.entries) {
    const auto offset = entry.identity == 101 ? 0 : entry.identity == 202 ? 1
                                                                          : 2;
    check(entry.id == first_id + offset && entry.generation == first_generation + offset);
  }
  control.record(dump, clients);
}

static void checkPendingCapacity(const char *socket, std::ostream &dump) {
  ProtocolPeer control{socket};
  std::vector<std::unique_ptr<NegotiatingPeer>> pending;
  for (unsigned index = 0; index < 16; ++index) {
    pending.push_back(std::make_unique<NegotiatingPeer>(socket));
  }
  NegotiatingPeer excess{socket};
  excess.expectClosed();
  const auto limits = control.exchange<LimitList>(QueryLimits{.request_id = 1});
  const auto entry = std::ranges::find(limits.entries, std::string_view{"clients.max_pending_handshakes"}, [](const auto &entry) { return entry.reach.name; });
  check(entry != limits.entries.end() && entry->reach.value == 16 && entry->hits == 1);
  for (const auto &peer : pending) {
    peer->expectClosed();
  }
  NegotiatingPeer replacement{socket};
  replacement.hello();
  replacement.accept();
  replacement.activate(303);
  const auto clients = control.exchange<ClientList>(QueryClients{.request_id = 2});
  check(clients.entries.size() == 1 && clients.entries[0].id == 2 && clients.entries[0].generation == 2);
  control.record(dump, clients);
}

static void checkClientCapacity(const char *socket, std::ostream &dump) {
  ProtocolPeer control{socket};
  std::vector<std::unique_ptr<NegotiatingPeer>> clients;
  for (unsigned index = 0; index < 31; ++index) {
    auto client = std::make_unique<NegotiatingPeer>(socket);
    client->hello();
    client->accept();
    clients.push_back(std::move(client));
  }
  NegotiatingPeer excess{socket};
  excess.expectSilent();
  excess.hello(true);
  excess.reject(HandshakeRejectReason::client_limit_reached);
  excess.expectClosed();
  NegotiatingPeer malformed{socket};
  malformed.hello(false, true);
  malformed.expectClosed();
  const auto limits = control.exchange<LimitList>(QueryLimits{.request_id = 1});
  const auto entry = std::ranges::find(limits.entries, std::string_view{"clients.max_clients"}, [](const auto &entry) { return entry.reach.name; });
  check(entry != limits.entries.end() && entry->reach.value == 32 && entry->reach.requested == 33 && entry->hits == 2);
  auto recorded = *entry;
  recorded.last_ms = 0;
  control.record(dump, LimitList{.request_id = 1, .entries = std::span{&recorded, 1}});
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    ::signal(SIGPIPE, SIG_IGN);
    const auto started = std::chrono::steady_clock::now();
    std::ofstream dump{argv[4], std::ios::binary};
    const std::string_view workload{argv[2]};
    if (workload == "admission-identities") {
      checkIdentities(argv[1], std::stoul(argv[3]), dump);
    } else if (workload == "admission-pending") {
      checkPendingCapacity(argv[1], dump);
    } else if (workload == "admission-capacity") {
      checkClientCapacity(argv[1], dump);
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", elapsed);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "admission-probe: %s\n", error.what());
    return 1;
  }
}
