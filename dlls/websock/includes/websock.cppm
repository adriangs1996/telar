module;

#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/socket.h>
#include <thread>

export module telar.websock;

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
      std::string_view _binding_address;
      uint16_t _binding_port = 0;
      int accepting_socket_fd_ = -1;

    public:
      Server(IAllocator &allocator)
          : _allocator(allocator) {};

      void serve(ServerOptions options) {
        _binding_address = options.bind_address;
        _binding_port = options.bind_port;

        prepareSocket();

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
      void prepareSocket() {
        constexpr int max_queue_accepting_backlog = 128;
        accepting_socket_fd_ = socket(AF_INET, SOCK_STREAM, sock_stream_proto);
        sockaddr_in server_address = {};

        if (accepting_socket_fd_ < 0) {
          throw std::logic_error("Error creating socket");
        }

        server_address.sin_addr.s_addr = parseBindAddressToInteger();
        server_address.sin_port = htons(_binding_port);
        server_address.sin_family = AF_INET;

        if (bind(accepting_socket_fd_, reinterpret_cast<struct sockaddr *>(&server_address), sizeof(server_address)) < 0) {
          throw std::logic_error("Error binding socket");
        };

        if (listen(accepting_socket_fd_, max_queue_accepting_backlog) < 0) {
          throw std::logic_error("Error listening");
        }
      }

      [[nodiscard]] uint32_t bitsForBytes(uint8_t bytes) const {
        constexpr uint8_t bits_in_bytes = 8;
        return bits_in_bytes * bytes;
      }

      uint32_t parseBindAddressToInteger() {
        auto string_repr = _binding_address;
        std::size_t pos = 0;
        uint8_t index = 0;
        uint32_t result = 0;

        if (_binding_address == "0.0.0.0") {
          return INADDR_ANY;
        }

        while ((pos = string_repr.find('.')) != std::string_view::npos) {
          auto byte_string = string_repr.substr(0, pos);
          string_repr.remove_prefix(byte_string.length());

          int parsing_result = std::stoi(byte_string.data());
          if (parsing_result >= 0 && parsing_result < 256) {
            result |= parsing_result << index * bitsForBytes(index);
          }
          index++;
        }

        return result;
      }
    };
  }
}
