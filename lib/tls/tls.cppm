module;
#include "tbc/annotations.hpp"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

export module telar.tls;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.platform.paths;

import telar.base.text;
import telar.base.text.json;
import telar.platform.primitives;
import telar.sys.posix;
import telar.base.ds;

// Interface: telar_tls/handle.cppm
export {
  namespace telar::runtime {

    class TlsError : public std::exception {
    public:
      explicit TlsError(const char* operation) noexcept;

      const char* what() const noexcept override;
      unsigned long code() const noexcept;

    private:
      const char* operation_;
      unsigned long code_;
    };

    void requireTls(bool succeeded, const char* operation);

    // A unique_ptr deleter used with every OpenSSL handle type; it stays inline so a release is one direct call.
    template <typename Value, auto Destroy>
    struct TBC_GENERIC TlsDeleter {
      inline void operator()(Value* value) const noexcept {
        Destroy(value);
      }
    };

    template <typename Value, auto Destroy>
    using TlsHandle = std::unique_ptr<Value, TlsDeleter<Value, Destroy>>;

    using TlsKey = TlsHandle<EVP_PKEY, EVP_PKEY_free>;
    using TlsCertificate = TlsHandle<X509, X509_free>;
    using TlsBuffer = TlsHandle<BIO, BIO_free>;
    using TlsContext = TlsHandle<SSL_CTX, SSL_CTX_free>;
    using TlsConnection = TlsHandle<SSL, SSL_free>;

    // Frees a copy of a trust store's object list and the reference it holds on each object.
    void freeTlsObjects(stack_st_X509_OBJECT* objects) noexcept;
    // A copy of a trust store's object list, from X509_STORE_get1_objects.
    using TlsObjects = TlsHandle<stack_st_X509_OBJECT, freeTlsObjects>;

  }
}

// Interface: telar_tls/hostname.cppm
export {
  namespace telar::runtime {

    class TlsHostname {
    public:
      static bool numeric(std::string_view host) noexcept;
      static bool valid(std::string_view host) noexcept;
    };

  }
}

// Interface: telar_tls/pem_document.cppm
export {
  namespace telar::runtime {

    class PemDocument {
    public:
      static constexpr std::size_t maximum_bytes = 4096;

      explicit PemDocument(EVP_PKEY* key);
      explicit PemDocument(X509* certificate);

      PemDocument(const PemDocument&) = delete;
      PemDocument& operator=(const PemDocument&) = delete;

      std::span<const std::uint8_t> bytes() const noexcept;

    private:
      static void clearBuffer(BIO* buffer) noexcept;

      TlsHandle<BIO, clearBuffer> buffer_{BIO_new(BIO_s_mem())};
    };

  }
}

// Interface: telar_tls/certificate_pair.cppm
export {
  namespace telar::runtime {

    struct CertificatePair {
      static constexpr std::size_t maximum_der_bytes = 2048;
      static constexpr auto backdate = std::chrono::hours{1};
      static constexpr auto private_lifetime = std::chrono::days{3650};
      static constexpr auto system_lifetime = std::chrono::days{30};
      static constexpr auto leaf_lifetime = std::chrono::days{30};

      TlsKey key;
      TlsCertificate certificate;

      static CertificatePair authority(std::string_view name, std::chrono::seconds lifetime);
      CertificatePair mint(std::string_view hostname) const;
      static CertificatePair parse(std::span<const std::uint8_t> key_pem, std::span<const std::uint8_t> certificate_pem);
      void validateAuthority(std::string_view name, bool system) const;

    private:
      static CertificatePair create(std::string_view name, std::chrono::seconds lifetime);
      static void setName(X509_NAME* destination, std::string_view name);
      static void extension(X509* certificate, int identifier, const char* value, X509* issuer = nullptr);

      // Signs a certificate with a key; a pair signs its own certificate with its own key.
      static void sign(TlsCertificate& certificate, EVP_PKEY* issuer);
      static int refusePassword(char*, int, int, void*) noexcept;
    };

  }
}

