module;
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.traffic.tls.interception;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.tls;

import telar.runtime.host.stream_read_buffer;
import telar.runtime.host.tunnel_sockets;
import telar.base.text;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.net;
import telar.base.ds;

// Interface: tls/alpn_offer.cppm
export {
  namespace telar::runtime {

    enum class HttpProtocol : std::uint8_t {
      http11,
      http2,
      other,
    };

    class AlpnOffer {
    public:
      enum class Read : std::uint8_t {
        pending,
        complete,
        ended,
      };

      // The bytes are written before they are read: allocating an offer does not zero 64 KiB.
      AlpnOffer() noexcept;

      Read peek(int socket) noexcept;

      // Parses a handshake by copying it into the offer, which keeps where its protocols lie.
      void parse(std::span<const std::uint8_t> handshake) noexcept;

      [[nodiscard]] bool tls() const noexcept;

      [[nodiscard]] bool valid() const noexcept;

      [[nodiscard]] bool encrypted() const noexcept;

      [[nodiscard]] std::string_view serverName() const noexcept;

      [[nodiscard]] std::span<const std::uint8_t> encoded() const noexcept;

    private:
      void parseStored(std::size_t size) noexcept;

      // What a hello's extensions say, as far as they were read: `valid` when they are well formed.
      struct Extensions {
        bool valid = false;
        bool encrypted = false;
        std::size_t protocols_offset = 0;
        std::size_t protocols_size = 0;
      };

      // Reads the extensions, which start `offset` bytes into the hello, and the server name into `name`.
      static Extensions readExtensions(std::span<const std::uint8_t> extension_bytes, std::size_t offset, FixedText<ProxyHostname::maximum_bytes>& name) noexcept;

      class Cursor {
      public:
        explicit Cursor(std::span<const std::uint8_t> bytes) noexcept;

        std::span<const std::uint8_t> take(std::size_t count) noexcept;

        std::uint8_t byte() noexcept;

        std::uint16_t word() noexcept;

        [[nodiscard]] bool failed() const noexcept;

        [[nodiscard]] bool empty() const noexcept;

        [[nodiscard]] std::size_t remaining() const noexcept;

      private:
        std::span<const std::uint8_t> bytes_;
        bool failed_ = false;
      };

      [[nodiscard]] Read incomplete(std::size_t count) const noexcept;

      // Reads the server name into `name`, from the hello the offer holds, so neither borrows it whole.
      static bool serverName(std::span<const std::uint8_t> extension, FixedText<ProxyHostname::maximum_bytes>& name) noexcept;

      // Whether the extension lists protocols well formed.
      static bool protocols(std::span<const std::uint8_t> extension) noexcept;

      static constexpr std::uint8_t handshake_record = 22;
      static constexpr std::uint8_t client_hello = 1;
      static constexpr std::uint16_t server_name_extension = 0;
      static constexpr std::uint16_t alpn_extension = 16;
      static constexpr std::uint16_t encrypted_hello_extension = 0xfe0d;
      static constexpr std::size_t record_header_bytes = 5;
      static constexpr std::size_t maximum_record_bytes = std::size_t{16} * 1024;
      static constexpr std::size_t handshake_length_bytes = 3;
      static constexpr std::size_t version_bytes = 2;
      static constexpr std::size_t random_bytes = 32;
      static constexpr std::size_t maximum_hello_bytes = std::size_t{64} * 1024;
      ds::Array<std::uint8_t, maximum_hello_bytes> bytes_;
      FixedText<ProxyHostname::maximum_bytes> server_name_;
      bool tls_ = false;
      bool valid_ = false;
      bool encrypted_ = false;
      std::size_t protocols_offset_ = 0;
      std::size_t protocols_size_ = 0;
    };

  }
}

// Interface: tls/alpn_selection.cppm
export {
  namespace telar::runtime {

    class AlpnSelection {
    public:
      bool assign(std::span<const unsigned char> protocol) noexcept;

      [[nodiscard]] std::span<const unsigned char> protocol() const noexcept;

      // OpenSSL fixes this ABI; the selection is borrowed from the stable session via SSL app data.
      static int select(SSL* connection, const unsigned char** selected, unsigned char* length, const unsigned char* offered, unsigned offered_length, void*) noexcept;

    private:
      static constexpr std::size_t maximum_name_bytes = 255;
      ds::Array<unsigned char, maximum_name_bytes> name_{};
      unsigned char length_ = 0;
    };

  }
}

// Interface: tls/trust_store.cppm
export {
  namespace telar::runtime {

    class TlsTrustStore {
    public:
      explicit TlsTrustStore(ConcurrentMemory& memory, const TlsLibrary& library);

      void addDer(std::span<const unsigned char> encoded);

      void add(X509* certificate);

      [[nodiscard]] X509_STORE* native() const noexcept;

      [[nodiscard]] std::size_t count() const noexcept;

    private:
      static constexpr std::size_t maximum_certificate_bytes = std::size_t{1024} * 1024;
      TlsHandle<X509_STORE, X509_STORE_free> store_;
      std::size_t count_ = 0;
    };

  }
}

// Interface: tls/contexts.cppm
export {
  namespace telar::runtime {

    class TlsContexts {
    public:
      explicit TlsContexts(ConcurrentMemory& memory, const TlsLibrary& library, const TlsTrustStore& trust);

      [[nodiscard]] SSL_CTX* origin() const noexcept;

      [[nodiscard]] SSL_CTX* child() const noexcept;

    private:
      TlsContext origin_;
      TlsContext child_;
    };

  }
}

// Interface: tls/side.cppm
export {
  namespace telar::runtime {

    enum class TlsSide : std::uint8_t {
      child,
      origin,
    };

  }
}

