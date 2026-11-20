module telar.runtime.tls.system_root_bundle;

import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;

namespace telar::runtime {

  SystemRootBundle::SystemRootBundle(ConcurrentMemory& memory)
      : bytes_(memory, maximum_bytes + 1) {
    const auto storage = bytes_.appendUninitialized(maximum_bytes + 1);
#pragma clang unsafe_buffer_usage begin
    const std::span<char> destination{reinterpret_cast<char*>(storage.data()), storage.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view writes bytes as text
#pragma clang unsafe_buffer_usage end

    for (const auto path : paths) {
      const auto contents = readRegularFile(path, destination);
      if (contents && contents->size() <= maximum_bytes) {
        bytes_.truncate(contents->size());
        return;
      }
    }

    throw SystemError{"Read system PEM root bundle", ENOENT};
  }

  std::span<const std::uint8_t> SystemRootBundle::bytes() const noexcept {
    return bytes_.readable();
  }

}
