#pragma once

#include "telar_platform/random_bytes.hpp"
#include "telar_platform/trace.hpp"
#include "telar_tls/handle.hpp"
#include "telar_tls/hostname.hpp"
#include "telar_tls/pem_document.hpp"
#include <array>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <string_view>

namespace telar::runtime {

struct CertificatePair {
  static constexpr std::size_t maximum_der_bytes = 2048;
  static constexpr auto backdate = std::chrono::hours{1};
  static constexpr auto private_lifetime = std::chrono::days{3650};
  static constexpr auto system_lifetime = std::chrono::days{30};
  static constexpr auto leaf_lifetime = std::chrono::days{30};

  TlsKey key;
  TlsCertificate certificate;

  static CertificatePair authority(std::string_view name, std::chrono::seconds lifetime) {
    TELAR_TRACE("tls.generateAuthority");
    auto pair = create(name, lifetime);
    requireTls(X509_set_issuer_name(pair.certificate.get(), X509_get_subject_name(pair.certificate.get())) == 1, "Set authority issuer");
    extension(pair.certificate.get(), NID_basic_constraints, "critical,CA:TRUE");
    extension(pair.certificate.get(), NID_key_usage, "critical,keyCertSign,cRLSign");
    extension(pair.certificate.get(), NID_subject_key_identifier, "hash");
    pair.sign(pair.key.get());
    return pair;
  }

  CertificatePair mint(std::string_view hostname) const {
    TELAR_TRACE("tls.mintCertificate");
    requireTls(TlsHostname::valid(hostname), "Invalid TLS certificate hostname");
    auto leaf = create(hostname, leaf_lifetime);
    requireTls(X509_set_issuer_name(leaf.certificate.get(), X509_get_subject_name(certificate.get())) == 1, "Set leaf issuer");
    extension(leaf.certificate.get(), NID_basic_constraints, "critical,CA:FALSE");
    extension(leaf.certificate.get(), NID_key_usage, "critical,digitalSignature");
    extension(leaf.certificate.get(), NID_ext_key_usage, "serverAuth");
    // Older persisted authorities may lack a subject key identifier. In that
    // case the issuer name and serial still identify the correct signing CA.
    extension(leaf.certificate.get(), NID_authority_key_identifier, "keyid,issuer", certificate.get());

    const std::string_view prefix = TlsHostname::numeric(hostname) ? "IP:" : "DNS:";
    std::array<char, 4 + ProxyHostname::maximum_bytes + 1> alternative{};
    std::copy(prefix.begin(), prefix.end(), alternative.begin());
    std::copy(hostname.begin(), hostname.end(), alternative.begin() + prefix.size());
    extension(leaf.certificate.get(), NID_subject_alt_name, alternative.data());
    leaf.sign(key.get());
    return leaf;
  }

  static CertificatePair parse(std::span<const std::uint8_t> key_pem, std::span<const std::uint8_t> certificate_pem) {
    requireTls(!key_pem.empty() && key_pem.size() <= PemDocument::maximum_bytes, "Invalid TLS key size");
    requireTls(!certificate_pem.empty() && certificate_pem.size() <= PemDocument::maximum_bytes, "Invalid TLS certificate size");
    TlsBuffer key_input{BIO_new_mem_buf(key_pem.data(), static_cast<int>(key_pem.size()))};
    TlsBuffer certificate_input{BIO_new_mem_buf(certificate_pem.data(), static_cast<int>(certificate_pem.size()))};
    requireTls(key_input != nullptr && certificate_input != nullptr, "Allocate TLS parser");

    CertificatePair pair;
    pair.key.reset(PEM_read_bio_PrivateKey(key_input.get(), nullptr, &refusePassword, nullptr));
    pair.certificate.reset(PEM_read_bio_X509(certificate_input.get(), nullptr, nullptr, nullptr));
    requireTls(pair.key != nullptr && pair.certificate != nullptr, "Decode TLS authority");
    return pair;
  }

