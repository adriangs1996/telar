module;
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.tls.interception;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.tls;

import telar.runtime.platform.stream_read_buffer;
import telar.runtime.platform.tunnel_sockets;
import telar.base.text;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.net;
import telar.base.ds;

// Interface: tls/alpn_offer.cppm
export {
  namespace telar::runtime {

    enum class HttpProtocol {
      http11,
      http2,
      other,
    };

    class AlpnOffer {
    public:
      enum class Read {
        pending,
        complete,
        ended,
      };

      // The bytes are written before they are read: allocating an offer does not zero 64 KiB.
      AlpnOffer() noexcept;

      Read peek(int socket) noexcept;

      // Parses a handshake by copying it into the offer, which keeps where its protocols lie.
      void parse(std::span<const std::uint8_t> handshake) noexcept;

      bool tls() const noexcept;

      bool valid() const noexcept;

      bool encrypted() const noexcept;

      std::string_view serverName() const noexcept;

      std::span<const std::uint8_t> encoded() const noexcept;

    private:
      void parseStored(std::size_t size) noexcept;

      class Cursor {
      public:
        explicit Cursor(std::span<const std::uint8_t> bytes) noexcept;

        std::span<const std::uint8_t> take(std::size_t count) noexcept;

        std::uint8_t byte() noexcept;

        std::uint16_t word() noexcept;

        bool failed() const noexcept;

        bool empty() const noexcept;

        std::size_t remaining() const noexcept;

      private:
        std::span<const std::uint8_t> bytes_;
        bool failed_ = false;
      };

      Read incomplete(std::size_t count) const noexcept;

      bool serverName(std::span<const std::uint8_t> extension) noexcept;

      bool protocols(std::span<const std::uint8_t> extension) noexcept;

      static constexpr std::uint8_t handshake_record = 22;
      static constexpr std::uint8_t client_hello = 1;
      static constexpr std::uint16_t alpn_extension = 16;
      static constexpr std::size_t record_header_bytes = 5;
      static constexpr std::size_t maximum_record_bytes = 16 * 1024;
      static constexpr std::size_t handshake_length_bytes = 3;
      static constexpr std::size_t version_bytes = 2;
      static constexpr std::size_t random_bytes = 32;
      static constexpr std::size_t maximum_hello_bytes = 64 * 1024;
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

      std::span<const unsigned char> protocol() const noexcept;

      // OpenSSL fixes this ABI; the selection is borrowed from the stable session via SSL app data.
      static int select(SSL* connection, const unsigned char** selected, unsigned char* length, const unsigned char* offered, unsigned offered_length, void*) noexcept;

    private:
      ds::Array<unsigned char, 255> name_;
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

      X509_STORE* native() const noexcept;

      std::size_t count() const noexcept;

    private:
      static constexpr std::size_t maximum_certificate_bytes = 1024 * 1024;
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

      SSL_CTX* origin() const noexcept;

      SSL_CTX* child() const noexcept;

    private:
      TlsContext origin_;
      TlsContext child_;
    };

  }
}

// Interface: tls/side.cppm
export {
  namespace telar::runtime {

    enum class TlsSide {
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
      enum class State {
        initialize,
        offer,
        origin,
        child,
        established,
        failed,
      };

      enum class Failure {
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
      explicit TlsSession(tbc::view<const TlsContexts&, tbc::lt::a> contexts, tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority, TunnelSockets sockets, std::string_view hostname, tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<ds::Box<AlpnOffer, ConcurrentMemory>, tbc::lt::a> offer);

      ~TlsSession();

      TlsSession(const TlsSession&) = delete;
      TlsSession& operator=(const TlsSession&) = delete;

      State advance() noexcept;

      State state() const noexcept;

      Failure failure() const noexcept;

      StreamReadiness waiting(TlsSide side) const noexcept;

      ds::Option<std::chrono::steady_clock::time_point> deadline() const noexcept;

      HttpProtocol protocol() const noexcept;

      bool unnegotiated() const noexcept;

      StreamResult read(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      StreamResult write(TlsSide side, std::span<const std::uint8_t> bytes) noexcept;

      StreamResult peek(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      StreamView peekView(TlsSide side, std::size_t maximum) noexcept;

      void consume(TlsSide side, std::size_t count) noexcept;

      bool buffered(TlsSide side) const noexcept;

      void halfClose(TlsSide side) noexcept;

    private:
      StreamResult readNative(TlsSide side, std::span<std::uint8_t> destination) noexcept;

      auto& input(TlsSide side) noexcept;

      void initialize();

      static bool handshake(SSL* connection, StreamReadiness& waiting);

      void mirrorProtocol();

      static StreamResult ioFailure(SSL* connection, int result) noexcept;

      SSL* endpoint(TlsSide side) const noexcept;

      std::chrono::steady_clock::time_point offer_after_{};
      static constexpr std::size_t read_capacity = 16 * 1024;
      StreamReadBuffer<read_capacity> child_input_;
      StreamReadBuffer<read_capacity> origin_input_;

      tbc::view<const TlsContexts&, tbc::lt::a> contexts_;
      tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority_;
      TunnelSockets sockets_;
      FixedText<ProxyHostname::maximum_bytes> hostname_;
      bool offered_;
      tbc::view<ds::Box<AlpnOffer, ConcurrentMemory>, tbc::lt::a> offer_;
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
      explicit TlsInterception(tbc::view<const TlsContexts&, tbc::lt::a> contexts, tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority) noexcept;

      // `offer` is the child's ClientHello when the caller already read it complete, or null.
      tbc::view<ds::Box<TlsSession, ConcurrentMemory>, tbc::lt::a> open(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, TunnelSockets sockets, std::string_view hostname, tbc::view<ds::Box<AlpnOffer, ConcurrentMemory>, tbc::lt::a> offer) const;

      tbc::view<ds::Box<TlsSession, ConcurrentMemory>, tbc::lt::a> open(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, TunnelSockets sockets, std::string_view hostname) const;

      tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> snapshot() const noexcept;

      void replace(tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority) noexcept;

      void suspend(bool value) noexcept;

      bool suspended() const noexcept;

    private:
      tbc::view<const TlsContexts&, tbc::lt::a> contexts_;
      mutable std::mutex mutex_;
      tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> replacement_;
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
