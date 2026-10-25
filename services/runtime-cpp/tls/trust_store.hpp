#pragma once

#include "handle.hpp"
#include "library.hpp"
#include <ctime>
#include <span>

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsTrustStore {
public:
  explicit TlsTrustStore(Memory &memory, const TlsLibrary<Memory> &library) {
    requireTls(library.uses(memory), "TLS trust allocator does not match its library");
    store_.reset(X509_STORE_new());
    requireTls(store_ != nullptr, "Allocate TLS trust store");
  }

  void addDer(std::span<const unsigned char> encoded) {
    requireTls(!encoded.empty() && encoded.size() <= maximum_certificate_bytes, "Invalid TLS root certificate size");
    auto *position = encoded.data();
    TlsCertificate certificate{d2i_X509(nullptr, &position, static_cast<long>(encoded.size()))};
    requireTls(certificate != nullptr && position == encoded.data() + encoded.size(), "Decode TLS root certificate");
    add(certificate.get());
  }

  void add(X509 *certificate) {
    TlsHandle<ASN1_TIME, ASN1_TIME_free> now{ASN1_TIME_set(nullptr, std::time(nullptr))};
    requireTls(now != nullptr, "Read TLS trust validation time");
    const int expiration = ASN1_TIME_compare(X509_get0_notAfter(certificate), now.get());
    requireTls(expiration != -2, "Invalid TLS root expiration");
    if (expiration < 0) {
      return;
    }

    const auto *objects = X509_STORE_get0_objects(store_.get());
    for (int index = 0; index < sk_X509_OBJECT_num(objects); ++index) {
      const auto *object = sk_X509_OBJECT_value(objects, index);
      if (X509_OBJECT_get_type(object) != X509_LU_X509) {
        continue;
      }
      const auto *existing = X509_OBJECT_get0_X509(object);
      if (X509_NAME_cmp(X509_get_subject_name(existing), X509_get_subject_name(certificate)) == 0) {
        return;
      }
    }
    requireTls(X509_STORE_add_cert(store_.get(), certificate) == 1, "Add TLS trust anchor");
    ++count_;
  }

  X509_STORE *native() const noexcept {
    return store_.get();
  }

  std::size_t count() const noexcept {
    return count_;
  }

private:
  static constexpr std::size_t maximum_certificate_bytes = 1024 * 1024;
  TlsHandle<X509_STORE, X509_STORE_free> store_;
  std::size_t count_ = 0;
};

}
