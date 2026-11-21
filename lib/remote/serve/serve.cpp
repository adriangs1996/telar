module telar.remote.serve;

import telar.platform.error;
import telar.platform.paths;
import telar.platform.process;
import telar.platform.thread;
import telar.remote.streams;
import telar.sys.process;

namespace telar::remote {

  using runtime::FileDescriptor;
  using runtime::SystemError;

  namespace {

    constexpr auto forward_connect_timeout = std::chrono::seconds{3};
    constexpr auto runtime_start_timeout = std::chrono::seconds{15};
    constexpr auto refusal_delay = std::chrono::seconds{1};
    constexpr auto poll_interval = std::chrono::milliseconds{5};
    constexpr unsigned byte_bits = 8;

    // A path with the terminator the system calls need.
    using PathText = ds::Array<char, PATH_MAX + 1>;

    PathText terminated(std::string_view path) noexcept {
      PathText text{};

      std::ranges::copy(path.substr(0, PATH_MAX), text.viewMut().begin());
      return text;
    }

    // The programs a client runs find `telar` on their PATH, wherever this gateway's service
    // manager started it from: the directory of this executable goes first.
    void exposeSiblings() {
      const runtime::ExecutablePath self;
      const auto directory = self.view().substr(0, self.view().rfind('/'));
      const auto current = runtime::process_environment.lookup("PATH");
      ds::Array<char, (2 * PATH_MAX) + 2> path{};
      const std::string_view fallback = "/usr/local/bin:/usr/bin:/bin";
      const auto rest = current.empty() ? fallback : current;

      if (directory.empty() || directory.size() + rest.size() + 2 > path.size()) {
        return;
      }

      auto end = std::ranges::copy(directory, path.viewMut().begin()).out;

      *end++ = ':';
      std::ranges::copy(rest, end);
      static_cast<void>(::setenv("PATH", path.data(), 1)); // NOLINT(concurrency-mt-unsafe): set once, before the gateway starts a thread
    }

    // Says no, and waits for the client to read it before the connection goes.
    void refuse(Channel& channel, Reply reply = Reply::refused) noexcept {
      try {
        sendReply(channel, reply);
      } catch (const std::exception&) {
        // The client left first, which is as good as told.
        return;
      }

      conclude(channel);
    }

    // The environment a command on a terminal starts with: the gateway's own, naming a terminal
    // type when it names none.
    class TerminalEnvironment {
    public:
      explicit TerminalEnvironment(ConcurrentMemory& memory)
          : entries_(memory) {
        bool named = false;

        // The environment block ends at its null entry.
#pragma clang unsafe_buffer_usage begin
        for (char** entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
          named = named || std::string_view{*entry}.starts_with("TERM=");
          entries_.push(*entry);
        }
#pragma clang unsafe_buffer_usage end

        if (!named) {
          entries_.push(term_.dataMut());
        }

        entries_.push(nullptr);
      }

      [[nodiscard]] char* const* data() const noexcept {
        return entries_.data();
      }

    private:
      ds::Array<char, 20> term_{'T', 'E', 'R', 'M', '=', 'x', 't', 'e', 'r', 'm', '-', '2', '5', '6', 'c', 'o', 'l', 'o', 'r', '\0'};
      ds::Vec<char*, ConcurrentMemory> entries_;
    };

  }

  Server::Server(ConcurrentMemory& memory, const State& state, const ServeOptions& options)
      : memory_(memory),
        state_(state),
        identity_(Identity::loadOrCreate(state.directory())),
        contexts_(identity_),
        listener_(listenTcp(options.host, options.port)) {
    runtime_socket_.assign(runtime::cli::SocketLocation::resolve(options.runtime_socket, runtime::process_environment, ::geteuid()).path());
    explicit_runtime_socket_ = !options.runtime_socket.empty();
    if (::pipe(wake_.dataMut()) != 0) {
      throw SystemError{"Create the gateway's wake pipe"};
    }

    for (const auto end : wake_) {
      runtime::setCloseOnExec(end);
      runtime::setNonblocking(end);
    }

    exposeSiblings();
    state_.recordPort(listener_.port);
  }

