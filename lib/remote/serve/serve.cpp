module telar.remote.serve;

import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.listening;
import telar.platform.net;
import telar.platform.paths;
import telar.platform.process;
import telar.platform.thread;
import telar.remote.streams;
import telar.sys.process;
import telar.sys.socket;

namespace telar::remote {

  using runtime::FileDescriptor;
  using runtime::SystemError;

  namespace {

    constexpr auto forward_connect_timeout = std::chrono::seconds{3};
    constexpr auto runtime_start_timeout = std::chrono::seconds{15};
    constexpr auto refusal_delay = std::chrono::seconds{1};
    constexpr auto poll_interval = std::chrono::milliseconds{5};
    // How often a client is told of the ports that opened and closed, and how old the reading
    // of this machine's ports may be when it is.
    constexpr auto ports_interval = std::chrono::milliseconds{250};
    constexpr auto listening_age = std::chrono::seconds{1};
    // How old the list must be for a port missing from it to be worth reading it again.
    constexpr auto listening_recheck = std::chrono::milliseconds{20};
    constexpr auto line_timeout = std::chrono::seconds{2};
    constexpr std::size_t line_bytes = 256;
    constexpr unsigned byte_bits = 8;

    // A path with the terminator the system calls need.
    using PathText = ds::Array<char, PATH_MAX + 1>;

    PathText terminated(std::string_view path) noexcept {
      PathText text{};

      std::ranges::copy(runtime::textPrefix(path, PATH_MAX), text.viewMut().begin());
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
      TerminalEnvironment(ConcurrentMemory& memory, std::span<char> term)
          : entries_(memory) {
        bool named = false;

        // The environment block ends at its null entry.
#pragma clang unsafe_buffer_usage begin
        for (char* const* entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
          named = named || std::string_view{*entry}.starts_with("TERM=");
          entries_.push(*entry);
        }
#pragma clang unsafe_buffer_usage end

        if (!named) {
          entries_.push(term.data());
        }

        entries_.push(nullptr);
      }

      [[nodiscard]] char* const* data() const noexcept {
        return entries_.data();
      }

    private:
      ds::Vec<char*, ConcurrentMemory> entries_;
    };

  }

