module;
#include "telar_platform/trace_macro.hpp"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

module telar.tls;

import std;
import telar.sys.posix;
import telar.tbc;
import telar.sys.process;
import telar.sys.socket;
import telar.base.memory.sensitive;
import telar.base.text.utf8;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.process;

namespace telar::runtime {

  TlsError::TlsError(const char* operation) noexcept
      : operation_(operation),
        code_(ERR_get_error()) {}

  const char* TlsError::what() const noexcept {
    return operation_;
  }

  unsigned long TlsError::code() const noexcept {
    return code_;
  }

  void requireTls(bool succeeded, const char* operation) {
    if (!succeeded) {
      throw TlsError{operation};
    }
  }

  bool TlsHostname::numeric(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      return false;
    }

    std::array<char, INET6_ADDRSTRLEN> text{};

    std::ranges::copy(host, text.begin());
    in6_addr address{};

    return ::inet_pton(AF_INET, text.data(), &address) == 1 || ::inet_pton(AF_INET6, text.data(), &address) == 1;
  }

  bool TlsHostname::valid(std::string_view host) noexcept {
    return ProxyHostname::validTarget(host) || numeric(host);
  }

  PemDocument::PemDocument(EVP_PKEY* key) {
    requireTls(buffer_ != nullptr, "Allocate TLS key encoding");
    requireTls(PEM_write_bio_PrivateKey(buffer_.get(), key, nullptr, nullptr, 0, nullptr, nullptr) == 1, "Encode TLS private key");
    requireTls(bytes().size() <= maximum_bytes, "TLS private key exceeds its bound");
  }

  PemDocument::PemDocument(X509* certificate) {
    requireTls(buffer_ != nullptr, "Allocate TLS certificate encoding");
    requireTls(PEM_write_bio_X509(buffer_.get(), certificate) == 1, "Encode TLS certificate");
    requireTls(bytes().size() <= maximum_bytes, "TLS certificate exceeds its bound");
  }

  std::span<const std::uint8_t> PemDocument::bytes() const noexcept {
    char* data = nullptr;
    const auto length = BIO_get_mem_data(buffer_.get(), &data);

    return {reinterpret_cast<const std::uint8_t*>(data), length > 0 ? static_cast<std::size_t>(length) : 0};
  }

  void PemDocument::clearBuffer(BIO* buffer) noexcept {
    BUF_MEM* storage = nullptr;

    BIO_get_mem_ptr(buffer, &storage);
    if (storage != nullptr && storage->data != nullptr) {
      eraseSensitive(storage->data, storage->max);
    }

    BIO_free(buffer);
  }

  CertificatePair CertificatePair::authority(std::string_view name, std::chrono::seconds lifetime) {
    TELAR_TRACE("tls.generateAuthority");
    auto pair = create(name, lifetime);

    requireTls(X509_set_issuer_name(pair.certificate.get(), X509_get_subject_name(pair.certificate.get())) == 1, "Set authority issuer");
    extension(pair.certificate.get(), NID_basic_constraints, "critical,CA:TRUE");
    extension(pair.certificate.get(), NID_key_usage, "critical,keyCertSign,cRLSign");
    extension(pair.certificate.get(), NID_subject_key_identifier, "hash");
    sign(pair.certificate, pair.key.get());
    return pair;
  }

  CertificatePair CertificatePair::mint(std::string_view hostname) const {
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
    sign(leaf.certificate, key.get());
    return leaf;
  }

  CertificatePair CertificatePair::parse(std::span<const std::uint8_t> key_pem, std::span<const std::uint8_t> certificate_pem) {
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

  void CertificatePair::validateAuthority(std::string_view name, bool system) const {
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

  CertificatePair CertificatePair::create(std::string_view name, std::chrono::seconds lifetime) {
    TlsHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> generator{EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr)};

    requireTls(generator != nullptr, "Allocate TLS key generator");
    requireTls(EVP_PKEY_keygen_init(generator.get()) == 1 && EVP_PKEY_CTX_set_ec_paramgen_curve_nid(generator.get(), NID_X9_62_prime256v1) == 1, "Configure TLS P-256 key generator");
    EVP_PKEY* generated = nullptr;
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

  void CertificatePair::setName(X509_NAME* destination, std::string_view name) {
    requireTls(!name.empty() && name.size() <= ProxyHostname::maximum_bytes && !name.contains('\0'), "Invalid TLS certificate name");
    requireTls(X509_NAME_add_entry_by_NID(destination, NID_commonName, V_ASN1_UTF8STRING, reinterpret_cast<const unsigned char*>(name.data()), static_cast<int>(name.size()), -1, 0) == 1, "Set TLS certificate name");
  }

  void CertificatePair::extension(X509* certificate, int identifier, const char* value, X509* issuer) {
    X509V3_CTX context{};

    X509V3_set_ctx(&context, issuer, certificate, nullptr, nullptr, 0);
    TlsHandle<X509_EXTENSION, X509_EXTENSION_free> extension{X509V3_EXT_conf_nid(nullptr, &context, identifier, value)};

    requireTls(extension != nullptr && X509_add_ext(certificate, extension.get(), -1) == 1, "Set TLS certificate extension");
  }

  void CertificatePair::sign(TlsCertificate& certificate, EVP_PKEY* issuer) {
    requireTls(X509_sign(certificate.get(), issuer, EVP_sha256()) > 0, "Sign TLS certificate");
    const auto length = i2d_X509(certificate.get(), nullptr);

    requireTls(length > 0 && length <= static_cast<int>(maximum_der_bytes), "TLS certificate exceeds its DER bound");
  }

  int CertificatePair::refusePassword(char*, int, int, void*) noexcept {
    return 0;
  }

  TlsLibrary::TlsLibrary(ConcurrentMemory& memory) {
    if (used_ || CRYPTO_set_mem_functions(&allocate, &reallocate, &deallocate) != 1) {
      throw std::logic_error{"TLS allocation must be configured once before using OpenSSL"};
    }

    used_ = true;
    memory_ = &memory;
    if (OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT | OPENSSL_INIT_NO_LOAD_CONFIG, nullptr) != 1) {
      OPENSSL_cleanup();
      memory_ = nullptr;
      throw std::bad_alloc{};
    }
  }

  TlsLibrary::~TlsLibrary() {
    OPENSSL_cleanup();
    memory_ = nullptr;
  }

  bool TlsLibrary::uses(const ConcurrentMemory& memory) const noexcept {
    return memory_ == &memory;
  }

  void* TlsLibrary::allocate(std::size_t size, const char*, int) noexcept {
    if (memory_ == nullptr || size == 0) {
      return nullptr;
    }

    return CAllocationBlocks{*memory_}.allocate(size);
  }

  void TlsLibrary::deallocate(void* pointer, const char*, int) noexcept {
    if (pointer == nullptr) {
      return;
    }

    CAllocationBlocks{*memory_}.release(pointer);
  }

  void* TlsLibrary::reallocate(void* pointer, std::size_t size, const char* file, int line) noexcept {
    if (size == 0) {
      deallocate(pointer, file, line);
      return nullptr;
    }

    return memory_ == nullptr ? nullptr : CAllocationBlocks{*memory_}.resize(pointer, size);
  }

  tbc::view<CertificateAuthority, tbc::lt::a> CertificateAuthority::loadOrCreate(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityKind kind) {
    if (auto existing = loadExisting(memory, library, directory, kind)) {
      return std::move(*existing);
    }

    return create(memory, library, directory, AuthorityFiles::forKind(kind), kind);
  }

  tbc::view<std::optional<CertificateAuthority>, tbc::lt::a> CertificateAuthority::loadExisting(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityKind kind) {
    TELAR_TRACE("tls.loadAuthority");
    requireTls(library.uses(memory), "TLS authority allocator does not match its library");
    const auto files = AuthorityFiles::forKind(kind);
    ErasingAllocator sensitive_memory{memory};
    Vector<unsigned char, decltype(sensitive_memory)> key_bytes{AllocatorRef<unsigned char, decltype(sensitive_memory)>{sensitive_memory}};
    Vector<unsigned char, ConcurrentMemory> certificate_bytes{AllocatorRef<unsigned char, ConcurrentMemory>{memory}};
    const bool has_key = readPrivateFile(directory, files.key, key_bytes, PemDocument::maximum_bytes);
    const bool has_certificate = readPrivateFile(directory, files.certificate, certificate_bytes, PemDocument::maximum_bytes);

    requireTls(has_key == has_certificate, "TLS authority is incomplete");

    if (!has_key) {
      return std::nullopt;
    }

    auto pair = CertificatePair::parse(key_bytes, certificate_bytes);

    pair.validateAuthority(common_name, kind == AuthorityKind::system_trust);
    return CertificateAuthority{memory, std::move(pair)};
  }

  tbc::view<CertificateAuthority, tbc::lt::a> CertificateAuthority::create(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityFiles files, AuthorityKind kind) {
    requireTls(library.uses(memory), "TLS authority allocator does not match its library");
    const auto lifetime = kind == AuthorityKind::system_trust ? CertificatePair::system_lifetime : CertificatePair::private_lifetime;
    auto pair = CertificatePair::authority(common_name, lifetime);
    const PemDocument key{pair.key.get()};
    const PemDocument certificate{pair.certificate.get()};

    if (const int error = writePrivateFile(directory, files.key, key.bytes(), PrivateFileMode::create_only)) {
      throw SystemError{"Publish TLS authority key", error};
    }

    if (const int error = writePrivateFile(directory, files.certificate, certificate.bytes(), PrivateFileMode::create_only)) {
      std::array<char, NAME_MAX + 1> name{};

      std::copy(files.key.begin(), files.key.end(), name.begin());
      ::unlinkat(directory, name.data(), 0);
      throw SystemError{"Publish TLS authority certificate", error};
    }

    return CertificateAuthority{memory, std::move(pair)};
  }

  CertificatePair CertificateAuthority::mint(std::string_view hostname) const {
    return pair_.mint(hostname);
  }

  X509* CertificateAuthority::certificate() const noexcept {
    return pair_.certificate.get();
  }

  std::array<char, 40> CertificateAuthority::fingerprint() const {
    return fingerprint<20>(EVP_sha1());
  }

  std::array<char, 64> CertificateAuthority::fingerprintSha256() const {
    return fingerprint<32>(EVP_sha256());
  }

  template <std::size_t digest_bytes>
  std::array<char, digest_bytes * 2> CertificateAuthority::fingerprint(const EVP_MD* algorithm) const {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest;
    unsigned length = 0;

    requireTls(X509_digest(certificate(), algorithm, digest.data(), &length) == 1 && length == digest_bytes, "Compute TLS authority fingerprint");
    constexpr std::string_view hexadecimal = "0123456789ABCDEF";
    std::array<char, digest_bytes * 2> result;

    for (std::size_t index = 0; index < digest_bytes; ++index) {
      result[index * 2] = hexadecimal[digest[index] >> 4];
      result[index * 2 + 1] = hexadecimal[digest[index] & 15];
    }

    return result;
  }

  bool CertificateAuthority::expiresWithin(std::chrono::seconds duration) const {
    TlsHandle<ASN1_TIME, ASN1_TIME_free> deadline{ASN1_TIME_adj(nullptr, std::time(nullptr), 0, duration.count())};

    requireTls(deadline != nullptr, "Compute TLS authority expiration deadline");
    const int comparison = ASN1_TIME_compare(X509_get0_notAfter(certificate()), deadline.get());

    requireTls(comparison != -2, "Read TLS authority expiration");
    return comparison <= 0;
  }

  void CertificateAuthority::writeBundle(int directory, std::span<const std::uint8_t> roots) const {
    constexpr std::size_t maximum_root_bytes = 4 * 1024 * 1024;

    requireTls(roots.size() <= maximum_root_bytes, "TLS root bundle exceeds its bound");
    const PemDocument own{certificate()};
    Vector<std::uint8_t, ConcurrentMemory> bundle{AllocatorRef<std::uint8_t, ConcurrentMemory>{memory_}};

    bundle.reserve(roots.size() + own.bytes().size());
    bundle.insert(bundle.end(), roots.begin(), roots.end());
    bundle.insert(bundle.end(), own.bytes().begin(), own.bytes().end());
    if (const int error = writePrivateFile(directory, "ca-bundle.pem", bundle, PrivateFileMode::replace)) {
      throw SystemError{"Publish TLS trust bundle", error};
    }
  }

  CertificateAuthority::CertificateAuthority(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, CertificatePair pair) noexcept
      : memory_(memory),
        pair_(std::move(pair)) {}

  String<ConcurrentMemory> proxyAuthorityDirectoryFrom(ConcurrentMemory& memory, const void* environment, std::string_view (*lookup)(const void*, const char*)) {
    String<ConcurrentMemory> path{lookup(environment, "XDG_DATA_HOME"), AllocatorRef<char, ConcurrentMemory>{memory}};
    if (path.empty() || path.front() != '/') {
      path = lookup(environment, "HOME");
      if (path.empty()) {
        throw std::invalid_argument{"Home directory unavailable for proxy"};
      }

      path += "/.local/share";
    }

    path += "/telar/proxy";
    return path;
  }

}

