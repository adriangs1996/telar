module telar.remote.link;

import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.net;
import telar.platform.sha256;
import telar.platform.thread;
import telar.sys.process;

namespace telar::remote {

  using runtime::FileDescriptor;
  using runtime::SystemError;

  namespace {

    constexpr auto dial_timeout = std::chrono::seconds{15};
    constexpr auto request_timeout = std::chrono::seconds{5};
    constexpr auto reply_timeout = std::chrono::seconds{30};
    constexpr auto hold_interval = std::chrono::milliseconds{250};
    constexpr auto poll_interval = std::chrono::milliseconds{5};
    constexpr std::string_view control_name = "/gateway.sock";
    constexpr std::size_t machine_name_digits = 12;
    constexpr unsigned byte_bits = 8;
    constexpr unsigned byte_mask = 0xff;
    constexpr int listen_backlog = 64;

    using Line = ds::Array<char, LinkClient::line_bytes>;

    // A fixed text built a piece at a time; a piece that does not fit is cut.
    template <std::size_t Capacity>
    class Text {
    public:
      void append(std::string_view text) noexcept {
        const auto count = std::min(text.size(), Capacity - length_);

        std::ranges::copy(text.substr(0, count), bytes_.viewMut().subspan(length_).begin());
        length_ += count;
      }

      void appendNumber(std::uint64_t number) noexcept {
        constexpr std::size_t digits = 20;
        ds::Array<char, digits> text{};
        const auto end = std::to_chars(text.dataMut(), text.dataMut() + text.size(), number).ptr;

        append({text.data(), static_cast<std::size_t>(end - text.data())});
      }

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

    private:
      ds::Array<char, Capacity> bytes_{};
      std::size_t length_ = 0;
    };

    bool waitFor(int descriptor, short events, Clock::time_point deadline) noexcept {
      for (;;) {
        pollfd entry{.fd = descriptor, .events = events, .revents = 0};
        const int ready = ::poll(&entry, 1, pollTimeout(deadline));
        if (ready > 0) {
          return true;
        }

        if (ready == 0 || sys::lastError() != EINTR) {
          return false;
        }
      }
    }

    // Writes all of `text` to a descriptor that may not block; false when its reader is gone.
    bool writeAll(int descriptor, std::string_view text) noexcept {
      const auto deadline = Clock::now() + request_timeout;

      while (!text.empty()) {
        const auto written = ::write(descriptor, text.data(), text.size());
        if (written > 0) {
          text.remove_prefix(static_cast<std::size_t>(written));
        } else if (!runtime::socketWouldBlock(sys::lastError()) || !waitFor(descriptor, POLLOUT, deadline)) {
          return false;
        }
      }

      return true;
    }

    // The line a descriptor sends next, without its newline; none when it ends or stalls first.
    ds::Option<std::string_view> readLine(int descriptor, Line& line, Clock::time_point deadline) noexcept {
      std::size_t length = 0;

      while (length < line.size()) {
        char byte = 0;
        const auto count = ::read(descriptor, &byte, 1);
        if (count == 1) {
          if (byte == '\n') {
            return std::string_view{line.data(), length};
          }

          line.atMut(length++) = byte;
        } else if (count == 0 || !runtime::socketWouldBlock(sys::lastError()) || !waitFor(descriptor, POLLIN, deadline)) {
          return ds::none;
        }
      }

      return ds::none;
    }

    bool sameMachine(const Endpoint& left, const Endpoint& right) noexcept {
      return left.port == right.port && left.key == right.key && left.host.view() == right.host.view();
    }

    bool ownedByUser(int socket) noexcept {
      const auto peer = runtime::peerCredentials(socket);

      return peer && peer->user == ::geteuid();
    }

    // A socket listening on `address`; none when the address is taken or its family is absent.
    FileDescriptor listenOn(const runtime::NetworkAddress& address) noexcept {
      FileDescriptor socket{::socket(address.storage.ss_family, SOCK_STREAM, IPPROTO_TCP)};

      if (!socket) {
        return socket;
      }

      try {
        runtime::configureProxySocket(socket.get());
      } catch (const SystemError&) {
        return FileDescriptor{};
      }

      const int only = 1;

      if (address.storage.ss_family == AF_INET6) {
        static_cast<void>(::setsockopt(socket.get(), IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only)));
      }

