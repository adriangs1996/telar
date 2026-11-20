module telar.cli.session.control_session;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;

import telar.platform.net;
import telar.platform.error;
import telar.wire.vocabulary;
import telar.wire.runtime;
import telar.base.ds;
import telar.base.memory.containers;

namespace telar::runtime::cli {

  Client RuntimeConnection::connect(const char* path) {
    try {
      return Client::init(path);
    } catch (const SocketError& error) {
      throw SystemError{error.what()};
    }
  }

  RuntimeConnection::RuntimeConnection(const char* path, bool negotiate)
      : client_(connect(path)) {
    try {
      const auto peer = peerCredentials(client_.descriptor());
      if (!peer || peer->user != ::geteuid()) {
        throw SystemError{"Runtime socket belongs to another user", EACCES};
      }

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

  auto RuntimeConnection::receive(tbc::val_a<std::span<Byte>> buffer) -> tbc::val_a<std::span<const Byte>> {
    return client_.receiveFrame(buffer);
  }

  namespace {

    // The runtime refused to stop; its own words say why.
    class StopRefused final : public std::exception {
    public:
      explicit StopRefused(std::string_view message) noexcept
          : message_(message) {}

      [[nodiscard]] const char* what() const noexcept override {
        return message_.cStr();
      }

    private:
      static constexpr std::size_t message_capacity = 1023;

      ErrorText<message_capacity> message_;
    };

  }

  void RuntimeConnection::requestStop() {
    const timeval timeout{.tv_sec = 10, .tv_usec = 0};
    if (::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
      throw SystemError{"Set shutdown reply timeout"};
    }

    client_.send(RuntimeStop{});

    // Room for the runtime's stop or its refusal, and for what decoding the refusal borrows.
    constexpr std::size_t reply_bytes = 2048;

    ds::Array<Byte, reply_bytes> incoming{};
    const auto response = client_.receiveFrame(incoming.viewMut());
    ds::Array<Byte, reply_bytes> decoded{};
    DecodeStorage storage{decoded.viewMut()};

    if (!response.empty() && response.front() == static_cast<Byte>(ServerTag::request_failed)) {
      const auto failure = Codec::decode<RequestFailed>(response, storage);

      throw StopRefused{failure.message};
    }

    Codec::decode<RuntimeStopping>(response, storage);
  }

  namespace {

    struct RelayDirection {
      int source;
      int destination;
    };

    [[noreturn]] void relay(RelayDirection direction) noexcept {
      constexpr std::size_t buffer_bytes = std::size_t{64} * 1024;

      ds::Array<Byte, buffer_bytes> buffer{};

      for (;;) {
        const auto count = ::read(direction.source, buffer.dataMut(), buffer.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          ::_exit(0);
        }

        auto pending = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));

        while (!pending.empty()) {
          const auto written = ::write(direction.destination, pending.data(), pending.size());
          if (written < 0 && sys::lastError() == EINTR) {
            continue;
          }

          if (written <= 0) {
            ::_exit(0);
          }

          pending = pending.subspan(static_cast<std::size_t>(written));
        }
      }
    }

    void* relayInput(void* context) noexcept {
      relay(*static_cast<RelayDirection*>(context));
    }

  }

  [[noreturn]] void RuntimeConnection::bridge() {
    static_cast<void>(::signal(SIGPIPE, SIG_IGN));
    RelayDirection upstream{.source = STDIN_FILENO, .destination = client_.descriptor()};
    pthread_t thread{};
    const auto result = ::pthread_create(&thread, nullptr, &relayInput, &upstream);
    if (result != 0) {
      throw SystemError{"Start runtime bridge", result};
    }

    ::pthread_detach(thread);
    relay({.source = client_.descriptor(), .destination = STDOUT_FILENO});
  }

}