// Interface: telar_tls/library.cppm
export {
  namespace telar::runtime {

    // OPENSSL_cleanup must hand every allocation back before memory_ is cleared;
    // only the managed OpenSSL build, patched to clean up immediately, does that.
    static_assert(std::string_view{OPENSSL_VERSION_STR} == TELAR_OPENSSL_VERSION, "TLS allocator ownership requires the managed OpenSSL headers");

    class TlsLibrary {
    public:
      explicit TlsLibrary(ConcurrentMemory& memory);
      ~TlsLibrary();

      TlsLibrary(const TlsLibrary&) = delete;
      TlsLibrary& operator=(const TlsLibrary&) = delete;

      bool uses(const ConcurrentMemory& memory) const noexcept;

    private:
      static void* allocate(std::size_t size, const char*, int) noexcept;
      static void deallocate(void* pointer, const char*, int) noexcept;
      static void* reallocate(void* pointer, std::size_t size, const char* file, int line) noexcept;

      // OpenSSL cannot be reinitialized after cleanup, and its callbacks have no context argument.
      inline static ConcurrentMemory* memory_ = nullptr;
      inline static bool used_ = false;
    };

  }
}

// Interface: telar_tls/authority.cppm
export {
  namespace telar::runtime {

    enum class AuthorityKind {
      private_local,
      system_trust,
    };

    struct AuthorityFiles {
      std::string_view key;
      std::string_view certificate;

      static constexpr AuthorityFiles forKind(AuthorityKind kind) noexcept {
        return kind == AuthorityKind::system_trust ? AuthorityFiles{"ca-system-key.pem", "ca-system-cert.pem"} : AuthorityFiles{"ca-key.pem", "ca-cert.pem"};
      }
    };

    class CertificateAuthority {
    public:
      static constexpr std::string_view common_name = "telar local CA";

      // An authority allocates from its allocator in region `a`; the library only checks that it is configured.
      static tbc::view<CertificateAuthority, tbc::lt::a> loadOrCreate(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityKind kind);
      static tbc::view<ds::Option<CertificateAuthority>, tbc::lt::a> loadExisting(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityKind kind);
      static tbc::view<CertificateAuthority, tbc::lt::a> create(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityFiles files, AuthorityKind kind);

      CertificatePair mint(std::string_view hostname) const;
      X509* certificate() const noexcept;
      std::array<char, 40> fingerprint() const;
      std::array<char, 64> fingerprintSha256() const;

    private:
      template <std::size_t digest_bytes>
      std::array<char, digest_bytes * 2> fingerprint(const EVP_MD* algorithm) const;

    public:
      bool expiresWithin(std::chrono::seconds duration) const;
      void writeBundle(int directory, std::span<const std::uint8_t> roots) const;

    private:
      explicit CertificateAuthority(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, CertificatePair pair) noexcept;

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      CertificatePair pair_;
    };

  }
}

// Interface: telar_tls/authority_directory.cppm
export {
  namespace telar::runtime {

    // The directory without the caller's environment type: lookup reads a variable from environment.
    String<ConcurrentMemory> proxyAuthorityDirectoryFrom(ConcurrentMemory& memory, const void* environment, std::string_view (*lookup)(const void*, const char*));

    // Generic over the caller's environment, so it stays here and hands the lookup to proxyAuthorityDirectoryFrom.
    template <Allocator Memory, EnvironmentLookup Environment>
    TBC_GENERIC String<Memory> proxyAuthorityDirectory(Memory& memory, const Environment& environment) {
      return proxyAuthorityDirectoryFrom(memory, std::addressof(environment), [](const void* target, const char* name) {
        return static_cast<const Environment*>(target)->lookup(name);
      });
    }

  }
}

// Interface: telar_tls/trust/command.cppm
export {
  namespace telar::runtime::proxy_trust {

    template <typename Executor>
    concept TrustCommandExecutor = requires(Executor& executor, std::span<const std::string_view> arguments) {
      { executor.run(arguments) } -> std::same_as<void>;
    };

    // What Service runs the trust store's commands through, so it compiles once rather than once per executor.
    class TrustCommandRunner {
    public:
      virtual ~TrustCommandRunner() = default;
      virtual void run(std::span<const std::string_view> arguments) = 0;
    };

    class SystemCommand : public TrustCommandRunner {
    public:
      explicit SystemCommand(ConcurrentMemory& memory, FILE* output) noexcept;

      void run(std::span<const std::string_view> arguments) override;

    private:
      ConcurrentMemory& memory_;
      FILE* output_;
    };

  }
}

