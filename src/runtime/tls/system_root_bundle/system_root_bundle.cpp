module telar.runtime.tls.system_root_bundle;

import telar.sys.posix;

namespace telar::runtime {

  template <Allocator Memory>
  SystemRootBundle<Memory>::SystemRootBundle(Memory& memory)
      : bytes_(memory, maximum_bytes + 1) {
    const auto storage = bytes_.appendUninitialized(maximum_bytes + 1);
    const std::span<char> destination{reinterpret_cast<char*>(storage.data()), storage.size()};

    for (const auto path : paths) {
      const auto contents = readRegularFile(path, destination);
      if (contents && contents->size() <= maximum_bytes) {
        bytes_.truncate(contents->size());
        return;
      }
    }

    throw SystemError{"Read system PEM root bundle", ENOENT};
  }

  template <Allocator Memory>
  std::span<const std::uint8_t> SystemRootBundle<Memory>::bytes() const noexcept {
    return bytes_.readable();
  }

  template class SystemRootBundle<ConcurrentMemory>;

}