namespace telar::runtime::proxy_trust {
  namespace {

    void makeName(std::array<char, NAME_MAX + 1>& output, std::string_view base, const char* operation, std::uint64_t nonce) {
      const int size = std::snprintf(output.data(), output.size(), "%.*s.%s-%016llx", static_cast<int>(base.size()), base.data(), operation, static_cast<unsigned long long>(nonce));
      if (size < 0 || static_cast<std::size_t>(size) >= output.size()) {
        throw std::length_error{"Proxy authority temporary filename exceeds its bound"};
      }
    }

  }

  SystemCommand::SystemCommand(ConcurrentMemory& memory, FILE* output) noexcept
      : memory_(memory),
        output_(output) {}

  void SystemCommand::run(std::span<const std::string_view> arguments) {
    Vector<String<ConcurrentMemory>, ConcurrentMemory> owned{AllocatorRef<String<ConcurrentMemory>, ConcurrentMemory>{memory_}};
    Vector<char*, ConcurrentMemory> pointers{AllocatorRef<char*, ConcurrentMemory>{memory_}};
    String<ConcurrentMemory> line{"telar proxy trust: exec", AllocatorRef<char, ConcurrentMemory>{memory_}};

    owned.reserve(arguments.size());
    pointers.reserve(arguments.size() + 1);
    for (const auto argument : arguments) {
      if (argument.contains('\0')) {
        throw std::invalid_argument{"Invalid proxy trust command argument"};
      }

      owned.emplace_back(argument, AllocatorRef<char, ConcurrentMemory>{memory_});
      line += ' ';
      appendJsonText(line, argument);
    }

    line += '\n';
    if (std::fwrite(line.data(), 1, line.size(), output_) != line.size() || std::fflush(output_) != 0) {
      throw SystemError{"Print proxy trust command", EIO};
    }

    for (auto& argument : owned) {
      pointers.push_back(argument.data());
    }

    pointers.push_back(nullptr);

    // The command talks to the person at the terminal, as sudo does, so it keeps the
    // standard streams and this process group, and nothing else this process holds.
    SpawnOptions spawn{0};

    spawn.keepStandardStreams();

    pid_t child;
    if (const int error = ::posix_spawn(&child, pointers.front(), &spawn.actions, &spawn.attributes, pointers.data(), environ)) {
      throw SystemError{"Start proxy trust command", error};
    }

    int status;
    pid_t waited;

    do {
      waited = ::waitpid(child, &status, 0);
    } while (waited < 0 && sys::lastError() == EINTR);

    if (waited < 0) {
      throw SystemError{"Wait for proxy trust command"};
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw SystemError{"Proxy trust command failed", EIO};
    }
  }

