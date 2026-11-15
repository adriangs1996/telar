module;
#include "tbc/annotations.hpp"

export module telar.runtime.platform.system_certificates;

import std;


#if defined(__linux__)
// Interface: platform/linux/system_certificates.cppm
export {
  namespace telar::runtime {

    class SystemCertificates {
      struct FreeEncoded {
        void operator()(unsigned char* bytes) const noexcept;
      };

      // telar links its own OpenSSL, whose default bundle path matches only some
      // distributions. These are the bundles Go's crypto/x509 looks for, in order.
      static constexpr std::array bundles{
          "/etc/ssl/certs/ca-certificates.crt",                // Debian, Ubuntu, Gentoo and others
          "/etc/pki/tls/certs/ca-bundle.crt",                  // Fedora, RHEL 6
          "/etc/ssl/ca-bundle.pem",                            // openSUSE
          "/etc/pki/tls/cacert.pem",                           // OpenELEC
          "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // CentOS, RHEL 7
          "/etc/ssl/cert.pem",                                 // Alpine
      };

      static const char* bundle() noexcept;

      // Reads the bundle and hands each certificate to `consume`, which calls the caller's consumer at `target`.
      static void readBundle(void* target, void (*consume)(void*, std::span<const std::uint8_t>));

    public:
      // Stays generic over the caller's consumer, which the reader calls through a function pointer.
      template <typename Consumer>
      TBC_GENERIC inline static void read(Consumer&& consume) {
        using Target = std::remove_reference_t<Consumer>;

        readBundle(const_cast<std::remove_const_t<Target>*>(std::addressof(consume)), [](void* target, std::span<const std::uint8_t> bytes) {
          (*static_cast<Target*>(target))(bytes);
        });
      }
    };

  }
}

#endif

#if defined(__APPLE__)
// Interface: platform/macos/system_certificates.cppm
export {
  namespace telar::runtime {

    class SystemCertificates {
    public:
      // Stays generic over the caller's consumer, which the reader calls through a function pointer.
      template <typename Consumer>
      TBC_GENERIC inline static void read(Consumer&& consume) {
        using Target = std::remove_reference_t<Consumer>;
        const auto sink = [](void* target, std::span<const std::uint8_t> bytes) {
          (*static_cast<Target*>(target))(bytes);
        };

        for (const auto path : keychains) {
          readKeychain(path, const_cast<std::remove_const_t<Target>*>(std::addressof(consume)), sink);
        }
      }

    private:
      // Reads one keychain and hands each certificate to `consume`, which calls the caller's consumer at `target`.
      static void readKeychain(const char* path, void* target, void (*consume)(void*, std::span<const std::uint8_t>));

      static constexpr std::array<const char*, 2> keychains{
          "/System/Library/Keychains/SystemRootCertificates.keychain",
          "/Library/Keychains/System.keychain"
      };
    };

  }
}

#endif

// Interface: platform/system_certificates.cppm
export {
#if defined(__APPLE__)
#else
#endif
}
