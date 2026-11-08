module;
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

export module telar.websock;

export import telar.websock.handshake;

import std;

import telar.base.diagnostics;
import telar.base.memory;

// Interface: includes/websock/websock.cppm
export {
  constexpr int sock_stream_proto = 0;

  namespace telar::websock {

    struct ServerOptions final {
      std::string_view bind_address;
      uint16_t bind_port;
    };

    template <Allocator IAllocator>
    class Server final {
      IAllocator &_allocator;
      bool _serving = false;
      int accepting_socket_fd_ = -1;

    public:
      Server(IAllocator &allocator)
          : _allocator(allocator) {};

      void serve(ServerOptions options) {
        prepareSocket(options);

        std::this_thread::sleep_for(std::chrono::seconds(5));
        _serving = true;
      }

      bool servingTraffic() {
        return _serving;
      }

      // Ignore this for now;
      ~Server() = default;
      Server(const Server &) = delete;
      Server(Server &&) = delete;
      Server &operator=(Server &&) = delete;
      Server &operator=(const Server &) = delete;

    private:
      void prepareSocket(ServerOptions options) {
        constexpr int max_queue_accepting_backlog = 128;
        sockaddr_in server_address = {};
        // Parsed before the socket exists, so an invalid address leaks no descriptor.
        server_address.sin_addr = parseBindAddress(options.bind_address);
        server_address.sin_port = htons(options.bind_port);
        server_address.sin_family = AF_INET;

        accepting_socket_fd_ = socket(AF_INET, SOCK_STREAM, sock_stream_proto);
        if (accepting_socket_fd_ < 0) {
          throw std::logic_error("Error creating socket");
        }

        if (bind(accepting_socket_fd_, reinterpret_cast<struct sockaddr *>(&server_address), sizeof(server_address)) < 0) {
          throw std::logic_error("Error binding socket");
        };

        if (listen(accepting_socket_fd_, max_queue_accepting_backlog) < 0) {
          throw std::logic_error("Error listening");
        }
      }

      // A dotted-quad IPv4 address in network byte order; "0.0.0.0" is INADDR_ANY.
      static in_addr parseBindAddress(std::string_view address) {
        // inet_pton reads up to a NUL, which a string_view need not end in, and
        // would stop at one inside it, accepting only the text before it.
        std::array<char, INET_ADDRSTRLEN> terminated{};
        if (address.size() >= terminated.size() || address.contains('\0')) {
          throw std::invalid_argument("Invalid IPv4 bind address");
        }
        std::ranges::copy(address, terminated.begin());

        in_addr parsed = {};
        if (inet_pton(AF_INET, terminated.data(), &parsed) != 1) {
          throw std::invalid_argument("Invalid IPv4 bind address");
        }
        return parsed;
      }
    };
  }
}
