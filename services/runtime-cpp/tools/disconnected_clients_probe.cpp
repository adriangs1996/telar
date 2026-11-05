#include "tests/protocol_peer.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <sys/un.h>
#include <thread>

using namespace telar;
using Clock = std::chrono::steady_clock;

int main(int argc, char **argv) {
  try {
    if (argc != 4) {
      throw std::runtime_error{"Expected socket, output directory and rounds"};
    }
    const auto directory = std::filesystem::path{argv[2]};
    const auto rounds = std::stoul(argv[3]);
    std::optional<ProtocolPeer> connection;
    const auto deadline = Clock::now() + std::chrono::seconds{10};
    while (!connection) {
      try {
        connection.emplace(argv[1]);
      } catch (const SocketError &error) {
        if (std::string_view{error.what()} != "Error connecting" || Clock::now() >= deadline) {
          throw;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
      }
    }
    auto &peer = *connection;
    peer.send(RequestRuntimeState{.client_identity = 854, .interactive = true});
    peer.receive<WorkspaceList>();
    pid_t pid = 0;
    socklen_t size = sizeof(pid);
    if (::getsockopt(peer.descriptor(), SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 || size != sizeof(pid) || pid <= 0) {
      throw std::runtime_error{"Cannot identify the measured peer"};
    }
    {
      std::ofstream ready{directory / "ready"};
      ready << pid << '\n';
    }
    for (std::size_t index = 0; index < rounds; ++index) {
      const auto trigger = directory / ("release-" + std::to_string(index));
      const auto timeout = Clock::now() + std::chrono::seconds{15};
      while (!std::filesystem::exists(trigger)) {
        if (Clock::now() >= timeout) {
          throw std::runtime_error{"Probe release timed out"};
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{5});
      }
      for (std::uint64_t request = 0; request < 2; ++request) {
        peer.exchange<ClientList>(QueryClients{.request_id = index * 2 + request + 1});
      }
      std::ofstream done{directory / ("done-" + std::to_string(index))};
      done << "healthy\n";
    }
    std::cout << "{\"healthy_rounds\":" << rounds << "}\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
