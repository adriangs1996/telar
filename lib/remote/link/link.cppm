export module telar.remote.link;

// The gateway of an account on the machine its clients run on: one process that calls the
// gateways of other machines, and gives the windows and commands here a local socket for each
// machine's runtime and a local port for each port a machine shares.
import std;

import telar.base.ds;
import telar.base.memory.containers;
import telar.platform.paths;
import telar.platform.primitives;
import telar.remote.channel;
import telar.remote.identity;
import telar.remote.streams;
import telar.sys.posix;
import telar.sys.socket;

// Interface: telar_remote/link_paths.cppm
export {
  namespace telar::remote {

    using SocketPath = runtime::FixedText<sizeof(sockaddr_un::sun_path)>;

    // Where the link's sockets live: beside the runtime's socket, in the account's own directory.
    struct LinkPaths {
      runtime::FixedText<PATH_MAX> directory;

      [[nodiscard]] static LinkPaths resolve(const runtime::EnvironmentSource& environment);

      // The socket the link takes its requests on.
      [[nodiscard]] SocketPath control() const;

      // The socket that is the runtime of the machine at `destination`.
      [[nodiscard]] SocketPath machine(std::string_view destination) const;
    };

  }
}

// Interface: telar_remote/link.cppm
export {
  namespace telar::remote {

    class Link {
    public:
      static constexpr std::size_t maximum_machines = 16;
      static constexpr std::size_t maximum_forwards = 64;
      static constexpr std::size_t origin_bytes = 96;

      // Binds the control socket; throws SystemError when another link already serves `paths`.
      explicit Link(const State& state, const LinkPaths& paths);
      ~Link();

      Link(const Link&) = delete;
      Link& operator=(const Link&) = delete;
      Link(Link&&) = delete;
      Link& operator=(Link&&) = delete;

      // Serves requests and connections until `stop`, each on a thread of its own.
      void run() noexcept;

      // Ends `run` from another thread or a signal handler.
      void stop() noexcept;

    private:
      // A machine whose runtime the link offers on a local socket.
      struct Machine {
        Endpoint endpoint;
        runtime::FileDescriptor listener;
        bool used = false;
      };

      // A port of a machine offered on a port of this one.
      struct Forward {
        Endpoint endpoint;
        runtime::FixedText<origin_bytes> origin;
        runtime::FileDescriptor listener;
        runtime::FileDescriptor listener_six;
        std::uint16_t remote = 0;
        std::uint16_t local = 0;
        unsigned holders = 0;
        unsigned connections = 0;
        // Bumped each time the slot is given to another forward, so a holder knows its own.
        unsigned generation = 0;
        bool used = false;
      };

      enum class Role : std::uint8_t {
        control,
        machine,
        forward,
      };

      struct Accepted {
        Role role = Role::control;
        std::size_t index = 0;
        unsigned generation = 0;
      };

      void answer(runtime::FileDescriptor socket, Accepted accepted) noexcept;
      void control(int socket);
      void attach(int socket, std::size_t machine);
      void carry(int socket, std::size_t forward, unsigned generation);

      void requestSocket(int socket, std::string_view destination);
      void requestForward(int socket, std::string_view arguments);
      void requestPorts(int socket, std::string_view destination);

      [[nodiscard]] ds::Option<std::size_t> openForward(const Endpoint& endpoint, std::uint16_t port, std::string_view origin);
      void releaseForward(std::size_t index, unsigned generation, bool closed_there) noexcept;
      void wake() noexcept;

      const State& state_;
      LinkPaths paths_;
      Identity identity_;
      Contexts contexts_;
      runtime::FileDescriptor control_;
      std::mutex mutex_;
      ds::Array<Machine, maximum_machines> machines_;
      ds::Array<Forward, maximum_forwards> forwards_;
      ds::Array<int, 2> wake_{-1, -1};
      std::atomic<unsigned> threads_{0};
      std::atomic<bool> stopping_{false};
    };

  }
}

// Interface: telar_remote/link_client.cppm
export {
  namespace telar::remote {

    // What a program on this machine asks of the link. Each call connects to the control socket
    // of `paths`, which a link must already serve.
    struct LinkClient {
      static constexpr std::size_t line_bytes = 1024;

      // Whether a link answers on `paths`.
      [[nodiscard]] static bool running(const LinkPaths& paths) noexcept;

      // The local socket that is the runtime of the machine at `destination`. Throws
      // ChannelFailure with what the link said.
      [[nodiscard]] static SocketPath socket(const LinkPaths& paths, std::string_view destination);

      // Asks for a local port to a port of a machine, writes `PORT\n` to `output` and holds the
      // forward until this process ends or the port closes there. Returns 0 when it closed
      // there, 1 when the link refused.
      [[nodiscard]] static int forward(const LinkPaths& paths, std::string_view destination, std::uint16_t port, std::string_view origin, int output);

      // Writes to `output` a line for each forward to the machine: its port there, its port
      // here, its open connections and what asked for it.
      [[nodiscard]] static int ports(const LinkPaths& paths, std::string_view destination, int output);

      // Asks the link to end.
      static void stop(const LinkPaths& paths) noexcept;
    };

  }
}

// Interface: telar_remote/remote_command.cppm
export {
  namespace telar::remote {

    // What to run on another machine, and the descriptors its streams are carried on here.
    struct RemoteCommand {
      std::string_view destination;
      std::string_view command;
      bool terminal = false;
      LocalStreams streams;
    };

    // Runs a command in the shell of the account at its destination and returns its exit status.
    // A connection that fails says so on the error stream and returns 255, as ssh does.
    [[nodiscard]] int runRemote(const State& state, const RemoteCommand& remote) noexcept;

    // Carries the runtime of the account at `destination` on `socket`, a stream socket of this
    // process such as the one a window hands it as its standard streams, until either side ends.
    // Returns 0 for a connection that was made, and 255 or 1, saying why on the error stream,
    // for a gateway that cannot be reached or a runtime that cannot be started.
    [[nodiscard]] int attachRemote(const State& state, std::string_view destination, int socket) noexcept;

    // Presents a pairing address to its gateway under `name`, and returns the address to save.
    // Throws ChannelFailure when the gateway refuses, and std::invalid_argument for an address
    // without a pairing code.
    [[nodiscard]] Endpoint::Text enroll(const State& state, std::string_view address, std::string_view name);

  }
}