  Server::~Server() {
    stop();
    while (connections_.load() != 0) {
      std::this_thread::sleep_for(poll_interval);
    }

    for (const auto end : wake_) {
      ::close(end);
    }
  }

  std::uint16_t Server::port() const noexcept {
    return listener_.port;
  }

  const PublicKey& Server::key() const noexcept {
    return identity_.key;
  }

  void Server::run() noexcept {
    while (!stopping_.load()) {
      ds::Array<pollfd, 2> entries{
          pollfd{.fd = listener_.socket.get(), .events = POLLIN, .revents = 0},
          pollfd{.fd = wake_[0], .events = POLLIN, .revents = 0},
      };

      if (::poll(entries.dataMut(), entries.size(), -1) < 0 && sys::lastError() != EINTR) {
        return;
      }

      for (auto socket = acceptConnection(listener_.socket.get()); socket; socket = acceptConnection(listener_.socket.get())) {
        if (connections_.fetch_add(1) >= maximum_connections) {
          connections_.fetch_sub(1);
          continue;
        }

        try {
          // The thread owns the connection from here; the descriptor crosses as a number.
          runtime::startThread("Start a gateway connection", [this, descriptor = socket.release()] {
            answer(FileDescriptor{descriptor});
          }).detach();
        } catch (const SystemError&) {
          connections_.fetch_sub(1);
        }
      }
    }
  }

  void Server::stop() noexcept {
    const char byte = 0;

    stopping_.store(true);
    static_cast<void>(::write(wake_[1], &byte, 1));
  }

  void Server::answer(FileDescriptor socket) noexcept {
    try {
      if (handshakes_.fetch_add(1) >= maximum_handshakes) {
        handshakes_.fetch_sub(1);
        connections_.fetch_sub(1);
        return;
      }

      ds::Option<Channel> channel;

      try {
        channel.emplace(Channel::accept(contexts_, std::move(socket), Clock::now() + handshake_timeout));
      } catch (const std::exception&) {
        handshakes_.fetch_sub(1);
        connections_.fetch_sub(1);
        return;
      }

      handshakes_.fetch_sub(1);
      serve(channel.getMut());
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a connection that fails ends alone; the others go on
    }

    connections_.fetch_sub(1);
  }

  void Server::serve(Channel& channel) {
    if (channel.service() == Service::pair) {
      pair(channel);
      return;
    }

    // The list is read for every connection, so a client revoked now is refused now.
    if (!AuthorizedClients::load(state_.directory()).admits(channel.peer())) {
      refuse(channel);
      return;
    }

    switch (channel.service()) {
    case Service::attach:
      attach(channel);
      return;
    case Service::run:
      runCommand(channel);
      return;
    case Service::forward:
      forward(channel);
      return;
    case Service::ports:
    case Service::pair:
      refuse(channel, Reply::unavailable);
      return;
    }
  }

  void Server::attach(Channel& channel) {
    const auto runtime = connectRuntime();
    if (!runtime) {
      refuse(channel, Reply::unavailable);
      return;
    }

    sendReply(channel, Reply::accepted);
    relay(channel, runtime.get());
  }

  FileDescriptor Server::connectRuntime() const noexcept {
    auto socket = connectUnix(runtime_socket_.view());

    if (!socket) {
      startRuntime();
      socket = connectUnix(runtime_socket_.view());
    }

    return socket;
  }

