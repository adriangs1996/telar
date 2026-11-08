#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory;
import telar.websock;

static constexpr std::uint16_t port = 65432;

template <typename Memory>
concept ServerMemory = requires { typename telar::websock::Server<Memory>; };

static_assert(ServerMemory<telar::SystemAllocator>);
static_assert(ServerMemory<telar::BudgetAllocator<telar::SystemAllocator>>);
static_assert(!ServerMemory<int>);

auto main() -> int {

  // Always remember that variables are destroyed in reverse order, so allocator must be top of the list
  telar::SystemAllocator allocator = {};
  telar::websock::Server server = {allocator};

  try {
    const auto thread = std::jthread([&] {
      server.serve(telar::websock::ServerOptions{
          .bind_address = "0.0.0.0",
          .bind_port = port,
      });
    });

    while (!server.servingTraffic()) {
      std::println("Waiting for server to accept traffic");
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    std::println("Server is providing traffic");
  } catch (...) {
    return -1;
  }

  return 0;
}
