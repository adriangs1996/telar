export module telar.remote.serve;

// The gateway of an account on the machine clients reach: it answers on a TCP port, admits the
// clients the account paired, and gives each the service it asks for.
import std;

import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.primitives;
import telar.remote.channel;
import telar.remote.identity;
import telar.sys.posix;

// Interface: telar_remote/server.cppm
export {
  namespace telar::remote {

    struct ServeOptions {
      // The address to listen on; every address of the machine when empty.
      std::string_view host;
      std::uint16_t port = default_port;
      // The runtime's socket, for a runtime that is not the account's default one.
      std::string_view runtime_socket;
    };

    class Server {
    public:
      // The most connections answered at once, and of those the most not admitted yet, from
      // their acceptance until their client is admitted or their pairing ended: a client that is
      // not admitted cannot take the places of those that are, and one address holds a few of
      // the places at most, so that it cannot keep every other client out.
      static constexpr unsigned maximum_connections = 256;
      static constexpr unsigned maximum_handshakes = 32;
      static constexpr unsigned maximum_handshakes_per_source = 8;
      static constexpr auto handshake_timeout = std::chrono::seconds{10};

      // The most ports programs of this machine share with every client at once.
      static constexpr std::size_t maximum_shared = 64;
      static constexpr std::size_t maximum_listening = 512;

      // The name, beside the runtime's socket, of the socket a program of this machine asks on
      // for one of its ports to be shared: `share PORT ORIGIN` and `unshare PORT`, a line
      // each, answered `ok` or `refused`. What it shared ends with its connection.
      static constexpr std::string_view sharing_socket = "gateway-ports.sock";

      // Binds the listener and records its port in `state`, which the server borrows.
      explicit Server(ConcurrentMemory& memory, const State& state, const ServeOptions& options);
      ~Server();

      Server(const Server&) = delete;
      Server& operator=(const Server&) = delete;
      Server(Server&&) = delete;
      Server& operator=(Server&&) = delete;

      [[nodiscard]] std::uint16_t port() const noexcept;
      [[nodiscard]] const PublicKey& key() const noexcept;

      // Answers clients until `stop`, each on a thread of its own.
      void run() noexcept;

      // Ends `run` from another thread or a signal handler.
      void stop() noexcept;

    private:
      // The address a connection comes from, by which the places in the handshake are counted.
      struct Source {
        ds::Array<std::uint8_t, 16> address{};
        std::size_t length = 0;

        [[nodiscard]] static Source of(int socket) noexcept;
        [[nodiscard]] bool operator==(const Source&) const noexcept = default;
      };

      // A place among the connections not admitted yet, held until its client is admitted or the
      // connection ends.
      class HandshakePlace {
      public:
        HandshakePlace(Server& server, const Source& source) noexcept;
        ~HandshakePlace();

        HandshakePlace(const HandshakePlace&) = delete;
        HandshakePlace& operator=(const HandshakePlace&) = delete;
        HandshakePlace(HandshakePlace&&) = delete;
        HandshakePlace& operator=(HandshakePlace&&) = delete;

        void leave() noexcept;

      private:
        Server& server_;
        Source source_;
        bool held_ = true;
      };

      // Takes a place for a connection from `source`; false when none is left for it.
      [[nodiscard]] bool enterHandshake(const Source& source) noexcept;
      void leaveHandshake(const Source& source) noexcept;

      // A channel that serves an admitted client, in the list of those a revocation cuts while it
      // serves.
      class LiveChannel {
      public:
        LiveChannel(Server& server, const Channel& channel) noexcept;
        ~LiveChannel();

        LiveChannel(const LiveChannel&) = delete;
        LiveChannel& operator=(const LiveChannel&) = delete;
        LiveChannel(LiveChannel&&) = delete;
        LiveChannel& operator=(LiveChannel&&) = delete;

      private:
        Server& server_;
        int descriptor_;
      };

      // Once a second, when the list of clients changed, shuts the channels of those it no longer
      // admits: what they relay waits on them without end.
      void cutRevoked() noexcept;

      // Hand each connection waiting on the TCP listener, and on the sharing socket, to a thread
      // of its own.
      void admitClients() noexcept;
      void admitPrograms() noexcept;

      void answer(runtime::FileDescriptor socket, const Source& source) noexcept;
      void serve(Channel& channel, HandshakePlace& place);
      void attach(Channel& channel);
      void runCommand(Channel& channel);
      static void forward(Channel& channel);
      void pair(Channel& channel);
      void ports(Channel& channel);
      void share(runtime::FileDescriptor socket) noexcept;
      [[nodiscard]] bool listening(std::uint16_t port) noexcept;
      // The same for a port a client asks about for the first time, which may have opened after
      // the list of listening ports was last read: one missing from the list is looked for again.
      [[nodiscard]] bool listeningNow(std::uint16_t port) noexcept;

      // What a program of this machine asks on the sharing socket: to share a port, or to stop.
      struct SharingRequest {
        // Zero when the line names no port.
        std::uint16_t port = 0;
        std::string_view origin;
        bool sharing = false;

        [[nodiscard]] static SharingRequest parse(std::string_view line) noexcept;
      };

      // Shares or withdraws a port for the connection `owner` numbers; false for a port another
      // connection shares.
      [[nodiscard]] bool recordSharing(unsigned owner, const SharingRequest& request) noexcept;

      // The ports a client of the ports service is kept told about.
      struct PortList {
        ds::Array<std::uint16_t, maximum_shared> ports{};
        std::size_t count = 0;

        void forget(std::uint16_t port) noexcept;
      };

      // Tells a client which of the ports it was told to forward closed, and which ports this
      // machine shares since.
      void tellShared(Channel& channel, PortList& told);
      [[nodiscard]] runtime::FileDescriptor connectRuntime() const noexcept;
      void startRuntime() const noexcept;

      ConcurrentMemory& memory_;
      const State& state_;
      Identity identity_;
      Contexts contexts_;
      Listener listener_;
      runtime::FixedText<PATH_MAX> runtime_socket_;
      bool explicit_runtime_socket_ = false;

      // A port a program of this machine shares, and the connection that asked for it.
      struct Shared {
        runtime::FixedText<PortNotice::origin_bytes> origin;
        unsigned owner = 0;
        std::uint16_t port = 0;
        bool used = false;
      };

      runtime::FileDescriptor sharing_;
      std::mutex mutex_;
      ds::Array<Shared, maximum_shared> shared_;
      // The ports this account listens on, as last read, and when: several clients watch them
      // and the system is asked once a second for all.
      ds::Array<std::uint16_t, maximum_listening> listening_{};
      std::size_t listening_count_ = 0;
      Clock::time_point listening_read_;
      unsigned owners_ = 0;
      ds::Array<int, 2> wake_{-1, -1};

      // The connections not admitted yet, by the address they come from, under the mutex.
      struct Handshakes {
        Source source;
        unsigned count = 0;
      };

      ds::Array<Handshakes, maximum_handshakes> handshaking_;
      unsigned handshakes_ = 0;

      // The channels serving admitted clients, under the mutex; a channel leaves before it closes.
      struct Live {
        PublicKey peer{};
        int descriptor = -1;
      };

      ds::Array<Live, maximum_connections> live_;
      AuthorizedClients::Stamp clients_stamp_;
      Clock::time_point clients_checked_;
      std::atomic<unsigned> connections_{0};
      std::atomic<bool> stopping_{false};
    };

  }
}