  std::string_view backendName(Backend backend) noexcept {
    switch (backend) {
    case Backend::macos:
      return "macos";
    case Backend::update_ca_certificates:
      return "update-ca-certificates";
    case Backend::trust:
      return "trust";
    }

    std::unreachable();
  }

  Record Record::parse(ConcurrentMemory& memory, std::string_view source) {
    validateUtf8(source);
    constexpr auto names = std::to_array<std::string_view>({"version", "backend", "fingerprint", "store_path"});
    JsonFields fields{memory, JsonValue::parse(source), names};
    if (!SchemaVersion<ConcurrentMemory>::isOne(memory, fields.required("version"))) {
      throw std::invalid_argument{"Invalid proxy trust record version"};
    }

    Record record;
    const auto backend = fields.string("backend");
    if (backend == "macos") {
      record.backend = Backend::macos;
    } else if (backend == "update-ca-certificates") {
      record.backend = Backend::update_ca_certificates;
    } else if (backend == "trust") {
      record.backend = Backend::trust;
    } else {
      throw std::invalid_argument{"Invalid proxy trust backend"};
    }

    const auto fingerprint = fields.string("fingerprint");
    if (fingerprint.size() != record.fingerprint.size()) {
      throw std::invalid_argument{"Invalid proxy trust fingerprint"};
    }

    for (std::size_t index = 0; index < fingerprint.size(); ++index) {
      const char byte = fingerprint[index];
      if (byte >= 'a' && byte <= 'f') {
        record.fingerprint[index] = byte - 'a' + 'A';
      } else if ((byte >= 'A' && byte <= 'F') || (byte >= '0' && byte <= '9')) {
        record.fingerprint[index] = byte;
      } else {
        throw std::invalid_argument{"Invalid proxy trust fingerprint"};
      }
    }

    const auto store = fields.string("store_path");
    if (store.empty() || store.front() != '/' || store.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust store path"};
    }

    record.store.assign(store);
    return record;
  }

