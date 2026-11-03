#pragma once

#include "../flow_key.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <charconv>
#include <fcntl.h>

namespace telar::runtime::redirect {

struct LinuxTcpSocket {
  sockaddr_storage local{};
  sockaddr_storage remote{};
  uid_t user = 0;
  std::uint64_t inode = 0;
  unsigned state = 0;

  bool matches(const Target &source, const Target &destination) const noexcept {
    return endpointMatches(local, source.endpoint.storage) && endpointMatches(remote, destination.endpoint.storage);
  }

  static std::optional<LinuxTcpSocket> parse(std::string_view line, int family) noexcept {
    constexpr std::size_t required_fields = 10;
    std::array<std::string_view, required_fields> fields;
    for (auto &field : fields) {
      const auto first = line.find_first_not_of(" \t");
      if (first == std::string_view::npos) {
        return std::nullopt;
      }
      line.remove_prefix(first);
      const auto separator = line.find_first_of(" \t");
      field = line.substr(0, separator);
      line = separator == std::string_view::npos ? std::string_view{} : line.substr(separator);
    }

    LinuxTcpSocket socket;
    if (!endpoint(fields[1], family, socket.local) || !endpoint(fields[2], family, socket.remote) || !number(fields[3], socket.state, 16) || !number(fields[7], socket.user, 10) || !number(fields[9], socket.inode, 10)) {
      return std::nullopt;
    }
    return socket;
  }

private:
  template <typename Integer>
  static bool number(std::string_view input, Integer &output, int base) noexcept {
    const auto parsed = std::from_chars(input.data(), input.data() + input.size(), output, base);
    return parsed.ec == std::errc{} && parsed.ptr == input.data() + input.size();
  }

  static bool endpoint(std::string_view input, int family, sockaddr_storage &output) noexcept {
    constexpr std::size_t word_digits = sizeof(std::uint32_t) * 2;
    const auto address_digits = family == AF_INET ? word_digits : word_digits * 4;
    if (input.size() != address_digits + 1 + sizeof(std::uint16_t) * 2 || input[address_digits] != ':') {
      return false;
    }

    std::uint16_t port = 0;
    if (!number(input.substr(address_digits + 1), port, 16)) {
      return false;
    }
    std::array<std::uint32_t, 4> words{};
    for (std::size_t index = 0; index < address_digits / word_digits; ++index) {
      if (!number(input.substr(index * word_digits, word_digits), words[index], 16)) {
        return false;
      }
    }

    if (family == AF_INET) {
      auto &address = reinterpret_cast<sockaddr_in &>(output);
      address.sin_family = AF_INET;
      address.sin_port = htons(port);
      std::memcpy(&address.sin_addr, words.data(), sizeof(address.sin_addr));
    } else {
      auto &address = reinterpret_cast<sockaddr_in6 &>(output);
      address.sin6_family = AF_INET6;
      address.sin6_port = htons(port);
      std::memcpy(&address.sin6_addr, words.data(), sizeof(address.sin6_addr));
    }
    return true;
  }

  static bool endpointMatches(const sockaddr_storage &left, const sockaddr_storage &right) noexcept {
    if (left.ss_family != right.ss_family) {
      return false;
    }
    if (left.ss_family == AF_INET) {
      const auto &actual = reinterpret_cast<const sockaddr_in &>(left);
      const auto &expected = reinterpret_cast<const sockaddr_in &>(right);
      return actual.sin_port == expected.sin_port && actual.sin_addr.s_addr == expected.sin_addr.s_addr;
    }
    const auto &actual = reinterpret_cast<const sockaddr_in6 &>(left);
    const auto &expected = reinterpret_cast<const sockaddr_in6 &>(right);
    return actual.sin6_port == expected.sin6_port && std::memcmp(&actual.sin6_addr, &expected.sin6_addr, sizeof(in6_addr)) == 0;
  }
};

template <typename Visitor>
void visitLinuxTcpSockets(Visitor &&visit) {
  constexpr std::array families{AF_INET, AF_INET6};
  constexpr std::size_t read_capacity = 4096;
  constexpr std::size_t maximum_line_bytes = 1024;
  constexpr std::size_t maximum_entries = 65536;
  for (const auto family : families) {
    FileDescriptor file{::open(family == AF_INET ? "/proc/net/tcp" : "/proc/net/tcp6", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
    if (!file) {
      if (family == AF_INET6 && errno == ENOENT) {
        continue;
      }
      throw SystemError{"Open TCP socket table"};
    }

    std::array<char, read_capacity> buffer;
    std::array<char, maximum_line_bytes> line;
    std::size_t length = 0;
    std::size_t entries = 0;
    bool header = true;
    for (;;) {
      const auto count = ::read(file.get(), buffer.data(), buffer.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read TCP socket table"};
      }
      if (count == 0) {
        if (length != 0) {
          throw SystemError{"Truncated TCP socket table", EINVAL};
        }
        break;
      }

      for (const auto byte : std::span{buffer}.first(static_cast<std::size_t>(count))) {
        if (byte != '\n') {
          if (length == line.size()) {
            throw SystemError{"TCP socket record exceeds its limit", EOVERFLOW};
          }
          line[length++] = byte;
          continue;
        }
        if (header) {
          header = false;
        } else {
          if (++entries > maximum_entries) {
            throw SystemError{"TCP socket table exceeds its limit", EOVERFLOW};
          }
          const auto socket = LinuxTcpSocket::parse({line.data(), length}, family);
          if (!socket) {
            throw SystemError{"Invalid TCP socket record", EINVAL};
          }
          if (!visit(*socket)) {
            return;
          }
        }
        length = 0;
      }
    }
  }
}

}
