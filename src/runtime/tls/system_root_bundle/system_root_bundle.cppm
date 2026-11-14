module;
#include <cstddef>
#include <cstdlib>
#include <new>

#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.tls.system_root_bundle;

import std;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;
import telar.base.diagnostics;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;

// Interface: tls/system_root_bundle.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class SystemRootBundle {
    public:
      explicit SystemRootBundle(Memory& memory);

      std::span<const std::uint8_t> bytes() const noexcept;

    private:
      static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
      static constexpr std::array<std::string_view, 4> paths{
          "/etc/ssl/cert.pem",
          "/etc/ssl/certs/ca-certificates.crt",
          "/etc/pki/tls/certs/ca-bundle.crt",
          "/etc/ssl/ca-bundle.pem"
      };
      ByteQueue<Memory> bytes_;
    };

    extern template class SystemRootBundle<ConcurrentMemory>;

    template <Allocator Memory>
    SystemRootBundle(Memory& memory) -> SystemRootBundle<Memory>;

  }
}
