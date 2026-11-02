#pragma once

#include "../error.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <array>
#include <cstdint>
#include <memory>
#include <span>

namespace telar::runtime {

class SystemCertificates {
public:
  template <typename Consumer>
  static void read(Consumer &&consume) {
    for (const auto path : keychains) {
      readKeychain(path, consume);
    }
  }

private:
  using Resource = std::unique_ptr<const void, decltype(&CFRelease)>;

  template <typename Consumer>
  static void readKeychain(const char *path, Consumer &consume) {
    SecKeychainRef opened = nullptr;
    if (SecKeychainOpen(path, &opened) != errSecSuccess) {
      throw SystemError{"Open system certificate keychain", EACCES};
    }
    const Resource keychain{opened, &CFRelease};
    const void *search_items[]{opened};
    const Resource search{CFArrayCreate(kCFAllocatorDefault, search_items, 1, &kCFTypeArrayCallBacks), &CFRelease};
    if (!search) {
      throw std::bad_alloc{};
    }

    const void *keys[]{kSecClass, kSecMatchSearchList, kSecMatchLimit, kSecReturnRef, kSecUseAuthenticationUI};
    const void *values[]{kSecClassCertificate, search.get(), kSecMatchLimitAll, kCFBooleanTrue, kSecUseAuthenticationUISkip};
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
      const auto certificate = static_cast<SecCertificateRef>(const_cast<void *>(item));
      const Resource encoded{SecCertificateCopyData(certificate), &CFRelease};
      if (!encoded) {
        throw std::bad_alloc{};
      }
      const auto data = static_cast<CFDataRef>(encoded.get());
      consume(std::span<const std::uint8_t>{CFDataGetBytePtr(data), static_cast<std::size_t>(CFDataGetLength(data))});
    }
  }

  static constexpr std::array<const char *, 2> keychains{
      "/System/Library/Keychains/SystemRootCertificates.keychain",
      "/Library/Keychains/System.keychain"};
};

}