// Interface: telar_tls/trust/record.cppm
export {
  namespace telar::runtime::proxy_trust {

    enum class Backend {
      macos,
      update_ca_certificates,
      trust,
    };

    std::string_view backendName(Backend backend) noexcept;

    struct Record {
      static constexpr std::string_view filename = "trust-install.json";
      static constexpr std::size_t maximum_bytes = 4096;

      Backend backend = Backend::macos;
      std::array<char, 40> fingerprint;
      FixedText<PATH_MAX> store;

      static Record parse(ConcurrentMemory& memory, std::string_view source);

      static ds::Option<Record> read(ConcurrentMemory& memory, int directory);

      void write(ConcurrentMemory& memory, int directory) const;
    };

  }
}

// Interface: telar_tls/trust/destination.cppm
export {
  namespace telar::runtime::proxy_trust {

    inline constexpr std::string_view linux_certificate_path = "/usr/local/share/ca-certificates/telar-proxy.crt";

    struct Destination {
      Destination(std::string_view path);

      // Generic over the caller's text type, so it stays here and forwards to the string_view constructor.
      template <typename Text>
        requires std::convertible_to<const Text&, std::string_view>
      TBC_GENERIC Destination(const Text& path)
          : Destination(std::string_view{path}) {}

      Destination(Backend selected, std::string_view path);

      Backend backend;
      FixedText<PATH_MAX> store;
    };

  }
}

// Interface: telar_tls/trust/paths.cppm
export {
  namespace telar::runtime::proxy_trust {

    class Paths {
    public:
      explicit Paths(ConcurrentMemory& memory, std::string_view directory);

      const String<ConcurrentMemory>& directory() const noexcept;
      String<ConcurrentMemory> file(std::string_view name) const;
      FileDescriptor open() const;
      FileDescriptor prepare() const;
      static void validateDirectory(int descriptor);

      // Generic over the caller's environment, so it stays here and hands the lookup to keychainFrom.
      template <EnvironmentLookup Environment>
      TBC_GENERIC static String<ConcurrentMemory> keychain(ConcurrentMemory& memory, const Environment& environment) {
        return keychainFrom(memory, std::addressof(environment), [](const void* target, const char* name) {
          return static_cast<const Environment*>(target)->lookup(name);
        });
      }

      // Generic over the caller's environment, so it stays here and hands the lookup to nativeDestinationFrom.
      template <EnvironmentLookup Environment>
      TBC_GENERIC Destination nativeDestination(ConcurrentMemory& memory, const Environment& environment, ds::Option<Backend> selected = ds::none) const {
        return nativeDestinationFrom(memory, selected, std::addressof(environment), [](const void* target, const char* name) {
          return static_cast<const Environment*>(target)->lookup(name);
        });
      }

    private:
      using Lookup = std::string_view (*)(const void*, const char*);

      static String<ConcurrentMemory> keychainFrom(ConcurrentMemory& memory, const void* environment, Lookup lookup);
      Destination nativeDestinationFrom(ConcurrentMemory& memory, ds::Option<Backend> selected, const void* environment, Lookup lookup) const;

      String<ConcurrentMemory> directory_;
    };

  }
}

// Interface: telar_tls/trust/inspection.cppm
export {
  namespace telar::runtime::proxy_trust {

    enum class Status {
      absent,
      installed,
      stale,
    };

    std::string_view statusName(Status status) noexcept;

    struct Inspection {
      Status status = Status::absent;
      ds::Option<Record> record;
    };

    inline constexpr auto rotation_window = std::chrono::hours{24};

    void validateTarget(const Record& record, const Destination& destination);

    Inspection inspect(ConcurrentMemory& memory, const TlsLibrary& library, const Paths& paths, const Destination& destination) noexcept;

  }
}

