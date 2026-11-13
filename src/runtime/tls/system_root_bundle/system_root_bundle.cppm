module;
#include <cstddef>
#include <cstdlib>
#include <new>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.tls.system_root_bundle;

import std;

export import telar.base.memory;
export import telar.platform;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: tls/system_root_bundle.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class SystemRootBundle {
public:
  inline explicit SystemRootBundle(Memory &memory)
      : bytes_(memory, maximum_bytes + 1) {
    const auto storage = bytes_.appendUninitialized(maximum_bytes + 1);
    const std::span<char> destination{reinterpret_cast<char *>(storage.data()), storage.size()};
    for (const auto path : paths) {
      const auto contents = readRegularFile(path, destination);
      if (contents && contents->size() <= maximum_bytes) {
        bytes_.truncate(contents->size());
        return;
      }
    }
    throw SystemError{"Read system PEM root bundle", ENOENT};
  }

  inline std::span<const std::uint8_t> bytes() const noexcept {
    return bytes_.readable();
  }

private:
  static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
  static constexpr std::array<std::string_view, 4> paths{
      "/etc/ssl/cert.pem",
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/ca-bundle.pem"};
  ByteQueue<Memory> bytes_;
};

template <Allocator Memory>
SystemRootBundle(Memory &memory) -> SystemRootBundle<Memory>;

}
}