      if (::bind(socket.get(), address.address(), address.length) != 0 || ::listen(socket.get(), listen_backlog) != 0) {
        return FileDescriptor{};
      }

      return socket;
    }

    std::uint16_t boundPort(int socket) noexcept {
      sockaddr_in address{};
      socklen_t length = sizeof(address);

      if (::getsockname(socket, reinterpret_cast<sockaddr*>(&address), &length) != 0) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
        return 0;
      }

      return ntohs(address.sin_port);
    }

    // The loopback listeners of a forward: IPv4, and IPv6 on the same port when it is free there.
    struct LocalPort {
      FileDescriptor four;
      FileDescriptor six;
      std::uint16_t port = 0;
    };

    // Listens on `wanted` of this machine, or on a port the system picks when it is taken.
    LocalPort listenLoopback(std::uint16_t wanted) noexcept {
      LocalPort local;
      const in_addr loopback{.s_addr = htonl(INADDR_LOOPBACK)};

      local.four = listenOn(runtime::NetworkAddress::ipv4(loopback, wanted));
      if (!local.four) {
        local.four = listenOn(runtime::NetworkAddress::ipv4(loopback, 0));
      }

      if (!local.four) {
        return local;
      }

      local.port = boundPort(local.four.get());
      local.six = listenOn(runtime::NetworkAddress::ipv6(in6addr_loopback, local.port));
      return local;
    }

    // Asks the gateway of `endpoint` for a connection to `port` there. The reply says whether
    // anything listens on it.
    ds::Option<Reply> requestPort(Channel& channel, std::uint16_t port) noexcept {
      try {
        const ds::Array<std::uint8_t, 2> request{static_cast<std::uint8_t>(port >> byte_bits), static_cast<std::uint8_t>(port & byte_mask)};

        channel.send(request.view(), Clock::now() + exchange_timeout);
        return receiveReply(channel);
      } catch (const ChannelFailure&) {
        return ds::none;
      }
    }

    // The terminal of this process in raw mode while a command there uses it, as it was after.
    class RawTerminal {
    public:
      explicit RawTerminal(int terminal) noexcept
          : terminal_(terminal) {
        if (::tcgetattr(terminal_, &saved_) != 0) {
          return;
        }

        termios raw = saved_;

        ::cfmakeraw(&raw);
        active_ = ::tcsetattr(terminal_, TCSAFLUSH, &raw) == 0;
      }

      ~RawTerminal() {
        if (active_) {
          ::tcsetattr(terminal_, TCSAFLUSH, &saved_);
        }
      }

      RawTerminal(const RawTerminal&) = delete;
      RawTerminal& operator=(const RawTerminal&) = delete;
      RawTerminal(RawTerminal&&) = delete;
      RawTerminal& operator=(RawTerminal&&) = delete;

    private:
      int terminal_;
      termios saved_{};
      bool active_ = false;
    };

    const char* describe(Reply reply) noexcept {
      return reply == Reply::refused ? "this machine is not paired with that gateway; pair it again with `telar machine add`" : "the gateway could not serve the request";
    }

  }

  LinkPaths LinkPaths::resolve(const runtime::EnvironmentSource& environment) {
    const auto location = runtime::cli::SocketLocation::resolve({}, environment, ::geteuid());
    const auto socket = location.path();
    LinkPaths paths;

    paths.directory.assign(socket.substr(0, socket.rfind('/')));
    return paths;
  }

  SocketPath LinkPaths::control() const {
    Text<sizeof(sockaddr_un::sun_path)> text;
    SocketPath path;

    text.append(directory.view());
    text.append(control_name);
    if (text.view().size() != directory.view().size() + control_name.size() || text.view().size() >= sizeof(sockaddr_un::sun_path)) {
      throw SystemError{"The gateway's socket path is too long", ENAMETOOLONG};
    }

    path.assign(text.view());
    return path;
  }

  SocketPath LinkPaths::machine(std::string_view destination) const {
    runtime::Sha256 hash;
    ds::Array<char, 2 * SHA256_DIGEST_LENGTH> digits{};
    Text<sizeof(sockaddr_un::sun_path)> text;
    SocketPath path;

    hash.update(destination);
    const auto digest = hash.finish();
    const auto name = runtime::encodeLowerHex(digest.view(), digits.viewMut()).substr(0, machine_name_digits);

    text.append(directory.view());
    text.append("/gw-");
    text.append(name);
    text.append(".sock");
    if (!text.view().ends_with(".sock") || text.view().size() >= sizeof(sockaddr_un::sun_path)) {
      throw SystemError{"The gateway's socket path is too long", ENAMETOOLONG};
    }

    path.assign(text.view());
    return path;
  }

  Link::Link(const State& state, const LinkPaths& paths)
      : state_(state),
        paths_(paths),
        identity_(Identity::loadOrCreate(state.directory())),
        contexts_(identity_) {
    runtime::createPrivateDirectory(paths_.directory.view());
    control_ = listenUnix(paths_.control().view());
    if (::pipe(wake_.dataMut()) != 0) {
      throw SystemError{"Create the gateway's wake pipe"};
    }

    for (const auto end : wake_) {
      runtime::setCloseOnExec(end);
      runtime::setNonblocking(end);
    }
  }

  Link::~Link() {
    stop();
    while (threads_.load() != 0) {
      std::this_thread::sleep_for(poll_interval);
    }

    for (const auto end : wake_) {
      ::close(end);
    }

    const auto control = paths_.control();
    ds::Array<char, sizeof(sockaddr_un::sun_path)> path{};

    std::ranges::copy(control.view(), path.viewMut().begin());
    ::unlink(path.data());
  }

  void Link::wake() noexcept {
    const char byte = 0;

    static_cast<void>(::write(wake_[1], &byte, 1));
  }

  void Link::stop() noexcept {
    stopping_.store(true);
    wake();
  }

  void Link::run() noexcept {
    constexpr std::size_t maximum_entries = 2 + maximum_machines + (2 * maximum_forwards);
    ds::Array<pollfd, maximum_entries> entries{};
    ds::Array<Accepted, maximum_entries> roles{};

    while (!stopping_.load()) {
      std::size_t count = 0;
      const auto watch = [&](int descriptor, Accepted role) {
        entries.atMut(count) = {.fd = descriptor, .events = POLLIN, .revents = 0};
        roles.atMut(count++) = role;
      };

      watch(wake_[0], {});
      watch(control_.get(), {.role = Role::control});
      {
        const std::scoped_lock lock{mutex_};

        for (std::size_t index = 0; index < machines_.size(); ++index) {
          if (machines_[index].used) {
            watch(machines_[index].listener.get(), {.role = Role::machine, .index = index});
          }
        }

        for (std::size_t index = 0; index < forwards_.size(); ++index) {
          auto& forward = forwards_.atMut(index);
          // A forward nobody holds is closed here, between two waits, so that no wait ever
          // names a descriptor another thread closed.
          if (forward.used && forward.holders == 0) {
            forward.listener.reset();
            forward.listener_six.reset();
            forward.used = forward.connections != 0;
          }

          if (forward.listener) {
            watch(forward.listener.get(), {.role = Role::forward, .index = index, .generation = forward.generation});
          }

          if (forward.listener_six) {
            watch(forward.listener_six.get(), {.role = Role::forward, .index = index, .generation = forward.generation});
          }
        }
      }

      if (::poll(entries.dataMut(), static_cast<nfds_t>(count), -1) < 0 && sys::lastError() != EINTR) {
        return;
      }

      ds::Array<char, 64> drained{};

      while (::read(wake_[0], drained.dataMut(), drained.size()) > 0) {
      }

      for (std::size_t index = 1; index < count; ++index) {
        if (entries[index].revents == 0) {
          continue;
        }

        for (auto socket = acceptConnection(entries[index].fd); socket; socket = acceptConnection(entries[index].fd)) {
          threads_.fetch_add(1);
          try {
            // The thread owns the connection from here; the descriptor crosses as a number.
            runtime::startThread("Start a gateway connection", [this, descriptor = socket.release(), role = roles[index]] {
              answer(FileDescriptor{descriptor}, role);
            }).detach();
          } catch (const SystemError&) {
            threads_.fetch_sub(1);
          }
        }
      }
    }
  }

  void Link::answer(FileDescriptor socket, Accepted accepted) noexcept {
    try {
      // A local port is for any program of this machine, as a forwarded port always is; the
      // sockets are for this account alone.
      if (accepted.role == Role::forward) {
        carry(socket.get(), accepted.index, accepted.generation);
      } else if (ownedByUser(socket.get())) {
        if (accepted.role == Role::control) {
          control(socket.get());
        } else {
          attach(socket.get(), accepted.index);
        }
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a connection that fails ends alone; the others go on
    }

    threads_.fetch_sub(1);
  }

  void Link::control(int socket) {
    Line line{};
    const auto request = readLine(socket, line, Clock::now() + request_timeout);
    if (!request) {
      return;
    }

    const auto space = request->find(' ');
    const auto verb = request->substr(0, space);
    const auto arguments = space == std::string_view::npos ? std::string_view{} : request->substr(space + 1);

    if (verb == "socket") {
      requestSocket(socket, arguments);
    } else if (verb == "forward") {
      requestForward(socket, arguments);
    } else if (verb == "ports") {
      requestPorts(socket, arguments);
    } else if (verb == "ping") {
      static_cast<void>(writeAll(socket, "ok\n"));
    } else if (verb == "stop") {
      static_cast<void>(writeAll(socket, "ok\n"));
      stop();
    } else {
      static_cast<void>(writeAll(socket, "error unknown request\n"));
    }
  }

  void Link::requestSocket(int socket, std::string_view destination) {
    Endpoint endpoint;

    try {
      endpoint = Endpoint::parse(destination);
    } catch (const std::invalid_argument&) {
      static_cast<void>(writeAll(socket, "error that is no gateway address\n"));
      return;
    }

    const auto path = paths_.machine(endpoint.destination().view());
    Text<LinkClient::line_bytes> reply;
    {
      const std::scoped_lock lock{mutex_};
      auto* found = static_cast<Machine*>(nullptr);
      auto* vacant = static_cast<Machine*>(nullptr);

      for (auto& machine : machines_.viewMut()) {
        if (machine.used && sameMachine(machine.endpoint, endpoint)) {
          found = &machine;
        } else if (!machine.used && vacant == nullptr) {
          vacant = &machine;
        }
      }

      if (found == nullptr && vacant != nullptr) {
        vacant->listener = listenUnix(path.view());
        vacant->endpoint = endpoint;
        vacant->used = true;
        found = vacant;
        wake();
      }

      reply.append(found != nullptr ? "ok " : "error the link already serves as many machines as it keeps");
      reply.append(found != nullptr ? path.view() : std::string_view{});
      reply.append("\n");
    }

    static_cast<void>(writeAll(socket, reply.view()));
  }

  void Link::attach(int socket, std::size_t machine) {
    Endpoint endpoint;
    {
      const std::scoped_lock lock{mutex_};

      endpoint = machines_[machine].endpoint;
    }

    auto channel = Channel::dial(contexts_, endpoint, Service::attach, Clock::now() + dial_timeout);
    if (receiveReply(channel) == Reply::accepted) {
      relay(channel, socket);
    }
  }

  ds::Option<std::size_t> Link::openForward(const Endpoint& endpoint, std::uint16_t port, std::string_view origin) {
    {
      const std::scoped_lock lock{mutex_};

      for (std::size_t index = 0; index < forwards_.size(); ++index) {
        auto& forward = forwards_.atMut(index);
        if (forward.used && forward.listener && forward.remote == port && sameMachine(forward.endpoint, endpoint)) {
          ++forward.holders;
          return index;
        }
      }
    }

    // A port nothing listens on there is refused before any port is taken here.
    auto probe = Channel::dial(contexts_, endpoint, Service::forward, Clock::now() + dial_timeout);
    if (requestPort(probe, port) != Reply::accepted) {
      return ds::none;
    }

    auto local = listenLoopback(port);
    if (!local.four) {
      return ds::none;
    }

    const std::scoped_lock lock{mutex_};

    for (std::size_t index = 0; index < forwards_.size(); ++index) {
      auto& forward = forwards_.atMut(index);
      if (forward.used) {
        continue;
      }

      forward.endpoint = endpoint;
      forward.origin.assign(origin.substr(0, std::min(origin.size(), origin_bytes)));
      forward.listener = std::move(local.four);
      forward.listener_six = std::move(local.six);
      forward.remote = port;
      forward.local = local.port;
      forward.holders = 1;
      forward.connections = 0;
      ++forward.generation;
      forward.used = true;
      wake();
      return index;
    }

    return ds::none;
  }

  void Link::releaseForward(std::size_t index, unsigned generation, bool closed_there) noexcept {
    const std::scoped_lock lock{mutex_};
    auto& forward = forwards_.atMut(index);

    if (!forward.used || forward.generation != generation) {
      return;
    }

    // A port that closed there is released for every holder at once, and whoever still holds
    // it finds another generation in its place.
    forward.holders = closed_there ? 0 : forward.holders - std::min(forward.holders, 1U);
    if (closed_there) {
      ++forward.generation;
    }

    if (forward.holders == 0) {
      wake();
    }
  }

  void Link::requestForward(int socket, std::string_view arguments) {
    const auto first = arguments.find(' ');
    const auto rest = first == std::string_view::npos ? std::string_view{} : arguments.substr(first + 1);
    const auto second = rest.find(' ');
    const auto port = runtime::unsignedDecimal<std::uint16_t>(rest.substr(0, second));
    const auto origin = second == std::string_view::npos ? std::string_view{} : rest.substr(second + 1);
    Endpoint endpoint;

    try {
      endpoint = Endpoint::parse(arguments.substr(0, first));
    } catch (const std::invalid_argument&) {
      static_cast<void>(writeAll(socket, "error that is no gateway address\n"));
      return;
    }

    if (!port || *port == 0) {
      static_cast<void>(writeAll(socket, "error that is no port\n"));
      return;
    }

    ds::Option<std::size_t> index;

    try {
      index = openForward(endpoint, *port, origin);
    } catch (const ChannelFailure& failure) {
      Text<LinkClient::line_bytes> reply;

      reply.append("error ");
      reply.append(failure.what());
      reply.append("\n");
      static_cast<void>(writeAll(socket, reply.view()));
      return;
    }

    if (!index) {
      static_cast<void>(writeAll(socket, "error nothing listens on that port there\n"));
      return;
    }

    unsigned generation = 0;
    Text<LinkClient::line_bytes> reply;
    {
      const std::scoped_lock lock{mutex_};

      generation = forwards_[*index].generation;
      reply.append("ok ");
      reply.appendNumber(forwards_[*index].local);
      reply.append("\n");
    }

    bool held = writeAll(socket, reply.view());

    // The forward lasts while its holder keeps this connection and the port stays open there.
    while (held && !stopping_.load()) {
      char byte = 0;
      bool open = false;
      {
        const std::scoped_lock lock{mutex_};

        open = forwards_[*index].used && forwards_[*index].generation == generation && forwards_[*index].holders != 0;
      }

      if (!open) {
        static_cast<void>(writeAll(socket, "closed\n"));
        return;
      }

      if (waitFor(socket, POLLIN, Clock::now() + hold_interval)) {
        held = ::read(socket, &byte, 1) > 0 || runtime::socketWouldBlock(sys::lastError());
      }
    }

    releaseForward(*index, generation, false);
  }

  void Link::carry(int socket, std::size_t index, unsigned generation) {
    Endpoint endpoint;
    std::uint16_t port = 0;
    {
      const std::scoped_lock lock{mutex_};
      auto& forward = forwards_.atMut(index);

      if (!forward.used || forward.generation != generation || forward.holders == 0) {
        return;
      }

      endpoint = forward.endpoint;
      port = forward.remote;
      ++forward.connections;
    }

    ds::Option<Reply> reply;

    try {
      auto channel = Channel::dial(contexts_, endpoint, Service::forward, Clock::now() + dial_timeout);

      reply = requestPort(channel, port);
      if (reply == Reply::accepted) {
        relay(channel, socket);
      }
    } catch (const ChannelFailure&) {
      // A gateway that cannot be reached says nothing of the port; the forward stays.
      reply = ds::none;
    }

    {
      const std::scoped_lock lock{mutex_};
      auto& forward = forwards_.atMut(index);

      forward.connections -= std::min(forward.connections, 1U);
      if (forward.connections == 0 && !forward.listener) {
        forward.used = false;
      }
    }

    // The gateway refuses a port nothing listens on any more, which closes the forward here.
    if (reply == Reply::refused) {
      releaseForward(index, generation, true);
    }
  }

  void Link::requestPorts(int socket, std::string_view destination) {
    Endpoint endpoint;
    Text<maximum_forwards*(origin_bytes + 32)> text;

    try {
      endpoint = Endpoint::parse(destination);
    } catch (const std::invalid_argument&) {
      static_cast<void>(writeAll(socket, "error that is no gateway address\n"));
      return;
    }

    {
      const std::scoped_lock lock{mutex_};

      for (const auto& forward : forwards_) {
        if (!forward.used || !forward.listener || forward.holders == 0 || !sameMachine(forward.endpoint, endpoint)) {
          continue;
        }

        text.appendNumber(forward.remote);
        text.append(" ");
        text.appendNumber(forward.local);
        text.append(" ");
        text.appendNumber(forward.connections);
        text.append(" ");
        text.append(forward.origin.view());
        text.append("\n");
      }
    }

    static_cast<void>(writeAll(socket, text.view()));
  }

  bool LinkClient::running(const LinkPaths& paths) noexcept {
    try {
      Line line{};
      const auto socket = connectUnix(paths.control().view());

      return socket && writeAll(socket.get(), "ping\n") && readLine(socket.get(), line, Clock::now() + request_timeout) == std::string_view{"ok"};
    } catch (const std::exception&) {
      return false;
    }
  }

  SocketPath LinkClient::socket(const LinkPaths& paths, std::string_view destination) {
    Line line{};
    Text<line_bytes> request;
    const auto socket = connectUnix(paths.control().view());

    request.append("socket ");
    request.append(destination);
    request.append("\n");
    if (!socket || !writeAll(socket.get(), request.view())) {
      throw ChannelFailure{"The gateway link is not running"};
    }

    const auto reply = readLine(socket.get(), line, Clock::now() + reply_timeout);
    if (!reply || !reply->starts_with("ok ")) {
      throw ChannelFailure{"The gateway link refused the machine's address"};
    }

    SocketPath path;

    path.assign(reply->substr(3));
    return path;
  }

  int LinkClient::forward(const LinkPaths& paths, std::string_view destination, std::uint16_t port, std::string_view origin, int output) {
    Line line{};
    Text<line_bytes> request;
    const auto socket = connectUnix(paths.control().view());

    request.append("forward ");
    request.append(destination);
    request.append(" ");
    request.appendNumber(port);
    request.append(" ");
    request.append(origin);
    request.append("\n");
    if (!socket || !writeAll(socket.get(), request.view())) {
      throw ChannelFailure{"The gateway link is not running"};
    }

    const auto reply = readLine(socket.get(), line, Clock::now() + reply_timeout);
    if (!reply || !reply->starts_with("ok ")) {
      Text<line_bytes> message;

      message.append("telar gateway: ");
      message.append(reply ? reply->substr(std::min<std::size_t>(reply->size(), 6)) : std::string_view{"the gateway link did not answer"});
      message.append("\n");
      static_cast<void>(writeAll(STDERR_FILENO, message.view()));
      return 1;
    }

    Text<line_bytes> local;

    local.append(reply->substr(3));
    local.append("\n");
    if (!writeAll(output, local.view())) {
      return 1;
    }

    // Holding the connection holds the forward; the link ends it when the port closes there.
    while (!waitFor(socket.get(), POLLIN, Clock::now() + reply_timeout)) {
    }

    return 0;
  }

  int LinkClient::ports(const LinkPaths& paths, std::string_view destination, int output) {
    Line line{};
    Text<line_bytes> request;
    const auto socket = connectUnix(paths.control().view());

    request.append("ports ");
    request.append(destination);
    request.append("\n");
    if (!socket || !writeAll(socket.get(), request.view())) {
      return 0;
    }

    while (const auto row = readLine(socket.get(), line, Clock::now() + request_timeout)) {
      Text<line_bytes> text;

      text.append(*row);
      text.append("\n");
      if (!writeAll(output, text.view())) {
        return 1;
      }
    }

    return 0;
  }

  void LinkClient::stop(const LinkPaths& paths) noexcept {
    try {
      Line line{};
      const auto socket = connectUnix(paths.control().view());

      if (socket && writeAll(socket.get(), "stop\n")) {
        static_cast<void>(readLine(socket.get(), line, Clock::now() + request_timeout));
      }
    } catch (const std::exception&) {
      // No link runs where the path cannot even be formed.
      return;
    }
  }

  int runRemote(const State& state, const RemoteCommand& remote) noexcept {
    try {
      const auto endpoint = Endpoint::parse(remote.destination);
      const auto identity = Identity::loadOrCreate(state.directory());
      const Contexts contexts{identity};
      auto channel = Channel::dial(contexts, endpoint, Service::run, Clock::now() + dial_timeout);
      RunRequest request{.terminal = remote.terminal};
      winsize size{};

      if (remote.terminal && ::ioctl(remote.streams.input, TIOCGWINSZ, &size) == 0 && size.ws_row != 0 && size.ws_col != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
        request.rows = size.ws_row;
        request.columns = size.ws_col;
      }

      sendRunRequest(channel, request, remote.command);
      if (const auto reply = receiveReply(channel); reply != Reply::accepted) {
        throw ChannelFailure{describe(reply)};
      }

      ds::Option<RawTerminal> raw;

      if (remote.terminal) {
        raw.emplace(remote.streams.input);
      }

      return pumpClient(channel, remote.streams);
    } catch (const std::exception& failure) {
      Text<LinkClient::line_bytes> message;

      message.append("telar gateway: ");
      message.append(failure.what());
      message.append("\n");
      static_cast<void>(writeAll(remote.streams.error, message.view()));
      return connection_lost_status;
    }
  }

  Endpoint::Text enroll(const State& state, std::string_view address, std::string_view name) {
    const auto endpoint = Endpoint::parse(address);
    if (!endpoint.secret) {
      throw std::invalid_argument{"Expected a pairing address, as `telar server pair` prints it"};
    }

    const auto identity = Identity::loadOrCreate(state.directory());
    const Contexts contexts{identity};
    auto channel = Channel::dial(contexts, endpoint, Service::pair, Clock::now() + dial_timeout);
    ds::Array<std::uint8_t, secret_bytes + 1 + AuthorizedClients::name_bytes> request{};
    const auto length = std::min(name.size(), AuthorizedClients::name_bytes);

    std::ranges::copy(endpoint.secret->view(), request.viewMut().begin());
    request.atMut(secret_bytes) = static_cast<std::uint8_t>(length);
    std::ranges::copy(name.substr(0, length), request.viewMut().subspan(secret_bytes + 1).begin());
    channel.send(request.view().first(secret_bytes + 1 + length), Clock::now() + exchange_timeout);
    if (receiveReply(channel) != Reply::accepted) {
      throw ChannelFailure{"The gateway refused the pairing code: it was used, it expired or it was mistyped"};
    }

    return endpoint.destination();
  }

}
