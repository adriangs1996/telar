#include "../pane_agent_control.hpp"
#include <cstdio>

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