  std::optional<Record> Record::read(ConcurrentMemory& memory, int directory) {
    Vector<unsigned char, ConcurrentMemory> source{AllocatorRef<unsigned char, ConcurrentMemory>{memory}};
    if (!readPrivateFile(directory, filename, source, maximum_bytes - 1)) {
      return std::nullopt;
    }

    return parse(memory, {reinterpret_cast<const char*>(source.data()), source.size()});
  }

  void Record::write(ConcurrentMemory& memory, int directory) const {
    String<ConcurrentMemory> source{"{\n  \"version\": 1,\n  \"backend\": ", AllocatorRef<char, ConcurrentMemory>{memory}};

    appendJsonText(source, backendName(backend));
    source += ",\n  \"fingerprint\": ";
    appendJsonText(source, {fingerprint.data(), fingerprint.size()});
    source += ",\n  \"store_path\": ";
    appendJsonText(source, store.view());
    source += "\n}\n";
    if (source.size() > maximum_bytes) {
      throw std::length_error{"Proxy trust record exceeds its bound"};
    }

    if (const int error = writePrivateFile(directory, filename, {reinterpret_cast<const unsigned char*>(source.data()), source.size()}, PrivateFileMode::replace)) {
      throw SystemError{"Publish proxy trust record", error};
    }
  }

