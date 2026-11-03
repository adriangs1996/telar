#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include "telar_platform/error.hpp"

namespace telar::runtime::cli {

class RuntimeConnection {
public:
  explicit RuntimeConnection(const char *path, bool negotiate = true);
  ~RuntimeConnection();
  RuntimeConnection(const RuntimeConnection &) = delete;
  RuntimeConnection &operator=(const RuntimeConnection &) = delete;

  void requestStop();
  [[noreturn]] void bridge();

  template <typename Message>
  void send(const Message &message, std::span<Byte> buffer) {
    client_.send(message, buffer);
  }

  std::span<const Byte> receive(std::span<Byte> buffer) {
    return client_.receiveFrame(buffer);
  }

  void receiveTimeout(unsigned seconds) {
    const timeval timeout{.tv_sec = static_cast<time_t>(seconds), .tv_usec = 0};
    if (::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
      throw SystemError{"Set runtime reply timeout"};
    }
  }

private:
  static Client connect(const char *path);
  Client client_;
};

}
