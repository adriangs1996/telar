module;
#include <cstddef>

export module telar.gui.tests.erasure_allocator;

import std;
export import telar.gui.core.primitives;

export {
namespace telar::gui::test {

struct ErasureAllocator {
  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (fail) {
      return nullptr;
    }

    void *const result = upstream_.allocate(size, alignment);
    if (result != nullptr) {
      std::fill_n(static_cast<std::byte *>(result), size, std::byte{});
      live += size;
    }

    return result;
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    const std::span bytes{static_cast<const std::byte *>(pointer), size};
    dirty_release = dirty_release || std::ranges::any_of(bytes, [](std::byte value) { return value != std::byte{}; });
    upstream_.deallocate(pointer, size, alignment);
    live -= size;
  }

  std::size_t live = 0;
  bool dirty_release = false;
  bool fail = false;

  SystemAllocator upstream_;
};

}
}