  Destination::Destination(std::string_view path)
      : Destination(Backend::macos, path) {}

  Destination::Destination(Backend selected, std::string_view path)
      : backend(selected) {
    store.assign(path);
  }

  Paths::Paths(ConcurrentMemory& memory, std::string_view directory)
      : directory_(directory, AllocatorRef<char, ConcurrentMemory>{memory}) {
    if (directory.empty() || directory.front() != '/' || directory.contains('\0') || directory.size() + AuthorityFiles::forKind(AuthorityKind::system_trust).certificate.size() + 1 >= PATH_MAX) {
      throw std::invalid_argument{"Proxy authority directory must be an absolute bounded path"};
    }
  }

  const String<ConcurrentMemory>& Paths::directory() const noexcept {
    return directory_;
  }

  String<ConcurrentMemory> Paths::file(std::string_view name) const {
    auto path = directory_;

    path += '/';
    path += name;
    if (path.size() >= PATH_MAX) {
      throw std::length_error{"Proxy authority file path exceeds its bound"};
    }

    return path;
  }

  FileDescriptor Paths::open() const {
    // A path that names no directory holds no trust record.
    FileDescriptor descriptor{::open(directory_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!descriptor && sys::lastError() != ENOENT && sys::lastError() != ENOTDIR) {
      throw SystemError{"Open proxy authority directory"};
    }

    return descriptor;
  }

  FileDescriptor Paths::prepare() const {
    createPrivateDirectory(directory_);
    auto descriptor = open();
    if (!descriptor) {
      throw SystemError{"Open prepared proxy authority directory", ENOENT};
    }

    validateDirectory(descriptor.get());
    return descriptor;
  }

  void Paths::validateDirectory(int descriptor) {
    struct stat state{};
    if (::fstat(descriptor, &state) != 0 || !S_ISDIR(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
      throw SystemError{"Validate proxy authority directory", EACCES};
    }
  }

  String<ConcurrentMemory> Paths::keychainFrom(ConcurrentMemory& memory, const void* environment, Lookup lookup) {
    const auto home = lookup(environment, "HOME");
    String<ConcurrentMemory> result{home, AllocatorRef<char, ConcurrentMemory>{memory}};

    if (home.empty()) {
      return result;
    }

    result += "/Library/Keychains/login.keychain-db";
    if (result.front() != '/' || result.size() > PATH_MAX || result.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust keychain path"};
    }

    return result;
  }

  Destination Paths::nativeDestinationFrom(ConcurrentMemory& memory, std::optional<Backend> selected, const void* environment, Lookup lookup) const {
#if defined(__APPLE__)
    if (selected && *selected != Backend::macos) {
      throw std::invalid_argument{"Linux trust backend is not supported on macOS"};
    }

    return Destination{keychainFrom(memory, environment, lookup)};
#else
    (void)environment;
    (void)lookup;
    auto backend = selected.value_or(Backend::trust);
    if (!selected) {
      const auto directory = open();
      if (directory) {
        if (const auto record = Record::read(memory, directory.get())) {
          backend = record->backend;
        }
      }
    }
    if (backend == Backend::macos) {
      throw std::invalid_argument{"macOS trust backend is not supported on Linux"};
    }
    return Destination{backend, backend == Backend::trust ? std::string_view{file(AuthorityFiles::forKind(AuthorityKind::system_trust).certificate)} : linux_certificate_path};
#endif
  }

  std::string_view statusName(Status status) noexcept {
    switch (status) {
    case Status::absent:
      return "absent";
    case Status::installed:
      return "installed";
    case Status::stale:
      return "stale";
    }

    std::unreachable();
  }

  void validateTarget(const Record& record, const Destination& destination) {
    if (record.backend != destination.backend || record.store.view() != destination.store.view()) {
      throw std::invalid_argument{"Invalid proxy trust record target"};
    }
  }

  Inspection inspect(ConcurrentMemory& memory, const TlsLibrary& library, const Paths& paths, const Destination& destination) noexcept {
    Inspection result;

    try {
      const auto directory = paths.open();
      if (!directory) {
        return result;
      }

      result.record = Record::read(memory, directory.get());
      if (!result.record) {
        return result;
      }

      validateTarget(*result.record, destination);
      Paths::validateDirectory(directory.get());
      const auto authority = CertificateAuthority::loadExisting(memory, library, directory.get(), AuthorityKind::system_trust);

      result.status = authority && authority->fingerprint() == result.record->fingerprint && !authority->expiresWithin(rotation_window) ? Status::installed : Status::stale;
    } catch (...) {
      result.status = Status::stale;
    }

    return result;
  }

  PreparedAuthority::PreparedAuthority(ConcurrentMemory& memory, const TlsLibrary& library, int directory, AuthorityPreparation options)
      : directory_(directory),
        canonical_(AuthorityFiles::forKind(options.kind)) {
    try {
      auto existing = CertificateAuthority::loadExisting(memory, library, directory, options.kind);
      if (existing && !options.force_rotation && !existing->expiresWithin(rotation_window)) {
        authority_.emplace(std::move(*existing));
        return;
      }
    } catch (const TlsError&) {
    } catch (const SystemError&) {
    }

    std::uint64_t nonce;

    randomBytes(&nonce, sizeof(nonce));
    makeName(key_, canonical_.key, "rotate", nonce);
    makeName(certificate_, canonical_.certificate, "rotate", nonce);
    makeName(previous_key_, canonical_.key, "previous", nonce);
    makeName(previous_certificate_, canonical_.certificate, "previous", nonce);
    authority_.emplace(CertificateAuthority::create(memory, library, directory, {key_.data(), certificate_.data()}, options.kind));
    temporary_ = true;
  }

  PreparedAuthority::~PreparedAuthority() {
    if (activated_ && !committed_) {
      restore(certificate_, canonical_.certificate.data());
      restore(key_, canonical_.key.data());
    }

    if (saved_certificate_) {
      restorePrevious(previous_certificate_, canonical_.certificate.data());
    }

    if (saved_key_) {
      restorePrevious(previous_key_, canonical_.key.data());
    }

    if (temporary_) {
      ::unlinkat(directory_, key_.data(), 0);
      ::unlinkat(directory_, certificate_.data(), 0);
    }
  }

  std::string_view PreparedAuthority::certificateName() const noexcept {
    return temporary_ && !activated_ ? std::string_view{certificate_.data()} : canonical_.certificate;
  }

  const CertificateAuthority& PreparedAuthority::authority() const noexcept {
    return *authority_;
  }

  void PreparedAuthority::activate() {
    if (!temporary_) {
      return;
    }

    saved_key_ = savePrevious(canonical_.key.data(), previous_key_);
    saved_certificate_ = savePrevious(canonical_.certificate.data(), previous_certificate_);
    rename(key_.data(), canonical_.key.data());
    try {
      rename(certificate_.data(), canonical_.certificate.data());
    } catch (...) {
      restore(key_, canonical_.key.data());
      throw;
    }

    activated_ = true;
  }

  void PreparedAuthority::commit() noexcept {
    committed_ = true;
    if (saved_key_) {
      ::unlinkat(directory_, previous_key_.data(), 0);
      saved_key_ = false;
    }

    if (saved_certificate_) {
      ::unlinkat(directory_, previous_certificate_.data(), 0);
      saved_certificate_ = false;
    }
  }

  void PreparedAuthority::rename(const char* source, const char* destination) const {
    if (renameAt(directory_, source, directory_, destination, RenameMode::create_only) != 0) {
      throw SystemError{"Activate proxy authority"};
    }
  }

  bool PreparedAuthority::savePrevious(const char* source, const Filename& destination) const {
    if (renameAt(directory_, source, directory_, destination.data(), RenameMode::create_only) == 0) {
      return true;
    }

    if (sys::lastError() == ENOENT) {
      return false;
    }

    throw SystemError{"Preserve previous proxy authority"};
  }

  void PreparedAuthority::restore(const Filename& temporary, const char* canonical) const noexcept {
    if (::renameat(directory_, canonical, directory_, temporary.data()) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not roll back %s: %s\n", canonical, std::strerror(sys::lastError()));
    }
  }

  void PreparedAuthority::restorePrevious(const Filename& previous, const char* canonical) const noexcept {
    if (::renameat(directory_, previous.data(), directory_, canonical) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not restore %s: %s\n", canonical, std::strerror(sys::lastError()));
    }
  }

  Service::Service(ConcurrentMemory& memory, const TlsLibrary& library, const Paths& paths, TrustCommandRunner& executor, Destination destination) noexcept
      : memory_(memory),
        library_(library),
        paths_(paths),
        executor_(executor),
        destination_(destination) {}

  Inspection Service::inspect() const noexcept {
    return proxy_trust::inspect(memory_, library_, paths_, destination_);
  }

  Record Service::install(const std::optional<Record>& previous, bool force_rotation) {
    TELAR_TRACE("proxy.installSystemTrust");
    if (destination_.store.view().empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy trust"};
    }

    if (previous) {
      validateTarget(*previous, destination_);
    }

    const auto directory = paths_.prepare();
    PreparedAuthority prepared{memory_, library_, directory.get(), AuthorityPreparation{.force_rotation = force_rotation}};
    const auto certificate = paths_.file(prepared.certificateName());
    Record replacement;

    replacement.backend = destination_.backend;
    replacement.fingerprint = prepared.authority().fingerprint();
    replacement.store = destination_.store;
    installAuthority(certificate);

    try {
      if (previous && previous->fingerprint != replacement.fingerprint && previous->backend != Backend::update_ca_certificates) {
        remove(*previous);
      }

      prepared.activate();
      replacement.write(memory_, directory.get());
      prepared.commit();
    } catch (...) {
      try {
        remove(replacement);
      } catch (const std::exception& error) {
        std::fprintf(stderr, "telar proxy trust: could not remove partially installed authority: %s\n", error.what());
      }

      throw;
    }

    return replacement;
  }

  void Service::uninstall(const Record& record) {
    TELAR_TRACE("proxy.removeSystemTrust");
    validateTarget(record, destination_);
    const auto directory = paths_.open();
    if (!directory) {
      throw SystemError{"Proxy trust record disappeared", ENOENT};
    }

    remove(record);
    if (::unlinkat(directory.get(), Record::filename.data(), 0) != 0) {
      throw SystemError{"Remove proxy trust record"};
    }
  }

  std::optional<Record> Service::rotateIfNeeded() {
    const auto current = inspect();
    if (current.status != Status::stale || !current.record) {
      return std::nullopt;
    }

    if (destination_.backend != Backend::macos) {
      return std::nullopt;
    }

    return install(current.record);
  }

  void Service::installAuthority(std::string_view certificate) {
    switch (destination_.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", destination_.store.view(), certificate}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/install", "-m", "0644", certificate, destination_.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", certificate}));
      break;
    }
  }

  void Service::remove(const Record& record) {
    switch (record.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "delete-certificate", "-t", "-Z", {record.fingerprint.data(), record.fingerprint.size()}, record.store.view()}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/rm", "-f", record.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", "--remove", record.store.view()}));
      break;
    }
  }

}

