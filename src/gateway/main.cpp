#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.text;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.paths;
import telar.platform.primitives;
import telar.platform.process;
import telar.remote.channel;
import telar.remote.identity;
import telar.remote.link;
import telar.remote.serve;
import telar.sys.posix;
import telar.sys.process;
import telar.tbc;
import telar.tls;

namespace telar::remote {
  namespace {

    constexpr std::string_view usage =
        "telar-gateway: the connection between telar on two machines\n"
        "\n"
        "Usage: telar-gateway COMMAND [ARGS...]\n"
        "\n"
        "On the machine clients reach:\n"
        "  serve [--listen [HOST]:PORT] [--runtime-socket PATH]\n"
        "                    Answer clients until stopped\n"
        "  pair [--host HOST] [--port PORT]\n"
        "                    Print an address that pairs one client, once, within ten minutes\n"
        "  clients           List the clients this account's gateway admits\n"
        "  revoke KEY|NAME   Stop admitting a client\n"
        "\n"
        "On the machine a client runs on:\n"
        "  enroll ADDRESS [--name NAME]\n"
        "                    Pair with the gateway a pairing address names; print the address to save\n"
        "  run [-t] [--share] [--to ADDRESS] ADDRESS COMMAND\n"
        "                    Run a shell command there with this process's streams; with --share,\n"
        "                    forward here the ports that machine shares while it runs\n"
        "  attach ADDRESS    Carry the runtime there on the socket given as standard input, and\n"
        "                    forward here the ports that machine shares meanwhile\n"
        "  socket ADDRESS    Print the local socket that is the runtime there\n"
        "  forward ADDRESS PORT [ORIGIN]\n"
        "                    Print a local port to a port there, and hold it until stopped\n"
        "  ports ADDRESS     List the ports forwarded from there\n"
        "  link              Serve the local sockets and ports; started when one is first asked for\n"
        "  stop-link         End the link\n"
        "\n"
        "  key               Print the key this account presents\n";

    constexpr auto link_start_window = std::chrono::seconds{5};
    constexpr auto poll_interval = std::chrono::milliseconds{10};
    constexpr int usage_status = 2;
    // Room for the name of the log a link starts with, after its directory.
    constexpr std::size_t log_name_bytes = 32;

    // What a signal ends: the server or the link this process runs.
    std::atomic<void (*)() noexcept> stop_running{nullptr}; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): a signal handler reaches only a global

    void onSignal(int /*number*/) noexcept {
      if (const auto stop = stop_running.load()) {
        stop();
      }
    }

    void print(int descriptor, std::string_view text) noexcept {
      while (!text.empty()) {
        const auto written = ::write(descriptor, text.data(), text.size());
        if (written <= 0) {
          return;
        }

        text.remove_prefix(static_cast<std::size_t>(written));
      }
    }

    // The value after the option at `index`, which it steps to.
    tbc::val_a<std::string_view> valueOf(tbc::val_a<std::span<char* const>> arguments, std::size_t& index) {
      if (index + 1 >= arguments.size()) {
        throw std::invalid_argument{"an option is missing its value"};
      }

      return arguments[++index];
    }

    // Runs until a signal or a request stops it, then leaves without waiting for the
    // connections still open: the process ends with them.
    template <typename Service>
    [[noreturn]] void runUntilStopped(Service& service) {
      static Service* running = nullptr;

      running = &service;
      stop_running.store([] noexcept {
        running->stop();
      });

      if (::signal(SIGTERM, &onSignal) == SIG_ERR || ::signal(SIGINT, &onSignal) == SIG_ERR) {
        throw runtime::SystemError{"Handle the signals that stop the gateway"};
      }

      service.run();
      ::_exit(0);
    }

    int serve(ConcurrentMemory& memory, const State& state, std::span<char* const> arguments) {
      ServeOptions options;

      for (std::size_t index = 0; index < arguments.size(); ++index) {
        const std::string_view argument{arguments[index]};
        if (argument == "--listen") {
          const auto address = valueOf(arguments, index);
          const auto colon = address.rfind(':');
          const auto port = runtime::unsignedDecimal<std::uint16_t>(address.substr(colon == std::string_view::npos ? 0 : colon + 1));
          if (!port) {
            throw std::invalid_argument{"--listen takes [HOST]:PORT"};
          }

          options.port = *port;
          options.host = colon == std::string_view::npos ? std::string_view{} : runtime::trimText(address.substr(0, colon), "[]");
        } else if (argument == "--runtime-socket") {
          options.runtime_socket = valueOf(arguments, index);
        } else {
          throw std::invalid_argument{"serve takes --listen [HOST]:PORT and --runtime-socket PATH"};
        }
      }

      Server server{memory, state, options};
      const auto key = keyText(server.key());

      std::println(stderr, "telar-gateway: listening on port {} with key {}", server.port(), std::string_view{key.data(), key.size()});
      runUntilStopped(server);
    }

