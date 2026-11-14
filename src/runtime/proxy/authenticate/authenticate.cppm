module;
#include <new>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include <arpa/inet.h>

#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
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

import std;
import telar.tbc;

export import telar.base.memory.allocators;
export import telar.base.text;

export import telar.config.runtime;

import telar.base.diagnostics;
import telar.base.memory.sensitive;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;

// Interface: proxy/secret.cppm
export {
  namespace telar::runtime {

    class ProxySecret {
    public:
      static constexpr std::size_t byte_count = 32;
      static constexpr std::size_t hexadecimal_bytes = byte_count * 2;

      static ProxySecret generate() noexcept;

      static std::optional<ProxySecret> fromHexadecimal(std::string_view text) noexcept;

      ~ProxySecret();

      ProxySecret(const ProxySecret&) = default;
      ProxySecret& operator=(const ProxySecret&) = default;

      bool matches(const ProxySecret& other) const noexcept;

      tbc::view<std::optional<std::string_view>, tbc::lt::a> formatHexadecimal(tbc::view<std::span<char>, tbc::lt::a> destination) const noexcept;

      tbc::view<std::optional<std::string_view>, tbc::lt::a> formatUrl(tbc::view<std::span<char>, tbc::lt::a> destination, std::uint16_t port) const noexcept;

    private:
      ProxySecret() noexcept;

      static std::optional<unsigned> digit(char character) noexcept;

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
      static std::optional<ProxySecret> parse(std::string_view head) noexcept;

      static bool present(std::string_view head) noexcept;

    private:
      static std::optional<std::string_view> next(std::string_view& head) noexcept;

      static constexpr std::string_view userinfo_prefix = "telar:";
      static constexpr std::size_t decoded_capacity = 192;
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
        invalid_target,
      };

      Reason reason;

      tbc::view<std::string_view, tbc::lt::static_storage> response() const noexcept;
    };

    using ProxyDecision = std::variant<ProxyAdmission, ProxyRejection>;

    // The admitted target views the request head.
    template <Allocator Memory>
    tbc::view<ProxyDecision, tbc::lt::a> authenticateProxy(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::view<std::string_view, tbc::lt::a> head) noexcept;
    extern template tbc::view<ProxyDecision, tbc::lt::a> authenticateProxy<Memory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::view<std::string_view, tbc::lt::a> head) noexcept;
    extern template tbc::view<ProxyDecision, tbc::lt::a> authenticateProxy<ConcurrentMemory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<ConcurrentMemory>& policy, tbc::view<std::string_view, tbc::lt::a> head) noexcept;

  }
}

// Interface: proxy/secret_file.cppm
export {
  namespace telar::runtime {

    class ProxySecretFile {
    public:
      template <Allocator Memory>
      static std::optional<ProxySecret> load(Memory& memory, int directory);

      template <Allocator Memory>
      static ProxySecret ensure(Memory& memory, int directory);

    private:
      static constexpr char filename[] = "proxy-secret";
      static constexpr std::size_t maximum_file_bytes = ProxySecret::hexadecimal_bytes + 8;
    };

    extern template std::optional<ProxySecret> ProxySecretFile::load<Memory>(Memory& memory, int directory);
    extern template ProxySecret ProxySecretFile::ensure<Memory>(Memory& memory, int directory);
    extern template ProxySecret ProxySecretFile::ensure<ConcurrentMemory>(ConcurrentMemory& memory, int directory);

  }
}
