#include "runtime_connection.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/peer_credentials.hpp"
#include <csignal>
#include <pthread.h>

namespace telar::runtime::cli {

Client RuntimeConnection::connect(const char *path) {
  try {
    return Client::init(path);
  } catch (const SocketError &error) {
    throw SystemError{error.what()};
  }
}

RuntimeConnection::RuntimeConnection(const char *path, bool negotiate)
    : client_(connect(path)) {
  try {
    const auto peer = peerCredentials(client_.descriptor());
    if (!peer || peer->user != ::geteuid()) {
      throw SystemError{"Runtime socket belongs to another user", EACCES};
    }

    setCloseOnExec(client_.descriptor());
    if (negotiate) {
      client_.handshake();
    }
  } catch (...) {
    client_.deinit();
    throw;
  }
}

RuntimeConnection::~RuntimeConnection() {
  client_.deinit();
}

void RuntimeConnection::requestStop() {
  const timeval timeout{.tv_sec = 10, .tv_usec = 0};
  if (::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
    throw SystemError{"Set shutdown reply timeout"};
  }

  client_.send(RuntimeStop{});
  std::array<Byte, 2048> incoming;
  const auto response = client_.receiveFrame(incoming);
  std::array<Byte, 2048> decoded;
  DecodeStorage storage{decoded};
  if (!response.empty() && response.front() == static_cast<Byte>(ServerTag::request_failed)) {
    const auto failure = Codec::decode<RequestFailed>(response, storage);
    throw std::runtime_error{std::string{failure.message}};
  }

  Codec::decode<RuntimeStopping>(response, storage);
}

namespace {

struct RelayDirection {
  int source;
  int destination;
};

[[noreturn]] void relay(RelayDirection direction) noexcept {
  std::array<Byte, 64 * 1024> buffer;
  for (;;) {
    const auto count = ::read(direction.source, buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      ::_exit(0);
    }

    auto pending = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));
    while (!pending.empty()) {
      const auto written = ::write(direction.destination, pending.data(), pending.size());
      if (written < 0 && errno == EINTR) {
        continue;
      }
      if (written <= 0) {
        ::_exit(0);
      }

      pending = pending.subspan(static_cast<std::size_t>(written));
    }
  }
}

void *relayInput(void *context) noexcept {
  relay(*static_cast<RelayDirection *>(context));
}

}

[[noreturn]] void RuntimeConnection::bridge() {
  ::signal(SIGPIPE, SIG_IGN);
  RelayDirection upstream{STDIN_FILENO, client_.descriptor()};
  pthread_t thread;
  const auto result = ::pthread_create(&thread, nullptr, &relayInput, &upstream);
  if (result != 0) {
    throw SystemError{"Start runtime bridge", result};
  }

  ::pthread_detach(thread);
  relay({client_.descriptor(), STDOUT_FILENO});
}

}