    int pair(const State& state, std::span<char* const> arguments) {
      ds::Array<char, Endpoint::host_bytes + 1> name{};
      Endpoint endpoint;

      static_cast<void>(::gethostname(name.dataMut(), name.size() - 1));
      std::string_view host{name.data()};

      ds::Option<std::uint16_t> port = state.port();

      for (std::size_t index = 0; index < arguments.size(); ++index) {
        const std::string_view argument{arguments[index]};
        if (argument == "--host") {
          host = valueOf(arguments, index);
        } else if (argument == "--port") {
          port = runtime::unsignedDecimal<std::uint16_t>(valueOf(arguments, index));
        } else {
          throw std::invalid_argument{"pair takes --host HOST and --port PORT"};
        }
      }

      endpoint.host.assign(host);
      endpoint.port = port.valueOr(default_port);
      endpoint.key = Identity::loadOrCreate(state.directory()).key;
      endpoint.secret = PairingCodes::mint(state.directory());
      std::println("{}", endpoint.format().view());
      return 0;
    }

    int clients(const State& state) {
      for (const auto& client : AuthorizedClients::load(state.directory()).rows()) {
        const auto key = keyText(client.key);

        std::println("{}\t{}", std::string_view{key.data(), key.size()}, client.name.view());
      }

      return 0;
    }

    int revoke(const State& state, std::span<char* const> arguments) {
      if (arguments.size() != 1) {
        throw std::invalid_argument{"revoke takes the key or the name of one client"};
      }

      const StateLock lock{state.directory()};
      auto admitted = AuthorizedClients::load(state.directory());
      const auto removed = admitted.revoke(arguments.front());

      admitted.save(state.directory());
      std::println("{}", removed);
      return removed == 0 ? 1 : 0;
    }

    int enrollClient(const State& state, std::span<char* const> arguments) {
      ds::Array<char, AuthorizedClients::name_bytes + 1> host{};
      std::string_view address;

      static_cast<void>(::gethostname(host.dataMut(), host.size() - 1));
      std::string_view name{host.data()};

      for (std::size_t index = 0; index < arguments.size(); ++index) {
        const std::string_view argument{arguments[index]};
        if (argument == "--name") {
          name = valueOf(arguments, index);
        } else if (address.empty()) {
          address = argument;
        } else {
          throw std::invalid_argument{"enroll takes one pairing address"};
        }
      }

      std::println("{}", enroll(state, {.address = address, .name = name}).view());
      return 0;
    }

    void ensureLink(const LinkPaths& paths);

    // Holds the machine at `destination` in the link, so that the ports it shares are forwarded
    // here while the descriptor stays open. Forwarding is a convenience: a link that cannot be
    // started or reached leaves the command it accompanies to run without it.
    runtime::FileDescriptor holdMachine(std::string_view destination) noexcept {
      try {
        const auto paths = LinkPaths::resolve(runtime::process_environment);

        ensureLink(paths);
        return LinkClient::hold(paths, destination);
      } catch (const std::exception&) {
        return runtime::FileDescriptor{};
      }
    }

    int run(const State& state, std::span<char* const> arguments) {
      RemoteCommand remote;
      std::size_t index = 0;
      bool share = false;

      for (; index < arguments.size(); ++index) {
        const std::string_view argument{arguments[index]};
        if (argument == "-t") {
          remote.terminal = true;
        } else if (argument == "--share") {
          share = true;
        } else if (argument == "--to") {
          remote.destination = valueOf(arguments, index);
        } else {
          break;
        }
      }

      // With --to, the address a caller such as Git puts first names nothing and is passed over.
      const auto rest = arguments.subspan(index);
      if (rest.size() != 2) {
        throw std::invalid_argument{"run takes an address and one command line"};
      }

      if (remote.destination.empty()) {
        remote.destination = rest[0];
      }

      remote.command = rest[1];
      const auto held = share ? holdMachine(remote.destination) : runtime::FileDescriptor{};
      ds::Option<LinkPaths> paths;

      // The link may hold a connection to the machine already; a link that cannot be started
      // only means the command connects by itself.
      try {
        paths.emplace(LinkPaths::resolve(runtime::process_environment));
        ensureLink(*paths);
        remote.link = &paths.get();
      } catch (const std::exception&) {
        remote.link = nullptr;
      }

      return runRemote(state, remote);
    }

