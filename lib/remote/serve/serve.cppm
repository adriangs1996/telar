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
      // The most connections answered at once, and of those the most still in their handshake:
      // a client that is not admitted yet cannot take the places of those that are.
      static constexpr unsigned maximum_connections = 256;
      static constexpr unsigned maximum_handshakes = 32;
      static constexpr auto handshake_timeout = std::chrono::seconds{10};

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
      void answer(runtime::FileDescriptor socket) noexcept;
      void serve(Channel& channel);
      void attach(Channel& channel);
      void runCommand(Channel& channel);
      void forward(Channel& channel);
      void pair(Channel& channel);
      [[nodiscard]] runtime::FileDescriptor connectRuntime() const noexcept;
      void startRuntime() const noexcept;

      ConcurrentMemory& memory_;
      const State& state_;
      Identity identity_;
      Contexts contexts_;
      Listener listener_;
      runtime::FixedText<PATH_MAX> runtime_socket_;
      bool explicit_runtime_socket_ = false;
      ds::Array<int, 2> wake_{-1, -1};
      std::atomic<unsigned> connections_{0};
      std::atomic<unsigned> handshakes_{0};
      std::atomic<bool> stopping_{false};
    };

  }
}
