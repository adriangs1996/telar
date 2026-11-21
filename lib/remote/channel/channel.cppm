export module telar.remote.channel;

// The connection between two gateways: TLS 1.3 over TCP in which each end presents its key and
// names the other by it, and the service the client asks of the server.
import std;

import telar.base.ds;
import telar.platform.primitives;
import telar.remote.identity;
import telar.sys.socket;
import telar.tls;

// Interface: telar_remote/service.cppm
export {
  namespace telar::remote {

    // What a client asks of a gateway, named in the handshake by its ALPN protocol.
    enum class Service : std::uint8_t {
      // The bytes of the account's runtime socket.
      attach,
      // A command of the account, with its streams and its exit status.
      run,
      // A TCP connection to a port of the gateway's own machine.
      forward,
      // The ports the gateway shares, as they open and close.
      ports,
      // Enrolling the client that carries a pairing code.
      pair,
    };

    inline constexpr std::size_t service_count = 5;

    [[nodiscard]] std::string_view serviceName(Service service) noexcept;
    [[nodiscard]] ds::Option<Service> namedService(std::string_view name) noexcept;

  }
}

// Interface: telar_remote/failure.cppm
export {
  namespace telar::remote {

    // A connection that could not be made or kept. Its text is a literal that says what failed.
    class ChannelFailure final : public std::exception {
    public:
      explicit ChannelFailure(const char* what) noexcept;

      [[nodiscard]] const char* what() const noexcept override;

    private:
      const char* what_;
    };

  }
}

// Interface: telar_remote/sockets.cppm
export {
  namespace telar::remote {

    using Clock = std::chrono::steady_clock;

    // The time left until `deadline` as poll takes it, never negative.
    [[nodiscard]] int pollTimeout(Clock::time_point deadline) noexcept;

    // A TCP socket listening on `host`, or on every address when it is empty, and the port it
    // got. Throws SystemError.
    struct Listener {
      runtime::FileDescriptor socket;
      std::uint16_t port = 0;
    };

    [[nodiscard]] Listener listenTcp(std::string_view host, std::uint16_t port);

    // A connected, nonblocking TCP socket, none when no address of the host answers in time.
    [[nodiscard]] runtime::FileDescriptor connectTcp(std::string_view host, std::uint16_t port, Clock::time_point deadline) noexcept;

    // A connection to a port of this machine, over IPv6 or IPv4, whichever listens.
    [[nodiscard]] runtime::FileDescriptor connectLoopback(std::uint16_t port, Clock::time_point deadline) noexcept;

    // A Unix socket listening at `path`, for its owner alone, replacing a socket nobody
    // listens on. Throws SystemError.
    [[nodiscard]] runtime::FileDescriptor listenUnix(std::string_view path);

    // A connected, nonblocking Unix socket; none when nothing listens at `path`.
    [[nodiscard]] runtime::FileDescriptor connectUnix(std::string_view path) noexcept;

    // The connection `listener` has waiting, nonblocking and closed in children; none when it
    // has none.
    [[nodiscard]] runtime::FileDescriptor acceptConnection(int listener) noexcept;

  }
}

// Interface: telar_remote/channel.cppm
export {
  namespace telar::remote {

    // The two TLS configurations an identity takes part with: as the gateway that answers and
    // as the client that calls.
    class Contexts {
    public:
      explicit Contexts(const Identity& identity);

      [[nodiscard]] SSL_CTX* server() const noexcept;
      [[nodiscard]] SSL_CTX* client() const noexcept;

    private:
      runtime::TlsContext server_;
      runtime::TlsContext client_;
    };

    // What one nonblocking step of a channel did.
    struct Transfer {
      enum class State : std::uint8_t {
        done,
        wants_read,
        wants_write,
        ended,
        failed,
      };

      State state = State::done;
      std::size_t bytes = 0;
    };

    // An established connection: the handshake is over, the service agreed and the peer's key
    // known. Whether that key may use the service is for the caller to decide.
    class Channel {
    public:
      // Answers the client on `socket`. Throws ChannelFailure.
      [[nodiscard]] static Channel accept(const Contexts& contexts, runtime::FileDescriptor socket, Clock::time_point deadline);

      // Calls the gateway at `endpoint` for `service` and checks it holds the endpoint's key.
      // Throws ChannelFailure.
      [[nodiscard]] static Channel dial(const Contexts& contexts, const Endpoint& endpoint, Service service, Clock::time_point deadline);

      [[nodiscard]] Service service() const noexcept;
      [[nodiscard]] const PublicKey& peer() const noexcept;
      [[nodiscard]] int descriptor() const noexcept;

      // Whole buffers, waiting until `deadline`: for the few bytes a service exchanges before
      // it streams. They throw ChannelFailure.
      void send(std::span<const std::uint8_t> bytes, Clock::time_point deadline);
      void receive(std::span<std::uint8_t> bytes, Clock::time_point deadline);

      // One step each, never waiting.
      [[nodiscard]] Transfer read(std::span<std::uint8_t> bytes) noexcept;
      [[nodiscard]] Transfer write(std::span<const std::uint8_t> bytes) noexcept;

      // Tells the peer this end sends no more; what the peer sends can still be read.
      [[nodiscard]] Transfer finish() noexcept;

      // Whether decrypted bytes wait to be read, which the socket's readiness does not show.
      [[nodiscard]] bool buffered() const noexcept;

    private:
      Channel(runtime::FileDescriptor socket, runtime::TlsConnection connection) noexcept;

      void handshake(Clock::time_point deadline);
      void identifyPeer();
      [[nodiscard]] Transfer result(int status, std::size_t bytes) noexcept;

      runtime::FileDescriptor socket_;
      runtime::TlsConnection connection_;
      PublicKey peer_{};
      Service service_ = Service::attach;
    };

    // Carries bytes both ways between a channel and a nonblocking stream socket until each
    // direction has ended, or either fails. An end one side reaches is passed on to the other.
    void relay(Channel& channel, int local) noexcept;

  }
}

// Interface: telar_remote/reply.cppm
export {
  namespace telar::remote {

    // How a gateway answers the request that opens a service, before the service streams.
    enum class Reply : std::uint8_t {
      accepted = 0,
      refused = 1,
      unavailable = 2,
    };

    inline constexpr auto exchange_timeout = std::chrono::seconds{10};

    void sendReply(Channel& channel, Reply reply);
    [[nodiscard]] Reply receiveReply(Channel& channel);

  }
}