  Server::Server(ConcurrentMemory& memory, const State& state, const ServeOptions& options)
      : memory_(memory),
        state_(state),
        identity_(Identity::loadOrCreate(state.directory())),
        contexts_(identity_),
        listener_(listenTcp(options.host, options.port)),
        explicit_runtime_socket_(!options.runtime_socket.empty()) {
    runtime_socket_.assign(runtime::cli::SocketLocation::resolve(options.runtime_socket, runtime::process_environment, ::geteuid()).path());
    if (::pipe(wake_.dataMut()) != 0) {
      throw SystemError{"Create the gateway's wake pipe"};
    }

    for (const auto end : wake_) {
      runtime::setCloseOnExec(end);
      runtime::setNonblocking(end);
    }

    exposeSiblings();
    state_.recordPort(listener_.port);
    try {
      // Programs of this machine reach the gateway beside the runtime they belong to.
      const auto directory = runtime_socket_.view().substr(0, runtime_socket_.view().rfind('/'));
      ds::Array<char, PATH_MAX> path{};
      const auto written = std::format_to_n(path.dataMut(), path.size() - 1, "{}/{}", directory, sharing_socket);

      runtime::createPrivateDirectory(directory);
      sharing_ = listenUnix({path.data(), static_cast<std::size_t>(written.size)});
    } catch (const std::exception&) {
      // Without the socket nothing here shares a port; clients still forward what they ask for.
      sharing_.reset();
    }
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
      ds::Array<pollfd, 3> entries{
          pollfd{.fd = listener_.socket.get(), .events = POLLIN, .revents = 0},
          pollfd{.fd = wake_[0], .events = POLLIN, .revents = 0},
          pollfd{.fd = sharing_.get(), .events = POLLIN, .revents = 0},
      };

      if (::poll(entries.dataMut(), entries.size(), -1) < 0 && sys::lastError() != EINTR) {
        return;
      }

      admitClients();
      admitPrograms();
    }
  }

  void Server::admitClients() noexcept {
    for (auto socket = acceptConnection(listener_.socket.get()); socket; socket = acceptConnection(listener_.socket.get())) {
      if (connections_.fetch_add(1) >= maximum_connections) {
        connections_.fetch_sub(1);
        continue;
      }

      const auto source = Source::of(socket.get());
      if (!enterHandshake(source)) {
        connections_.fetch_sub(1);
        continue;
      }

      try {
        // The descriptor crosses as a number, and is the thread's once the thread has started:
        // one that could not start leaves the connection here, which closes it.
        runtime::startThread("Start a gateway connection", [this, descriptor = socket.get(), source] {
          answer(FileDescriptor{descriptor}, source);
        }).detach();

        static_cast<void>(socket.release());
      } catch (const SystemError&) {
        leaveHandshake(source);
        connections_.fetch_sub(1);
      }
    }
  }

  void Server::admitPrograms() noexcept {
    for (auto socket = sharing_ ? acceptConnection(sharing_.get()) : FileDescriptor{}; socket; socket = acceptConnection(sharing_.get())) {
      connections_.fetch_add(1);
      try {
        runtime::startThread("Start a gateway connection", [this, descriptor = socket.get()] {
          share(FileDescriptor{descriptor});
        }).detach();

        static_cast<void>(socket.release());
      } catch (const SystemError&) {
        connections_.fetch_sub(1);
      }
    }
  }

  void Server::stop() noexcept {
    const char byte = 0;

    stopping_.store(true);
    static_cast<void>(::write(wake_[1], &byte, 1));
  }

  Server::Source Server::Source::of(int socket) noexcept {
    sockaddr_storage address{};
    socklen_t size = sizeof(address);
    Source source;

    // A connection whose address cannot be read counts with the others that have none.
    if (::getpeername(socket, reinterpret_cast<sockaddr*>(&address), &size) != 0) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API takes every address family as a sockaddr
      return source;
    }

    // The host's bytes alone: each connection of one host comes from a port of its own.
    const auto keep = [&source](std::span<const std::byte> host) {
      std::ranges::transform(host, source.address.viewMut().begin(), [](std::byte byte) {
        return std::to_integer<std::uint8_t>(byte);
      });

      source.length = host.size();
    };

    const auto stored = std::as_bytes(std::span{&address, 1});

    if (address.ss_family == AF_INET) {
      sockaddr_in ipv4{};

      std::ranges::copy(stored.first(sizeof(ipv4)), std::as_writable_bytes(std::span{&ipv4, 1}).begin());
      keep(std::as_bytes(std::span{&ipv4.sin_addr, 1}));
    } else if (address.ss_family == AF_INET6) {
      sockaddr_in6 ipv6{};

      std::ranges::copy(stored.first(sizeof(ipv6)), std::as_writable_bytes(std::span{&ipv6, 1}).begin());
      keep(std::as_bytes(std::span{&ipv6.sin6_addr, 1}));
    }

    return source;
  }

  Server::HandshakePlace::HandshakePlace(Server& server, const Source& source) noexcept
      : server_(server),
        source_(source) {}

  Server::HandshakePlace::~HandshakePlace() {
    leave();
  }

  void Server::HandshakePlace::leave() noexcept {
    if (std::exchange(held_, false)) {
      server_.leaveHandshake(source_);
    }
  }

  bool Server::enterHandshake(const Source& source) noexcept {
    const std::scoped_lock lock{mutex_};

    if (handshakes_ >= maximum_handshakes) {
      return false;
    }

    auto* vacant = static_cast<Handshakes*>(nullptr);

    for (auto& entry : handshaking_.viewMut()) {
      if (entry.count != 0 && entry.source == source) {
        if (entry.count >= maximum_handshakes_per_source) {
          return false;
        }

        ++entry.count;
        ++handshakes_;
        return true;
      }

      if (entry.count == 0 && vacant == nullptr) {
        vacant = &entry;
      }
    }

    // Fewer places are taken than the table holds sources, so one is vacant.
    vacant->source = source;
    vacant->count = 1;
    ++handshakes_;
    return true;
  }

  void Server::leaveHandshake(const Source& source) noexcept {
    const std::scoped_lock lock{mutex_};

    for (auto& entry : handshaking_.viewMut()) {
      if (entry.count != 0 && entry.source == source) {
        --entry.count;
        --handshakes_;
        return;
      }
    }
  }

  void Server::answer(FileDescriptor socket, const Source& source) noexcept {
    try {
      HandshakePlace place{*this, source};
      ds::Option<Channel> channel;

      try {
        channel.emplace(Channel::accept(contexts_, std::move(socket), Clock::now() + handshake_timeout));
      } catch (const std::exception&) {
        place.leave();
        connections_.fetch_sub(1);
        return;
      }

      serve(channel.getMut(), place);
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a connection that fails ends alone; the others go on
    }

    connections_.fetch_sub(1);
  }

  void Server::serve(Channel& channel, HandshakePlace& place) {
    // A pairing keeps its place until it ends, admitted or not.
    if (channel.service() == Service::pair) {
      pair(channel);
      return;
    }

    // The list is read for every connection, so a client revoked now is refused now.
    if (!AuthorizedClients::load(state_.directory()).admits(channel.peer())) {
      refuse(channel);
      return;
    }

    place.leave();

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
      ports(channel);
      return;
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
      const auto home = terminated(runtime::processHome().empty() ? std::string_view{"/"} : runtime::processHome());
      auto server = ds::toArray("server");
      auto endpoint = ds::toArray("endpoint");
      auto option = ds::toArray("--socket");
      // A runtime at its default socket is started as any telar command starts it, without naming the socket.
      const ds::Array<char*, 6> arguments{path.dataMut(), server.dataMut(), endpoint.dataMut(), explicit_runtime_socket_ ? option.dataMut() : nullptr, socket.dataMut(), nullptr};
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
    const auto home = terminated(runtime::processHome().empty() ? std::string_view{"/"} : runtime::processHome());
    ds::Array<char, 3> flag{'-', 'c', '\0'};
    const ds::Array<char*, 4> arguments{shell.dataMut(), flag.dataMut(), command.dataMut(), nullptr};
    runtime::SpawnSpec specification{
        .executable = shell.data(),
        .cwd = home.data(),
        .arguments = arguments.data(),
        .environment = environ,
        .size = {.cols = request.columns, .rows = request.rows, .cell_width_px = 0, .cell_height_px = 0},
    };

    try {
      if (request.terminal) {
        auto term = ds::toArray("TERM=xterm-256color");
        const TerminalEnvironment environment{memory_, term.viewMut()};

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
    auto reply = Reply::accepted;

    // The list is read before the code is spent: a list with no room for a new client leaves the
    // code pending, for once a client is revoked.
    {
      const StateLock lock{state_.directory()};
      auto clients = AuthorizedClients::load(state_.directory());

      if (!clients.admits(channel.peer()) && clients.rows().size() == AuthorizedClients::maximum) {
        reply = Reply::unavailable;
      } else if (!PairingCodes::redeem(state_.directory(), secret, lock)) {
        reply = Reply::refused;
      } else {
        clients.admit(channel.peer(), {reinterpret_cast<const char*>(name.data()), length}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the name's bytes are read as text
        clients.save(state_.directory());
      }
    }

    // A wrong code costs its sender a second, whatever it guessed.
    if (reply == Reply::refused) {
      std::this_thread::sleep_for(refusal_delay);
    }

    refuse(channel, reply);
  }

  bool Server::listening(std::uint16_t port) noexcept {
    const std::scoped_lock lock{mutex_};

    if (Clock::now() - listening_read_ >= listening_age) {
      listening_count_ = runtime::userListeningPorts(::geteuid(), listening_.viewMut());
      listening_read_ = Clock::now();
    }

    return std::ranges::binary_search(std::span{listening_}.first(listening_count_), port);
  }

  bool Server::listeningNow(std::uint16_t port) noexcept {
    if (listening(port)) {
      return true;
    }

    {
      const std::scoped_lock lock{mutex_};

      if (Clock::now() - listening_read_ < listening_recheck) {
        return false;
      }

      // Read again at the next question, which is the one below.
      listening_read_ = Clock::time_point{};
    }

    return listening(port);
  }

  Server::SharingRequest Server::SharingRequest::parse(std::string_view line) noexcept {
    const auto first = line.find(' ');
    const auto rest = first == std::string_view::npos ? std::string_view{} : runtime::textAfter(line, first + 1);
    const auto second = rest.find(' ');

    return {
        .port = runtime::unsignedDecimal<std::uint16_t>(runtime::textPrefix(rest, second)).valueOr(0),
        .origin = second == std::string_view::npos ? std::string_view{} : runtime::textAfter(rest, second + 1),
        .sharing = runtime::textPrefix(line, first) == "share",
    };
  }

  bool Server::recordSharing(unsigned owner, const SharingRequest& request) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which the origin is cut to
    const std::scoped_lock lock{mutex_};
    auto* vacant = static_cast<Shared*>(nullptr);

    for (auto& entry : shared_.viewMut()) {
      if (entry.used && entry.port == request.port) {
        // A port is shared once; whoever asked first keeps it, and only it withdraws it.
        const bool own = entry.owner == owner;

        entry.used = request.sharing || !own;
        return own;
      }

      if (!entry.used && vacant == nullptr) {
        vacant = &entry;
      }
    }

    if (!request.sharing) {
      return true;
    }

    // As many ports are shared as the gateway keeps: this one is not, and its program is told.
    if (vacant == nullptr) {
      return false;
    }

    vacant->origin.assign(runtime::textPrefix(request.origin, PortNotice::origin_bytes));
    vacant->owner = owner;
    vacant->port = request.port;
    vacant->used = true;
    return true;
  }

  void Server::share(FileDescriptor socket) noexcept {
    unsigned owner = 0;

    {
      const std::scoped_lock lock{mutex_};

      owner = ++owners_;
    }

    const auto peer = runtime::peerCredentials(socket.get());

    // What a program shares lasts as long as its connection: it is read until it ends.
    while (peer && peer->user == ::geteuid() && !stopping_.load()) {
      ds::Array<char, line_bytes> line{};

      if (!waitReady(socket.get(), POLLIN, Clock::now() + ports_interval)) {
        continue;
      }

      const auto asked = readLine(socket.get(), line.viewMut(), Clock::now() + line_timeout);
      if (!asked) {
        break;
      }

      const auto request = SharingRequest::parse(*asked);
      const bool done = request.port != 0 && (!request.sharing || listening(request.port)) && recordSharing(owner, request);

      if (!writeText(socket.get(), done ? "ok\n" : "refused\n", Clock::now() + line_timeout)) {
        break;
      }
    }

    {
      const std::scoped_lock lock{mutex_};

      for (auto& entry : shared_.viewMut()) {
        entry.used = entry.used && entry.owner != owner;
      }
    }

    connections_.fetch_sub(1);
  }

  void Server::PortList::forget(std::uint16_t port) noexcept {
    const auto kept = std::ranges::remove(ports.viewMut().first(count), port);

    count = static_cast<std::size_t>(kept.begin() - ports.viewMut().begin());
  }

  void Server::tellShared(Channel& channel, PortList& told) {
    // What this machine shares now, read under the lock and told outside it.
    ds::Array<Shared, maximum_shared> shared;

    {
      const std::scoped_lock lock{mutex_};

      shared = shared_;
    }

    for (std::size_t index = told.count; index > 0; --index) {
      const auto port = told.ports[index - 1];
      const bool still = std::ranges::any_of(shared, [port](const Shared& entry) {
        return entry.used && entry.port == port;
      });

      if (!still || !listening(port)) {
        told.forget(port);
        PortNotice{.kind = PortNotice::Kind::closed, .port = port}.send(channel);
      }
    }

    for (const auto& entry : shared) {
      const bool known = std::ranges::contains(std::span{told.ports}.first(told.count), entry.port);
      if (entry.used && !known && told.count < told.ports.size() && listening(entry.port)) {
        PortNotice notice{.kind = PortNotice::Kind::shared, .port = entry.port};

        notice.origin = entry.origin;
        notice.send(channel);
        told.ports.atMut(told.count++) = entry.port;
      }
    }
  }

  void Server::ports(Channel& channel) {
    // The ports this client asked to hear about, and those shared here it was told to forward.
    PortList watched;
    PortList told;
    PortNotices notices;

    sendReply(channel, Reply::accepted);
    while (!stopping_.load() && notices.receive(channel)) {
      while (const auto notice = notices.next()) {
        watched.forget(notice->port);
        if (notice->kind != PortNotice::Kind::watch) {
          continue;
        }

        // A port nothing listens on is closed before it was ever watched.
        if (listeningNow(notice->port) && watched.count < watched.ports.size()) {
          watched.ports.atMut(watched.count++) = notice->port;
        } else {
          PortNotice{.kind = PortNotice::Kind::closed, .port = notice->port}.send(channel);
        }
      }

      for (std::size_t index = watched.count; index > 0; --index) {
        const auto port = watched.ports[index - 1];
        if (!listening(port)) {
          watched.forget(port);
          PortNotice{.kind = PortNotice::Kind::closed, .port = port}.send(channel);
        }
      }

      tellShared(channel, told);
      static_cast<void>(waitReady(channel.descriptor(), POLLIN, Clock::now() + ports_interval));
    }
  }

}
