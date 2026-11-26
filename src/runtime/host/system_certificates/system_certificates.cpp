module telar.runtime.host.system_certificates;

import telar.tbc;
import telar.sys.posix;
import telar.tls;
import telar.platform.error;
#ifdef __APPLE__
import telar.runtime.host.frameworks;
#endif

#ifdef __linux__
namespace telar::runtime {

  void SystemCertificates::FreeEncoded::operator()(unsigned char* bytes) const noexcept {
    OPENSSL_free(bytes);
  }

  const char* SystemCertificates::bundle() noexcept {
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

  void SystemCertificates::readBundle(void* target, void (*consume)(void*, std::span<const std::uint8_t>)) {
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
      consume(target, std::span<const std::uint8_t>{bytes.get(), static_cast<std::size_t>(length)});
    }
  }

}

#endif

#ifdef __APPLE__
namespace telar::runtime {
  namespace {
    using Resource = std::unique_ptr<const void, decltype(&CFRelease)>;
  }

  void SystemCertificates::readKeychain(const char* path, void* target, void (*consume)(void*, std::span<const std::uint8_t>)) {
    SecKeychainRef opened = nullptr;
    // SecKeychain is deprecated with no successor that opens a given keychain file; the
    // trust-settings API that replaces it reads which roots are trusted, not what a keychain holds.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const auto opening = SecKeychainOpen(path, &opened);
#pragma clang diagnostic pop
    if (opening != errSecSuccess) {
      throw SystemError{"Open system certificate keychain", EACCES};
    }

    const Resource keychain{opened, &CFRelease};
    // CFArrayCreate takes its values through a mutable pointer, though it only reads them.
    ds::Array<const void*, 1> search_items{opened};
    const Resource search{CFArrayCreate(kCFAllocatorDefault, search_items.dataMut(), static_cast<CFIndex>(search_items.size()), &kCFTypeArrayCallBacks), &CFRelease};
    if (!search) {
      throw std::bad_alloc{};
    }

    constexpr std::size_t query_fields = 5;
    ds::Array<const void*, query_fields> keys{kSecClass, kSecMatchSearchList, kSecMatchLimit, kSecReturnRef, kSecUseAuthenticationUI};
    ds::Array<const void*, query_fields> values{kSecClassCertificate, search.get(), kSecMatchLimitAll, kCFBooleanTrue, kSecUseAuthenticationUISkip};
    const Resource query{CFDictionaryCreate(kCFAllocatorDefault, keys.dataMut(), values.dataMut(), static_cast<CFIndex>(keys.size()), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks), &CFRelease};
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

    const auto* const certificates = static_cast<CFArrayRef>(result.get());

    for (CFIndex index = 0; index < CFArrayGetCount(certificates); ++index) {
      const auto* const item = CFArrayGetValueAtIndex(certificates, index);
      if (item == nullptr || CFGetTypeID(item) != SecCertificateGetTypeID()) {
        throw SystemError{"Invalid system certificate entry", EINVAL};
      }

      auto* const certificate = static_cast<SecCertificateRef>(tbc::raw(const_cast<void*>(item))); // NOLINT(cppcoreguidelines-pro-type-const-cast): CFArray hands its objects out as const void*, and Security takes a certificate as a mutable reference
      const Resource encoded{SecCertificateCopyData(certificate), &CFRelease};
      if (!encoded) {
        throw std::bad_alloc{};
      }

      const auto* const data = static_cast<CFDataRef>(encoded.get());
      // CFData hands its bytes over as a pointer and a length.
#pragma clang unsafe_buffer_usage begin
      const std::span<const std::uint8_t> bytes{CFDataGetBytePtr(data), static_cast<std::size_t>(CFDataGetLength(data))};
#pragma clang unsafe_buffer_usage end

      consume(target, bytes);
    }
  }

}

#endif
