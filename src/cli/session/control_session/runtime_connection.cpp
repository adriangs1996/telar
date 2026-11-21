module telar.cli.session.control_session;

import std;
import telar.sys.posix;
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

  RuntimeConnection::RuntimeConnection(const char* path)
      : client_(connect(path)) {
    try {
      const auto peer = peerCredentials(client_.descriptor());
      if (!peer || peer->user != ::geteuid()) {
        throw SystemError{"Runtime socket belongs to another user", EACCES};
      }

      client_.handshake();
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

}
