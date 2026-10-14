#include <cstdint>
#include <cstdio>
#include <exception>
#include <unistd.h>
#include <vector>

#include "telar_client/telar.hpp"

int main(int argc, const char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: %s SOCKET_PATH\n", argv[0]);
    return 1;
  }

  try {
    std::vector<telar::Byte> receive_buffer(telar::max_payload_size);
    auto client = telar::Client::init(argv[1]);

    try {
      client.handshake();

      const telar::RequestRuntimeState request{
          .client_identity = static_cast<std::uint64_t>(getpid()),
          .interactive = false,
      };

#ifdef TELAR_DEBUG
      std::printf("Request: %s\n", telar::MessageSchema<telar::RequestRuntimeState>::name);
      telar::Codec::pretty_print(request, stdout);
      std::fflush(stdout);
#endif

      client.send(request);

      // An observer receives other runtime events before or between metric samples.
      while (true) {
        const auto payload = client.receiveFrame(receive_buffer);
        const auto tag = static_cast<telar::ServerTag>(payload.front());
        switch (tag) {
        case telar::ServerTag::runtime_stopping:
          throw telar::SocketError{"Runtime stopped before sending metrics"};
        case telar::ServerTag::request_failed:
          throw telar::SocketError{"Runtime rejected the state subscription"};
        case telar::ServerTag::resync_required:
          throw telar::SocketError{"Runtime requires a new state subscription"};
        case telar::ServerTag::system_metrics:
          break;
        default:
          continue;
        }

        const auto response = telar::Codec::decode<telar::SystemMetrics>(payload);

#ifdef TELAR_DEBUG
        std::printf("\nResponse: %s\n", telar::MessageSchema<telar::SystemMetrics>::name);
        telar::Codec::pretty_print(response, stdout);
#else
        std::printf("Runtime metrics received (revision %llu)\n",
                    static_cast<unsigned long long>(response.revision));
#endif

        break;
      }
    } catch (...) {
      client.deinit();
      throw;
    }

    client.deinit();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }

  return 0;
}