  void validateAuthority(std::string_view name, bool system) const {
    requireTls(EVP_PKEY_is_a(key.get(), "EC") == 1, "TLS authority requires an EC key");
    std::array<char, 80> group;
    std::size_t length = 0;
    requireTls(EVP_PKEY_get_group_name(key.get(), group.data(), group.size(), &length) == 1 && std::string_view{group.data(), length} == "prime256v1", "TLS authority requires a P-256 key");
    requireTls(X509_check_private_key(certificate.get(), key.get()) == 1, "TLS authority key does not match its certificate");
    requireTls(X509_verify(certificate.get(), key.get()) == 1, "TLS authority signature is invalid");
    requireTls(X509_check_ca(certificate.get()) > 0, "TLS certificate is not an authority");
    TlsHandle<ASN1_TIME, ASN1_TIME_free> now{ASN1_TIME_set(nullptr, std::time(nullptr))};
    requireTls(now != nullptr, "Read TLS validation time");
    const int begins = ASN1_TIME_compare(X509_get0_notBefore(certificate.get()), now.get());
    const int ends = ASN1_TIME_compare(X509_get0_notAfter(certificate.get()), now.get());
    requireTls(begins >= -1 && begins <= 0 && ends >= 0, "TLS authority is outside its validity period");
    const auto encoded_length = i2d_X509(certificate.get(), nullptr);
    requireTls(encoded_length > 0 && encoded_length <= static_cast<int>(maximum_der_bytes), "TLS authority exceeds its DER bound");

    TlsHandle<X509_NAME, X509_NAME_free> expected{X509_NAME_new()};
    requireTls(expected != nullptr, "Allocate TLS authority name");
    setName(expected.get(), name);
    requireTls(X509_NAME_cmp(expected.get(), X509_get_subject_name(certificate.get())) == 0 && X509_NAME_cmp(expected.get(), X509_get_issuer_name(certificate.get())) == 0, "TLS authority name does not match");
    if (system) {
      int days = 0;
      int seconds = 0;
      requireTls(ASN1_TIME_diff(&days, &seconds, X509_get0_notBefore(certificate.get()), X509_get0_notAfter(certificate.get())) == 1 && std::chrono::days{days} + std::chrono::seconds{seconds} <= system_lifetime + backdate, "TLS system authority lifetime is too long");
    }
  }

private:
  static CertificatePair create(std::string_view name, std::chrono::seconds lifetime) {
    TlsHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> generator{EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr)};
    requireTls(generator != nullptr, "Allocate TLS key generator");
    requireTls(EVP_PKEY_keygen_init(generator.get()) == 1 && EVP_PKEY_CTX_set_ec_paramgen_curve_nid(generator.get(), NID_X9_62_prime256v1) == 1, "Configure TLS P-256 key generator");
    EVP_PKEY *generated = nullptr;
    const auto result = EVP_PKEY_keygen(generator.get(), &generated);
    CertificatePair pair{TlsKey{generated}, TlsCertificate{X509_new()}};
    requireTls(result == 1 && pair.key != nullptr && pair.certificate != nullptr, "Generate TLS key pair");
    constexpr long version_three = 2;
    requireTls(X509_set_version(pair.certificate.get(), version_three) == 1 && X509_set_pubkey(pair.certificate.get(), pair.key.get()) == 1, "Set TLS certificate public key");

    std::uint64_t serial;
    randomBytes(&serial, sizeof(serial));
    serial >>= 1;
    requireTls(ASN1_INTEGER_set_uint64(X509_get_serialNumber(pair.certificate.get()), serial == 0 ? 1 : serial) == 1, "Set TLS certificate serial");
    const auto backdate_seconds = std::chrono::duration_cast<std::chrono::seconds>(backdate).count();
    requireTls(X509_gmtime_adj(X509_getm_notBefore(pair.certificate.get()), -backdate_seconds) != nullptr && X509_gmtime_adj(X509_getm_notAfter(pair.certificate.get()), lifetime.count()) != nullptr, "Set TLS certificate validity");
    TlsHandle<X509_NAME, X509_NAME_free> subject{X509_NAME_new()};
    requireTls(subject != nullptr, "Allocate TLS certificate subject");
    setName(subject.get(), name);
    requireTls(X509_set_subject_name(pair.certificate.get(), subject.get()) == 1, "Set TLS certificate subject");
    return pair;
  }

  static void setName(X509_NAME *destination, std::string_view name) {
    requireTls(!name.empty() && name.size() <= ProxyHostname::maximum_bytes && !name.contains('\0'), "Invalid TLS certificate name");
    requireTls(X509_NAME_add_entry_by_NID(destination, NID_commonName, V_ASN1_UTF8STRING, reinterpret_cast<const unsigned char *>(name.data()), static_cast<int>(name.size()), -1, 0) == 1, "Set TLS certificate name");
  }

  static void extension(X509 *certificate, int identifier, const char *value, X509 *issuer = nullptr) {
    X509V3_CTX context{};
    X509V3_set_ctx(&context, issuer, certificate, nullptr, nullptr, 0);
    TlsHandle<X509_EXTENSION, X509_EXTENSION_free> extension{X509V3_EXT_conf_nid(nullptr, &context, identifier, value)};
    requireTls(extension != nullptr && X509_add_ext(certificate, extension.get(), -1) == 1, "Set TLS certificate extension");
  }

  void sign(EVP_PKEY *issuer) {
    requireTls(X509_sign(certificate.get(), issuer, EVP_sha256()) > 0, "Sign TLS certificate");
    const auto length = i2d_X509(certificate.get(), nullptr);
    requireTls(length > 0 && length <= static_cast<int>(maximum_der_bytes), "TLS certificate exceeds its DER bound");
  }

  static int refusePassword(char *, int, int, void *) noexcept {
    return 0;
  }
};

}
