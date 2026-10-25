#pragma once

#include "../memory/erasing_allocator.hpp"
#include "../memory/sensitive_buffer.hpp"
#include "../platform/private_file.hpp"
#include "../platform/write_private_file.hpp"
#include "secret.hpp"

namespace telar::runtime {

class ProxySecretFile {
public:
  template <Allocator Memory>
  static std::optional<ProxySecret> load(Memory &memory, int directory) {
    ErasingAllocator sensitive{memory};
    Vector<unsigned char, decltype(sensitive)> bytes{AllocatorRef<unsigned char, decltype(sensitive)>{sensitive}};
    if (!readPrivateFile(directory, filename, bytes, maximum_file_bytes)) {
      return std::nullopt;
    }

    std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) {
      text.remove_suffix(1);
    }
    const auto secret = ProxySecret::fromHexadecimal(text);
    if (!secret) {
      throw SystemError{"Invalid proxy secret", EINVAL};
    }
    return secret;
  }

  template <Allocator Memory>
  static ProxySecret ensure(Memory &memory, int directory) {
    if (const auto existing = load(memory, directory)) {
      return *existing;
    }

    const auto secret = ProxySecret::generate();
    SensitiveBuffer<ProxySecret::hexadecimal_bytes + 1> line;
    secret.formatHexadecimal({reinterpret_cast<char *>(line.bytes().data()), ProxySecret::hexadecimal_bytes});
    line.bytes().back() = '\n';
    const auto failure = writePrivateFile(directory, filename, line.bytes(), PrivateFileMode::create_only);
    if (failure != 0) {
      throw SystemError{"Create proxy secret", failure};
    }
    return secret;
  }

private:
  static constexpr char filename[] = "proxy-secret";
  static constexpr std::size_t maximum_file_bytes = ProxySecret::hexadecimal_bytes + 8;
};

}