// Interface: tls/session.cppm
export {
  namespace telar::runtime {

    class TlsSession {
    public:
      enum class State : std::uint8_t {
        initialize,
        offer,
        origin,
        child,
        established,
        failed,
      };

      enum class Failure : std::uint8_t {
        none,
        context,
        client_hello,
        origin_handshake,
        child_handshake,
        mint,
      };

      // The session shares the authority it mints from, so a rotation that replaces it leaves this one valid.
      // `offer` is the child's ClientHello when the caller already read it complete; without one the
      // session reads its own, from an offer allocated in `memory`. Either is released once the origin
      // has the protocols.
      explicit TlsSession(tbc::ref_a<TlsContexts> contexts, tbc::val_a<std::shared_ptr<const CertificateAuthority>> authority, TunnelRoute route, tbc::mut_a<ConcurrentMemory> memory, tbc::val_a<ds::Box<AlpnOffer, ConcurrentMemory>> offer);

      ~TlsSession();

      TlsSession(const TlsSession&) = delete;
      TlsSession& operator=(const TlsSession&) = delete;
      TlsSession(TlsSession&&) = delete;
      TlsSession& operator=(TlsSession&&) = delete;

      State advance() noexcept;

      [[nodiscard]] State state() const noexcept;

      [[nodiscard]] Failure failure() const noexcept;

      [[nodiscard]] StreamReadiness waiting(TlsSide side) const noexcept;

      [[nodiscard]] ds::Option<std::chrono::steady_clock::time_point> deadline() const noexcept;

      [[nodiscard]] HttpProtocol protocol() const noexcept;

      [[nodiscard]] bool unnegotiated() const noexcept;

      StreamResult read(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      StreamResult write(TlsSide side, std::span<const std::uint8_t> bytes) noexcept;

      StreamResult peek(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      StreamView peekView(TlsSide side, std::size_t maximum) noexcept;

      void consume(TlsSide side, std::size_t count) noexcept;

      [[nodiscard]] bool buffered(TlsSide side) const noexcept;

      void halfClose(TlsSide side) noexcept;

    private:
      StreamResult readNative(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      auto& input(TlsSide side) noexcept;

      void initialize();

      // Hands the child's offered protocols to the origin; false while its ClientHello is on its way.
      bool offerProtocols();

      static bool handshake(SSL* connection, StreamReadiness& waiting);

      void mirrorProtocol();

      static StreamResult ioFailure(SSL* connection, int result) noexcept;

      [[nodiscard]] SSL* endpoint(TlsSide side) const noexcept;

      std::chrono::steady_clock::time_point offer_after_;
      static constexpr std::size_t read_capacity = std::size_t{16} * 1024;
      StreamReadBuffer<read_capacity> child_input_;
      StreamReadBuffer<read_capacity> origin_input_;

      tbc::ref_a<TlsContexts> contexts_;
      tbc::val_a<std::shared_ptr<const CertificateAuthority>> authority_;
      TunnelSockets sockets_;
      FixedText<ProxyHostname::maximum_bytes> hostname_;
      bool offered_;
      tbc::val_a<ds::Box<AlpnOffer, ConcurrentMemory>> offer_;
      AlpnSelection selection_;
      TlsConnection origin_;
      TlsConnection child_;
      State state_ = State::initialize;
      Failure failure_ = Failure::none;
      StreamReadiness origin_waiting_ = StreamReadiness::writable;
      StreamReadiness child_waiting_ = StreamReadiness::readable;
    };

  }
}

// Interface: tls/interception.cppm
export {
  namespace telar::runtime {

    class TlsInterception {
    public:
      // A session it opens keeps the contexts and the allocator it is built in, region `a`.
      explicit TlsInterception(tbc::ref_a<TlsContexts> contexts, tbc::val_a<std::shared_ptr<const CertificateAuthority>> authority) noexcept;

      // `offer` is the child's ClientHello when the caller already read it complete, or null.
      tbc::val_a<ds::Box<TlsSession, ConcurrentMemory>> open(tbc::mut_a<ConcurrentMemory> memory, TunnelSockets sockets, std::string_view hostname, tbc::val_a<ds::Box<AlpnOffer, ConcurrentMemory>> offer) const;

      tbc::val_a<ds::Box<TlsSession, ConcurrentMemory>> open(tbc::mut_a<ConcurrentMemory> memory, TunnelSockets sockets, std::string_view hostname) const;

      tbc::val_a<std::shared_ptr<const CertificateAuthority>> snapshot() const noexcept;

      void replace(tbc::val_a<std::shared_ptr<const CertificateAuthority>> authority) noexcept;

      void suspend(bool value) noexcept;

      bool suspended() const noexcept;

    private:
      tbc::ref_a<TlsContexts> contexts_;
      mutable std::mutex mutex_;
      tbc::val_a<std::shared_ptr<const CertificateAuthority>> replacement_;
      std::atomic<bool> suspended_{false};
    };

  }
}

// Interface: tls/stream.cppm
export {
  namespace telar::runtime {

    class TlsStream {
    public:
      explicit TlsStream(TlsSession& session, TlsSide side) noexcept;

      StreamResult read(std::span<std::uint8_t> destination) noexcept;

      StreamResult peek(std::span<std::uint8_t> destination) noexcept;

      StreamView peekView(std::size_t maximum) noexcept;

      void consume(std::size_t count) noexcept;

      StreamResult write(std::span<const std::uint8_t> bytes) noexcept;

      void halfClose() noexcept;

    private:
      TlsSession& session_;
      TlsSide side_;
    };

    static_assert(ByteStream<TlsStream>);
    static_assert(PeekableByteStream<TlsStream>);
    static_assert(BufferedByteStream<TlsStream>);

  }
}
