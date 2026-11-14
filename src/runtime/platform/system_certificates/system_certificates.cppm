module;
#include <cerrno>
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif
#if (!(defined(__APPLE__)))
#include <cstdlib>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <unistd.h>
#endif

export module telar.runtime.platform.system_certificates;

import std;

import telar.platform.error;

#if defined(__linux__)
// Interface: platform/linux/system_certificates.cppm
export {
  namespace telar::runtime {

    class SystemCertificates {
      struct FreeEncoded {
        inline void operator()(unsigned char* bytes) const noexcept {
          OPENSSL_free(bytes);
        }
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

      inline static const char* bundle() noexcept {
        const auto* path = std::getenv(X509_get_default_cert_file_env());
        if (path != nullptr && path[0] != '\0') {
          return path;
        }

        for (const auto* candidate : bundles) {
          if (::access(candidate, R_OK) == 0) {
            return candidate;
          }
        }

        return bundles.back();
      }

    public:
      template <typename Consumer>
      inline static void read(Consumer&& consume) {
        const auto* path = bundle();
        const std::unique_ptr<BIO, decltype(&BIO_free)> file{BIO_new_file(path, "r"), &BIO_free};
        if (!file) {
          throw SystemError{"Open system certificate bundle", EACCES};
        }

        std::size_t count = 0;
        for (;;) {
          const std::unique_ptr<X509, decltype(&X509_free)> certificate{PEM_read_bio_X509_AUX(file.get(), nullptr, nullptr, nullptr), &X509_free};
          if (!certificate) {
            if (!BIO_eof(file.get()) || count == 0) {
              throw SystemError{"Read system certificate bundle", EINVAL};
            }
            ERR_clear_error();
            return;
          }
          ++count;
          if (X509_check_trust(certificate.get(), X509_TRUST_SSL_SERVER, 0) == X509_TRUST_REJECTED) {
            continue;
          }

          unsigned char* encoded = nullptr;
          const auto length = i2d_X509(certificate.get(), &encoded);
          const std::unique_ptr<unsigned char, FreeEncoded> bytes{encoded};
          if (length <= 0 || encoded == nullptr) {
            throw SystemError{"Encode system certificate", EINVAL};
          }
          consume(std::span<const std::uint8_t>{bytes.get(), static_cast<std::size_t>(length)});
        }
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
      template <typename Consumer>
      inline static void read(Consumer&& consume) {
        for (const auto path : keychains) {
          readKeychain(path, consume);
        }
      }

    private:
      using Resource = std::unique_ptr<const void, decltype(&CFRelease)>;

      template <typename Consumer>
      inline static void readKeychain(const char* path, Consumer& consume) {
        SecKeychainRef opened = nullptr;
        if (SecKeychainOpen(path, &opened) != errSecSuccess) {
          throw SystemError{"Open system certificate keychain", EACCES};
        }

        const Resource keychain{opened, &CFRelease};
        const void* search_items[]{opened};
        const Resource search{CFArrayCreate(kCFAllocatorDefault, search_items, 1, &kCFTypeArrayCallBacks), &CFRelease};
        if (!search) {
          throw std::bad_alloc{};
        }

        const void* keys[]{kSecClass, kSecMatchSearchList, kSecMatchLimit, kSecReturnRef, kSecUseAuthenticationUI};
        const void* values[]{kSecClassCertificate, search.get(), kSecMatchLimitAll, kCFBooleanTrue, kSecUseAuthenticationUISkip};
        const Resource query{CFDictionaryCreate(kCFAllocatorDefault, keys, values, std::size(keys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks), &CFRelease};
        if (!query) {
          throw std::bad_alloc{};
        }

        CFTypeRef matched = nullptr;
        const auto status = SecItemCopyMatching(static_cast<CFDictionaryRef>(query.get()), &matched);
        const Resource result{matched, &CFRelease};

        if (status == errSecItemNotFound) {
          return;
        }

        if (status != errSecSuccess || !result || CFGetTypeID(result.get()) != CFArrayGetTypeID()) {
          throw SystemError{"Read system certificate keychain", EIO};
        }

        const auto certificates = static_cast<CFArrayRef>(result.get());

        for (CFIndex index = 0; index < CFArrayGetCount(certificates); ++index) {
          const auto item = CFArrayGetValueAtIndex(certificates, index);
          if (item == nullptr || CFGetTypeID(item) != SecCertificateGetTypeID()) {
            throw SystemError{"Invalid system certificate entry", EINVAL};
          }

          const auto certificate = static_cast<SecCertificateRef>(const_cast<void*>(item));
          const Resource encoded{SecCertificateCopyData(certificate), &CFRelease};
          if (!encoded) {
            throw std::bad_alloc{};
          }

          const auto data = static_cast<CFDataRef>(encoded.get());

          consume(std::span<const std::uint8_t>{CFDataGetBytePtr(data), static_cast<std::size_t>(CFDataGetLength(data))});
        }
      }

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