// Interface: telar_tls/trust/prepared_authority.cppm
export {
  namespace telar::runtime::proxy_trust {

    struct AuthorityPreparation {
      AuthorityKind kind = AuthorityKind::system_trust;
      bool force_rotation = false;
    };

    class PreparedAuthority {
    public:
      explicit PreparedAuthority(ConcurrentMemory& memory, const TlsLibrary& library, int directory, AuthorityPreparation options = {});
      ~PreparedAuthority();

      PreparedAuthority(const PreparedAuthority&) = delete;
      PreparedAuthority& operator=(const PreparedAuthority&) = delete;

      std::string_view certificateName() const noexcept;
      const CertificateAuthority& authority() const noexcept;
      void activate();
      void commit() noexcept;

    private:
      using Filename = std::array<char, NAME_MAX + 1>;

      // The file operations change the directory, not the authority, so they lend nothing of it.
      void rename(const char* source, const char* destination) const;
      bool savePrevious(const char* source, const Filename& destination) const;
      void restore(const Filename& temporary, const char* canonical) const noexcept;
      void restorePrevious(const Filename& previous, const char* canonical) const noexcept;

      int directory_;
      AuthorityFiles canonical_;
      ds::Option<CertificateAuthority> authority_;
      Filename key_;
      Filename certificate_;
      Filename previous_key_;
      Filename previous_certificate_;
      bool temporary_ = false;
      bool activated_ = false;
      bool committed_ = false;
      bool saved_key_ = false;
      bool saved_certificate_ = false;
    };

  }
}

// Interface: telar_tls/trust/service.cppm
export {
  namespace telar::runtime::proxy_trust {

    enum class Action {
      install,
      uninstall,
      rotate,
    };

    class Service {
    public:
      explicit Service(ConcurrentMemory& memory, const TlsLibrary& library, const Paths& paths, TrustCommandRunner& executor, Destination destination) noexcept;

      Inspection inspect() const noexcept;
      Record install(const ds::Option<Record>& previous, bool force_rotation = false);
      void uninstall(const Record& record);
      ds::Option<Record> rotateIfNeeded();

    private:
      void installAuthority(std::string_view certificate);
      void remove(const Record& record);

      ConcurrentMemory& memory_;
      const TlsLibrary& library_;
      const Paths& paths_;
      TrustCommandRunner& executor_;
      Destination destination_;
    };

  }
}

// OpenSSL's headers stay in this module's global fragments only; importers reach the library
// through these declarations instead of including them.
export {
  using ::ASN1_TIME;
  using ::BIO;
  using ::SSL;
  using ::SSL_CTX;
  using ::X509;
  using ::X509_STORE;

  using ::ASN1_TIME_compare;
  using ::ASN1_TIME_free;
  using ::ASN1_TIME_set;
  using ::BIO_eof;
  using ::BIO_free;
  using ::BIO_new_file;
  using ::d2i_X509;
  using ::ERR_clear_error;
  using ::i2d_X509;
  using ::PEM_read_bio_X509_AUX;
  using ::SSL_CTX_new;
  using ::SSL_CTX_set_alpn_select_cb;
  using ::SSL_CTX_set_num_tickets;
  using ::SSL_CTX_set_options;
  using ::SSL_CTX_set_verify;
  using ::SSL_do_handshake;
  using ::SSL_get0_alpn_selected;
  using ::SSL_get0_param;
  using ::SSL_get_error;
  using ::SSL_new;
  using ::SSL_pending;
  using ::SSL_read_ex;
  using ::SSL_set1_dnsname;
  using ::SSL_set_accept_state;
  using ::SSL_set_alpn_protos;
  using ::SSL_set_connect_state;
  using ::SSL_set_fd;
  using ::SSL_shutdown;
  using ::SSL_use_certificate;
  using ::SSL_use_PrivateKey;
  using ::SSL_write_ex;
  using ::TLS_client_method;
  using ::TLS_server_method;
  using ::X509_check_trust;
  using ::X509_cmp;
  using ::X509_free;
  using ::X509_get0_notAfter;
  using ::X509_get_default_cert_file_env;
  using ::X509_OBJECT_get0_X509;
  using ::X509_OBJECT_get_type;
  using ::X509_STORE_add_cert;
  using ::X509_STORE_free;
  using ::X509_STORE_get1_objects;
  using ::X509_STORE_new;
  using ::X509_VERIFY_PARAM_set1_ip_asc;

  using ::X509_LU_X509;
}