  void Server::startRuntime() const noexcept {
    try {
      const auto program = runtime::ExecutablePath::sibling({"telar"});
      if (!program) {
        return;
      }

      auto path = terminated(program->view());
      auto socket = terminated(runtime_socket_.view());
      auto home = terminated(runtime::processHome().empty() ? std::string_view{"/"} : runtime::processHome());
      ds::Array<char, 7> server{'s', 'e', 'r', 'v', 'e', 'r', '\0'};
      ds::Array<char, 9> endpoint{'e', 'n', 'd', 'p', 'o', 'i', 'n', 't', '\0'};
      ds::Array<char, 9> option{'-', '-', 's', 'o', 'c', 'k', 'e', 't', '\0'};
      // A runtime at its default socket is started as any telar command starts it, without naming the socket.
      ds::Array<char*, 6> arguments{path.dataMut(), server.dataMut(), endpoint.dataMut(), explicit_runtime_socket_ ? option.dataMut() : nullptr, socket.dataMut(), nullptr};
      runtime::PipeProcess process{{.executable = path.data(), .cwd = home.data(), .arguments = arguments.data(), .environment = environ, .size = {}}};
      const auto deadline = Clock::now() + runtime_start_timeout;

      process.closeInput();
      while (!process.reap() && Clock::now() < deadline) {
        std::this_thread::sleep_for(poll_interval);
      }
    } catch (const std::exception&) {
      // Without a runtime the attach is answered as unavailable.
      return;
    }
  }

  void Server::runCommand(Channel& channel) {
    ds::Vec<char, ConcurrentMemory> command{memory_};
    RunRequest request;

    command.resize(RunRequest::maximum_command_bytes + 1);
    const auto text = receiveRunRequest(channel, request, command.viewMut().first(RunRequest::maximum_command_bytes));

    command.atMut(text.size()) = '\0';
    auto shell = terminated(runtime::loginShell().view());
    auto home = terminated(runtime::processHome().empty() ? std::string_view{"/"} : runtime::processHome());
    ds::Array<char, 3> flag{'-', 'c', '\0'};
    ds::Array<char*, 4> arguments{shell.dataMut(), flag.dataMut(), command.dataMut(), nullptr};
    runtime::SpawnSpec specification{
        .executable = shell.data(),
        .cwd = home.data(),
        .arguments = arguments.data(),
        .environment = environ,
        .size = {.cols = request.columns, .rows = request.rows, .cell_width_px = 0, .cell_height_px = 0},
    };

    try {
      if (request.terminal) {
        const TerminalEnvironment environment{memory_};

        specification.environment = environment.data();
        runtime::PtyProcess process{specification};

        sendReply(channel, Reply::accepted);
        pumpTerminal(channel, process);
        process.shutdown();
        conclude(channel);
        return;
      }

      runtime::PipeProcess process{specification};

      sendReply(channel, Reply::accepted);
      pumpPipes(channel, process);
      // A client that left ends its command, as a closed terminal ends what ran in it.
      process.signal(SIGHUP);
      conclude(channel);
    } catch (const SystemError&) {
      refuse(channel, Reply::unavailable);
    }
  }

  void Server::forward(Channel& channel) {
    ds::Array<std::uint8_t, 2> request{};

    channel.receive(request.viewMut(), Clock::now() + exchange_timeout);
    const auto port = static_cast<std::uint16_t>((static_cast<unsigned>(request[0]) << byte_bits) | request[1]);
    const auto target = connectLoopback(port, Clock::now() + forward_connect_timeout);
    if (!target) {
      refuse(channel);
      return;
    }

    sendReply(channel, Reply::accepted);
    relay(channel, target.get());
  }

  void Server::pair(Channel& channel) {
    ds::Array<std::uint8_t, secret_bytes + 1> request{};
    ds::Array<std::uint8_t, AuthorizedClients::name_bytes> name{};
    const auto deadline = Clock::now() + exchange_timeout;

    channel.receive(request.viewMut(), deadline);
    const std::size_t length = request[secret_bytes];
    if (length > name.size()) {
      refuse(channel);
      return;
    }

    channel.receive(name.viewMut().first(length), deadline);
    Secret secret{};

    std::ranges::copy(request.view().first(secret_bytes), secret.viewMut().begin());
    if (!PairingCodes::redeem(state_.directory(), secret)) {
      // A wrong code costs its sender a second, whatever it guessed.
      std::this_thread::sleep_for(refusal_delay);
      refuse(channel);
      return;
    }

    {
      const StateLock lock{state_.directory()};
      auto clients = AuthorizedClients::load(state_.directory());

      clients.admit(channel.peer(), {reinterpret_cast<const char*>(name.data()), length}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the name's bytes are read as text
      clients.save(state_.directory());
    }

    refuse(channel, Reply::accepted);
  }

}
