module;
#include <stdlib.h>
#include <chrono>
#include <limits>
#include <utility>
#include <concepts>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <cstddef>
#include <cstring>
#include <string_view>
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <span>

#include <arpa/inet.h>

#include <variant>

#include <cerrno>
#include <exception>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <unistd.h>

export module telar.runtime.proxy.authenticate;

export import telar.base.memory;
export import telar.base.text;


export import telar.config;


export import telar.platform;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: proxy/secret.cppm
export {
namespace telar::runtime {

class ProxySecret {
public:
  static constexpr std::size_t byte_count = 32;
  static constexpr std::size_t hexadecimal_bytes = byte_count * 2;

  inline static ProxySecret generate() noexcept {
    ProxySecret secret;
    randomBytes(secret.bytes_.data(), secret.bytes_.size());
    return secret;
  }

  inline static std::optional<ProxySecret> fromHexadecimal(std::string_view text) noexcept {
    if (text.size() != hexadecimal_bytes) {
      return std::nullopt;
    }

    ProxySecret secret;
    for (std::size_t index = 0; index < byte_count; ++index) {
      const auto high = digit(text[index * 2]);
      const auto low = digit(text[index * 2 + 1]);
      if (!high || !low) {
        return std::nullopt;
      }
      secret.bytes_[index] = static_cast<std::uint8_t>((*high << 4) | *low);
    }
    return secret;
  }

  inline ~ProxySecret() {
    eraseSensitive(bytes_.data(), bytes_.size());
  }

  ProxySecret(const ProxySecret &) = default;
  ProxySecret &operator=(const ProxySecret &) = default;

  inline bool matches(const ProxySecret &other) const noexcept {
    volatile unsigned difference = 0;
    for (std::size_t index = 0; index < byte_count; ++index) {
      difference = difference | (bytes_[index] ^ other.bytes_[index]);
    }
    return difference == 0;
  }

  inline std::optional<std::string_view> formatHexadecimal(std::span<char> destination) const noexcept {
    if (destination.size() < hexadecimal_bytes) {
      return std::nullopt;
    }

    for (std::size_t index = 0; index < byte_count; ++index) {
      destination[index * 2] = hexadecimal[bytes_[index] >> 4];
      destination[index * 2 + 1] = hexadecimal[bytes_[index] & 15];
    }
    return std::string_view{destination.data(), hexadecimal_bytes};
  }

  inline std::optional<std::string_view> formatUrl(std::span<char> destination, std::uint16_t port) const noexcept {
    constexpr std::string_view prefix = "http://telar:";
    constexpr std::string_view address = "@127.0.0.1:";
    constexpr std::size_t port_digits = 5;
    if (destination.size() < prefix.size() + hexadecimal_bytes + address.size() + port_digits) {
      return std::nullopt;
    }

    auto *end = std::copy(prefix.begin(), prefix.end(), destination.data());
    formatHexadecimal({end, hexadecimal_bytes});
    end += hexadecimal_bytes;
    end = std::copy(address.begin(), address.end(), end);
    end = std::to_chars(end, destination.data() + destination.size(), port).ptr;
    return std::string_view{destination.data(), static_cast<std::size_t>(end - destination.data())};
  }

private:
  inline ProxySecret() noexcept {}

  inline static std::optional<unsigned> digit(char character) noexcept {
    const auto position = hexadecimal.find(asciiLower(character));
    return position == std::string_view::npos ? std::nullopt : std::optional{static_cast<unsigned>(position)};
  }

  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  std::array<std::uint8_t, byte_count> bytes_;
};

}
}

