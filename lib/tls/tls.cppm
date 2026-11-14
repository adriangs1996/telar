module;
#include "tbc/annotations.hpp"

#include <openssl/crypto.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

export module telar.tls;

import std;
import telar.tbc;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;

export import telar.platform.paths;

import telar.base.diagnostics;
import telar.base.memory.sensitive;
import telar.base.text;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.sys.posix;

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
    struct TBC_HOT_PATH TlsDeleter {
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
      static tbc::view<std::optional<CertificateAuthority>, tbc::lt::a> loadExisting(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const TlsLibrary& library, int directory, AuthorityKind kind);
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
    TBC_HOT_PATH String<Memory> proxyAuthorityDirectory(Memory& memory, const Environment& environment) {
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

      static std::optional<Record> read(ConcurrentMemory& memory, int directory);

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
      TBC_HOT_PATH Destination(const Text& path)
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
      TBC_HOT_PATH static String<ConcurrentMemory> keychain(ConcurrentMemory& memory, const Environment& environment) {
        return keychainFrom(memory, std::addressof(environment), [](const void* target, const char* name) {
          return static_cast<const Environment*>(target)->lookup(name);
        });
      }

      // Generic over the caller's environment, so it stays here and hands the lookup to nativeDestinationFrom.
      template <EnvironmentLookup Environment>
      TBC_HOT_PATH Destination nativeDestination(ConcurrentMemory& memory, const Environment& environment, std::optional<Backend> selected = std::nullopt) const {
        return nativeDestinationFrom(memory, selected, std::addressof(environment), [](const void* target, const char* name) {
          return static_cast<const Environment*>(target)->lookup(name);
        });
      }

    private:
      using Lookup = std::string_view (*)(const void*, const char*);

      static String<ConcurrentMemory> keychainFrom(ConcurrentMemory& memory, const void* environment, Lookup lookup);
      Destination nativeDestinationFrom(ConcurrentMemory& memory, std::optional<Backend> selected, const void* environment, Lookup lookup) const;

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
      std::optional<Record> record;
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
      std::optional<CertificateAuthority> authority_;
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
      Record install(const std::optional<Record>& previous, bool force_rotation = false);
      void uninstall(const Record& record);
      std::optional<Record> rotateIfNeeded();

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
