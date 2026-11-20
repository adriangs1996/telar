export module telar.runtime.proxy.authenticate;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.text;

import telar.config.runtime;
import telar.base.ds;

// Interface: proxy/secret.cppm
export {
  namespace telar::runtime {

    class ProxySecret {
    public:
      static constexpr std::size_t byte_count = 32;
      static constexpr std::size_t hexadecimal_bytes = byte_count * 2;

      static ProxySecret generate() noexcept;

      static ds::Option<ProxySecret> fromHexadecimal(std::string_view text) noexcept;

      ~ProxySecret();

      ProxySecret(const ProxySecret&) = default;
      ProxySecret& operator=(const ProxySecret&) = default;

      bool matches(const ProxySecret& other) const noexcept;

      tbc::val_a<ds::Option<std::string_view>> formatHexadecimal(tbc::val_a<std::span<char>> destination) const noexcept;

      tbc::val_a<ds::Option<std::string_view>> formatUrl(tbc::val_a<std::span<char>> destination, std::uint16_t port) const noexcept;

    private:
      ProxySecret() noexcept;

      static ds::Option<unsigned> digit(char character) noexcept;

      static constexpr std::string_view hexadecimal = "0123456789abcdef";
      ds::Array<std::uint8_t, byte_count> bytes_;
    };

  }
}

// Interface: proxy/authorization.cppm
export {
  namespace telar::runtime {

    class ProxyAuthorization {
    public:
      static ds::Option<ProxySecret> parse(std::string_view head) noexcept;

      static bool present(std::string_view head) noexcept;

    private:
      static ds::Option<std::string_view> next(std::string_view& head) noexcept;

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

      tbc::val_static<std::string_view> response() const noexcept;
    };

    using ProxyDecision = std::variant<ProxyAdmission, ProxyRejection>;

    // The admitted target views the request head.
    template <Allocator Memory>
    tbc::val_a<ProxyDecision> authenticateProxy(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept;
    extern template tbc::val_a<ProxyDecision> authenticateProxy<Memory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept;
    extern template tbc::val_a<ProxyDecision> authenticateProxy<ConcurrentMemory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<ConcurrentMemory>& policy, tbc::val_a<std::string_view> head) noexcept;

  }
}

// Interface: proxy/secret_file.cppm
export {
  namespace telar::runtime {

    class ProxySecretFile {
    public:
      static ds::Option<ProxySecret> load(Memory& memory, int directory);

      template <Allocator Memory>
      static ProxySecret ensure(Memory& memory, int directory);

    private:
      static constexpr char filename[] = "proxy-secret";
      static constexpr std::size_t maximum_file_bytes = ProxySecret::hexadecimal_bytes + 8;
    };

    extern template ProxySecret ProxySecretFile::ensure<Memory>(Memory& memory, int directory);
    extern template ProxySecret ProxySecretFile::ensure<ConcurrentMemory>(ConcurrentMemory& memory, int directory);

  }
}