    // Starts the link when none answers, and waits until it does.
    void ensureLink(const LinkPaths& paths) {
      if (LinkClient::running(paths)) {
        return;
      }

      const runtime::ExecutablePath self;
      ds::Array<char, PATH_MAX + log_name_bytes> log{};
      auto command = ds::toArray("link");
      const ds::Array<char*, 3> arguments{const_cast<char*>(self.cStr()), command.dataMut(), nullptr}; // NOLINT(cppcoreguidelines-pro-type-const-cast): posix_spawn's C signature takes the arguments as char*, and does not write them

      std::format_to_n(log.dataMut(), log.size() - 1, "{}/gateway.start.log", paths.directory.view());
      static_cast<void>(runtime::cli::spawnDaemon(self.cStr(), arguments.data(), log.data()));
      const auto deadline = Clock::now() + link_start_window;

      while (!LinkClient::running(paths)) {
        if (Clock::now() >= deadline) {
          throw runtime::SystemError{"Start the gateway link; see gateway.start.log beside the runtime socket", ETIMEDOUT};
        }

        std::this_thread::sleep_for(poll_interval);
      }
    }

    int link(const State& state, const LinkPaths& paths) {
      Link service{state, paths};

      runUntilStopped(service);
    }

    int forward(const LinkPaths& paths, std::span<char* const> arguments) {
      const auto port = arguments.size() < 2 ? ds::none : runtime::unsignedDecimal<std::uint16_t>(arguments[1]);
      if (!port || arguments.size() > 3) {
        throw std::invalid_argument{"forward takes an address, a port and what asks for it"};
      }

      ensureLink(paths);
      return LinkClient::forward(paths, arguments[0], *port, arguments.size() == 3 ? std::string_view{arguments[2]} : std::string_view{"telar"}, STDOUT_FILENO);
    }

    int dispatch(ConcurrentMemory& memory, std::span<char* const> words) {
      if (words.empty() || std::string_view{words.front()} == "--help" || std::string_view{words.front()} == "-h") {
        print(STDOUT_FILENO, usage);
        return words.empty() ? usage_status : 0;
      }

      const std::string_view command{words.front()};
      const auto arguments = words.subspan(1);
      const auto state = State::open(runtime::process_environment);
      const auto single = [&] -> std::string_view {
        if (arguments.size() != 1) {
          throw std::invalid_argument{"the command takes one address"};
        }

        return arguments.front();
      };

      if (command == "serve") {
        return serve(memory, state, arguments);
      }

      if (command == "pair") {
        return pair(state, arguments);
      }

      if (command == "clients") {
        return clients(state);
      }

      if (command == "revoke") {
        return revoke(state, arguments);
      }

      if (command == "enroll") {
        return enrollClient(state, arguments);
      }

      if (command == "run") {
        return run(state, arguments);
      }

      if (command == "attach") {
        const auto destination = single();
        const auto held = holdMachine(destination);

        return attachRemote(state, destination, STDIN_FILENO);
      }

      if (command == "key") {
        const auto key = keyText(Identity::loadOrCreate(state.directory()).key);

        std::println("{}", std::string_view{key.data(), key.size()});
        return 0;
      }

      const auto paths = LinkPaths::resolve(runtime::process_environment);

      if (command == "link") {
        return link(state, paths);
      }

      if (command == "stop-link") {
        LinkClient::stop(paths);
        return 0;
      }

      if (command == "socket") {
        const auto destination = single();

        ensureLink(paths);
        std::println("{}", LinkClient::socket(paths, destination).view());
        return 0;
      }

      if (command == "forward") {
        return forward(paths, arguments);
      }

      if (command == "ports") {
        const auto destination = single();

        return LinkClient::running(paths) ? LinkClient::ports(paths, destination, STDOUT_FILENO) : 0;
      }

      throw std::invalid_argument{"unknown command"};
    }

    // Prints the failure that ended a command on stderr, as each kind of failure reads, and
    // returns the status the process ends with.
    int reportFailure(const std::exception& error) {
      if (dynamic_cast<const std::invalid_argument*>(&error) != nullptr) {
        std::println(stderr, "telar-gateway: {}; see `telar-gateway --help`", error.what());
        return usage_status;
      }

      if (const auto* system = dynamic_cast<const runtime::SystemError*>(&error)) {
        std::println(stderr, "telar-gateway: {}: {}", error.what(), std::system_category().message(system->code()));
      } else {
        std::println(stderr, "telar-gateway: {}", error.what());
      }

      return 1;
    }

  }
}

auto main(int argc, char** argv) -> int {
  using namespace telar;

  // main receives its arguments as the C array and count the C runtime gives it.
#pragma clang unsafe_buffer_usage begin
  const std::span<char* const> words = std::span<char* const>{argv, static_cast<std::size_t>(argc)}.subspan(argc > 0 ? 1 : 0);
#pragma clang unsafe_buffer_usage end

  try {
    SystemAllocator system;
    SynchronizedAllocator synchronized{system};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    const runtime::TlsLibrary library{memory};

    // A peer that closes its connection must fail the write that finds out, not end the process.
    if (::signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
      throw runtime::SystemError{"Ignore the signal of a closed connection"};
    }

    return remote::dispatch(memory, words);
  } catch (const std::exception& error) {
    try {
      return remote::reportFailure(error);
    } catch (const std::exception&) {
      // stderr refused the report too, and nothing is left to tell it to.
      return 1;
    }
  }
}