// The parentheses keep each name from expanding as the macro the body calls.
void(OPENSSL_free)(void* pointer) {
  OPENSSL_free(pointer);
}

long(SSL_CTX_set1_verify_cert_store)(SSL_CTX* context, X509_STORE* store) {
  return SSL_CTX_set1_verify_cert_store(context, store);
}

long(SSL_CTX_set_min_proto_version)(SSL_CTX* context, int version) {
  return SSL_CTX_set_min_proto_version(context, version);
}

long(SSL_CTX_set_mode)(SSL_CTX* context, long mode) {
  return SSL_CTX_set_mode(context, mode);
}

long(SSL_CTX_set_session_cache_mode)(SSL_CTX* context, long mode) {
  return SSL_CTX_set_session_cache_mode(context, mode);
}

long(SSL_add1_chain_cert)(SSL* ssl, X509* certificate) {
  return SSL_add1_chain_cert(ssl, certificate);
}

void*(SSL_get_app_data)(const SSL* ssl) {
  return SSL_get_app_data(ssl);
}

int(SSL_set_app_data)(SSL* ssl, void* data) {
  return SSL_set_app_data(ssl, data);
}

long(SSL_set_tlsext_host_name)(SSL* ssl, const char* name) {
  return SSL_set_tlsext_host_name(ssl, name);
}

int(sk_X509_OBJECT_num)(const stack_st_X509_OBJECT* objects) {
  return sk_X509_OBJECT_num(objects);
}

X509_OBJECT*(sk_X509_OBJECT_value)(const stack_st_X509_OBJECT* objects, int index) {
  return sk_X509_OBJECT_value(objects, index);
}
