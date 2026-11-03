#pragma once

#include "telar_base/memory/byte_queue.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/read_regular_file.hpp"

namespace telar::runtime {

template <Allocator Memory>
class SystemRootBundle {
public:
  explicit SystemRootBundle(Memory &memory)
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

  std::span<const std::uint8_t> bytes() const noexcept {
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
