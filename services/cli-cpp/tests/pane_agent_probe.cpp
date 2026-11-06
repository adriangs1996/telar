#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <span>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include "telar_client/codecs/telar_codec.hpp"
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_base/memory/allocator.hpp"
#include <optional>
#include <stdexcept>
#include "telar_platform/random_bytes.hpp"
#include <algorithm>
#include <limits>
#include <string_view>
#include <type_traits>
#include <charconv>
#include <string>
#include <cstdio>
#include <concepts>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
#include <chrono>



import telar.cli.project_setup;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli;

int main(int argc, char **argv) {
  try {
    if (argc == 1) {
      constexpr std::string_view banner = "\x1b[2J\x1b[HClaude Code\n❯ ";
      if (::write(STDOUT_FILENO, banner.data(), banner.size()) != static_cast<ssize_t>(banner.size())) {
        return 1;
      }

      std::array<char, 4096> input;
      for (;;) {
        const auto count = ::read(STDIN_FILENO, input.data(), input.size());
        if (count <= 0) {
          return 0;
        }

        if (::write(STDOUT_FILENO, input.data(), static_cast<std::size_t>(count)) != count) {
          return 1;
        }
      }
    }

    if (argc < 3) {
      return 2;
    }

    SystemAllocator memory;
    ControlSession session{memory, argv[2]};
    session.receiveTimeout(10);
    const std::string_view action{argv[1]};
    if (action == "seed" && argc == 5) {
      const std::array<std::string_view, 1> command{argv[4]};
      const auto reply = session.exchange<PaneOpened>(CreateWorkspace{.size = {80, 24, 8, 16}, .name = "Fixture", .launch = {.cwd = argv[3], .arguments = command}});
      std::printf("{\"workspace_id\":%llu,\"tab_id\":%llu,\"pane_id\":%llu,\"pane_generation\":%llu}\n", static_cast<unsigned long long>(reply.location.workspace.id), static_cast<unsigned long long>(reply.location.tab_id), static_cast<unsigned long long>(reply.pane_id), static_cast<unsigned long long>(reply.pane_generation));
    } else if (action == "clients") {
      const auto reply = session.exchange<ClientList>(QueryClients{});
      for (const auto &client : reply.entries) {
        std::printf("%llu\n", static_cast<unsigned long long>(client.id));
      }
    } else {
      return 2;
    }

    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "pane-agent-probe: %s\n", error.what());
    return 1;
  }
}
