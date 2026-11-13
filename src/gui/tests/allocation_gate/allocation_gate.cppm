module;
#include <cstddef>

export module telar.gui.tests.allocation_gate;

import std;
export import telar.gui.core.primitives;

export {
namespace telar::gui::test {

template <Allocator Memory>
class AllocationGate {
public:
  explicit AllocationGate(Memory &memory)
      : memory_(memory) {}

  void permit(std::optional<std::size_t> count) noexcept {
    remaining_ = count;
  }

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (remaining_) {
      if (*remaining_ == 0) {
        return nullptr;
      }

      --*remaining_;
    }

    return memory_.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    memory_.deallocate(pointer, size, alignment);
  }

private:
  Memory &memory_;
  std::optional<std::size_t> remaining_;
};

}
}