// Macros do not cross an import. Each constant the tree reads is captured while the headers still
// define it, undefined, and exported under its own name. The function-like macros are functions
// defined in tls.cpp, where the macros are.
#define TELAR_TLS_CONSTANTS(X)           \
  X(SSL_ERROR_WANT_READ)                 \
  X(SSL_ERROR_WANT_WRITE)                \
  X(SSL_ERROR_ZERO_RETURN)               \
  X(SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER) \
  X(SSL_MODE_ENABLE_PARTIAL_WRITE)       \
  X(SSL_OP_IGNORE_UNEXPECTED_EOF)        \
  X(SSL_OP_NO_COMPRESSION)               \
  X(SSL_OP_NO_RENEGOTIATION)             \
  X(SSL_SESS_CACHE_OFF)                  \
  X(SSL_TLSEXT_ERR_ALERT_FATAL)          \
  X(SSL_TLSEXT_ERR_NOACK)                \
  X(SSL_TLSEXT_ERR_OK)                   \
  X(SSL_VERIFY_PEER)                     \
  X(TLS1_2_VERSION)                      \
  X(X509_TRUST_REJECTED)                 \
  X(X509_TRUST_SSL_SERVER)

namespace telar::runtime::tls::captured {

#define TELAR_TLS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_TLS_CONSTANTS(TELAR_TLS_CAPTURE)

}

#undef SSL_ERROR_WANT_READ
#undef SSL_ERROR_WANT_WRITE
#undef SSL_ERROR_ZERO_RETURN
#undef SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
#undef SSL_MODE_ENABLE_PARTIAL_WRITE
#undef SSL_OP_IGNORE_UNEXPECTED_EOF
#undef SSL_OP_NO_COMPRESSION
#undef SSL_OP_NO_RENEGOTIATION
#undef SSL_SESS_CACHE_OFF
#undef SSL_TLSEXT_ERR_ALERT_FATAL
#undef SSL_TLSEXT_ERR_NOACK
#undef SSL_TLSEXT_ERR_OK
#undef SSL_VERIFY_PEER
#undef TLS1_2_VERSION
#undef X509_TRUST_REJECTED
#undef X509_TRUST_SSL_SERVER
#undef OPENSSL_free
#undef SSL_CTX_set1_verify_cert_store
#undef SSL_CTX_set_min_proto_version
#undef SSL_CTX_set_mode
#undef SSL_CTX_set_session_cache_mode
#undef SSL_add1_chain_cert
#undef SSL_get_app_data
#undef SSL_set_app_data
#undef SSL_set_tlsext_host_name
#undef sk_X509_OBJECT_num
#undef sk_X509_OBJECT_value

#define TELAR_TLS_CONSTANT(name) inline constexpr auto name = telar::runtime::tls::captured::name##_;

export {
  TELAR_TLS_CONSTANTS(TELAR_TLS_CONSTANT)

  void OPENSSL_free(void* pointer);
  long SSL_CTX_set1_verify_cert_store(SSL_CTX* context, X509_STORE* store);
  long SSL_CTX_set_min_proto_version(SSL_CTX* context, int version);
  long SSL_CTX_set_mode(SSL_CTX* context, long mode);
  long SSL_CTX_set_session_cache_mode(SSL_CTX* context, long mode);
  long SSL_add1_chain_cert(SSL* ssl, X509* certificate);
  void* SSL_get_app_data(const SSL* ssl);
  int SSL_set_app_data(SSL* ssl, void* data);
  long SSL_set_tlsext_host_name(SSL* ssl, const char* name);
  int sk_X509_OBJECT_num(const stack_st_X509_OBJECT* objects);
  X509_OBJECT* sk_X509_OBJECT_value(const stack_st_X509_OBJECT* objects, int index);
}
