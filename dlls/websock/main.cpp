#include <websock/websock.hpp>

template <typename Memory>
concept ServerMemory = requires { typename telar::websock::Server<Memory>; };

static_assert(ServerMemory<telar::SystemAllocator>);
static_assert(ServerMemory<telar::BudgetAllocator<telar::SystemAllocator>>);
static_assert(!ServerMemory<int>);

auto main() -> int {
  return 0;
}
