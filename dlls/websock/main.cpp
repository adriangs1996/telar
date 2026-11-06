#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#if (!defined(TELAR_WEBSOCK_HPP))
#include "telar_base/memory/allocator.hpp"
#endif



import telar.websock;

template <typename Memory>
concept ServerMemory = requires { typename telar::websock::Server<Memory>; };

static_assert(ServerMemory<telar::SystemAllocator>);
static_assert(ServerMemory<telar::BudgetAllocator<telar::SystemAllocator>>);
static_assert(!ServerMemory<int>);

auto main() -> int {
  return 0;
}