// Interface: proxy/authorization.cppm
export {
namespace telar::runtime {

class ProxyAuthorization {
public:
  inline static std::optional<ProxySecret> parse(std::string_view head) noexcept {
    std::optional<ProxySecret> secret;
    while (const auto value = next(head)) {
      if (secret) {
        return std::nullopt;
      }

      const auto authorization = trim(*value);
      if (authorization.size() < 7 || !sameCaseInsensitive(authorization.substr(0, 5), "basic") || authorization[5] != ' ') {
        return std::nullopt;
      }

      SensitiveBuffer<decoded_capacity> decoded;
      const auto length = base64::decode(trim(authorization.substr(6)), decoded.bytes());
      if (!length || *length != userinfo_prefix.size() + ProxySecret::hexadecimal_bytes) {
        return std::nullopt;
      }
      const std::string_view userinfo{reinterpret_cast<const char *>(decoded.bytes().data()), *length};
      if (!userinfo.starts_with(userinfo_prefix)) {
        return std::nullopt;
      }

      secret = ProxySecret::fromHexadecimal(userinfo.substr(userinfo_prefix.size()));
      if (!secret) {
        return std::nullopt;
      }
    }
    return secret;
  }

  inline static bool present(std::string_view head) noexcept {
    return next(head).has_value();
  }

private:
  inline static bool sameCaseInsensitive(std::string_view left, std::string_view right) noexcept {
    return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char first, char second) { return asciiLower(first) == asciiLower(second); });
  }

  inline static std::string_view trim(std::string_view value) noexcept {
    const auto first = value.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }
    return value.substr(first, value.find_last_not_of(" \t") - first + 1);
  }

  inline static std::optional<std::string_view> next(std::string_view &head) noexcept {
    auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      head = {};
      return std::nullopt;
    }
    head.remove_prefix(line_end + 2);
    while (!head.empty()) {
      line_end = head.find("\r\n");
      const auto line = head.substr(0, line_end);
      const auto colon = line.find(':');
      if (colon != std::string_view::npos && sameCaseInsensitive(line.substr(0, colon), "proxy-authorization")) {
        return line.substr(colon + 1);
      }
      head.remove_prefix(line_end == std::string_view::npos ? head.size() : line_end + 2);
    }
    return std::nullopt;
  }

  static constexpr std::string_view userinfo_prefix = "telar:";
  static constexpr std::size_t decoded_capacity = 192;
};

}
}

// Interface: proxy/target.cppm
export {
namespace telar::runtime {

struct ProxyTarget {
  std::string_view hostname;
  std::uint16_t port;

  inline static std::optional<ProxyTarget> parse(std::string_view head) noexcept {
    constexpr std::string_view method = "CONNECT ";
    constexpr std::string_view version = " HTTP/1.1";
    const auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      return std::nullopt;
    }

    const auto line = head.substr(0, line_end);
    if (!line.starts_with(method) || !line.ends_with(version) || line.size() <= method.size() + version.size()) {
      return std::nullopt;
    }

    const auto authority = line.substr(method.size(), line.size() - method.size() - version.size());
    const auto colon = authority.rfind(':');
    if (colon == std::string_view::npos || colon == 0 || colon > ProxyHostname::maximum_bytes) {
      return std::nullopt;
    }

    const auto hostname = authority.substr(0, colon);
    if (!ProxyHostname::validTarget(hostname)) {
      return std::nullopt;
    }

    const auto port_text = authority.substr(colon + 1);
    std::uint16_t port = 0;
    const auto parsed = std::from_chars(port_text.data(), port_text.data() + port_text.size(), port);
    if (parsed.ec != std::errc{} || parsed.ptr != port_text.data() + port_text.size() || port == 0) {
      return std::nullopt;
    }
    return ProxyTarget{hostname, port};
  }
};

}
}

// Interface: proxy/authenticate.cppm
export {
namespace telar::runtime {

struct ProxyAdmission {
  ProxyTarget target;
  bool authenticated;
};

struct ProxyRejection {
  enum class Reason {
    invalid_authorization,
    unknown_credential,
    invalid_target
  };

  Reason reason;

  inline std::string_view response() const noexcept {
    if (reason == Reason::invalid_target) {
      return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    }
    return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  }
};

using ProxyDecision = std::variant<ProxyAdmission, ProxyRejection>;

template <Allocator Memory>
ProxyDecision authenticateProxy(const ProxySecret &secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory> &policy, std::string_view head) noexcept {
  if (anonymous_tunnels && !ProxyAuthorization::present(head)) {
    const auto target = ProxyTarget::parse(head);
    if (!target) {
      return ProxyRejection{ProxyRejection::Reason::invalid_target};
    }
    if (policy.contains(target->hostname)) {
      return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
    }
    return ProxyAdmission{*target, false};
  }

  const auto presented = ProxyAuthorization::parse(head);
  if (!presented) {
    return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
  }
  if (!secret.matches(*presented)) {
    return ProxyRejection{ProxyRejection::Reason::unknown_credential};
  }

  const auto target = ProxyTarget::parse(head);
  if (!target) {
    return ProxyRejection{ProxyRejection::Reason::invalid_target};
  }
  return ProxyAdmission{*target, true};
}

}
}

// Interface: proxy/secret_file.cppm
export {
namespace telar::runtime {

class ProxySecretFile {
public:
  template <Allocator Memory>
  inline static std::optional<ProxySecret> load(Memory &memory, int directory) {
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
  inline static ProxySecret ensure(Memory &memory, int directory) {
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
}
