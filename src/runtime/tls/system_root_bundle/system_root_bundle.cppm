export module telar.runtime.tls.system_root_bundle;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;

// Interface: tls/system_root_bundle.cppm
export {
  namespace telar::runtime {

    class SystemRootBundle {
    public:
      explicit SystemRootBundle(ConcurrentMemory& memory);

      std::span<const std::uint8_t> bytes() const noexcept;

    private:
      static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
      static constexpr std::array<std::string_view, 4> paths{
          "/etc/ssl/cert.pem",
          "/etc/ssl/certs/ca-certificates.crt",
          "/etc/pki/tls/certs/ca-bundle.crt",
          "/etc/ssl/ca-bundle.pem"
      };
      ByteQueue<ConcurrentMemory> bytes_;
    };

  }
}
