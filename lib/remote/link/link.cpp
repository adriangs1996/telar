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
    constexpr auto watch_interval = std::chrono::milliseconds{250};
    constexpr auto watch_retry = std::chrono::seconds{5};
    // How long a port of this machine is given to answer before a forward listens on it.
    constexpr auto taken_probe = std::chrono::milliseconds{200};
    // How often an idle link looks at whether it is still wanted.
    constexpr auto idle_check = std::chrono::seconds{30};
    constexpr auto poll_interval = std::chrono::milliseconds{5};
    constexpr std::string_view control_name = "/gateway.sock";
    constexpr std::size_t machine_name_digits = 12;
    constexpr unsigned byte_bits = 8;
    constexpr unsigned byte_mask = 0xff;
    constexpr int listen_backlog = 64;
    // What a wait reads at a time of the bytes that woke it.
    constexpr std::size_t wake_bytes = 64;
    // What a row of a machine's forwards takes beside its origin: three numbers, how it came to
    // be and what separates them.
    constexpr std::size_t ports_row_bytes = 32;
    // What starts the line a link refuses a request with, before the reason.
    constexpr std::string_view refusal_prefix = "error ";

    using Line = ds::Array<char, LinkClient::line_bytes>;

    // A fixed text built a piece at a time; a piece that does not fit is cut.
    template <std::size_t Capacity>
    class Text {
    public:
      void append(std::string_view text) noexcept {
        const auto count = std::min(text.size(), Capacity - length_);

        std::ranges::copy(runtime::textPrefix(text, count), bytes_.viewMut().subspan(length_).begin());
        length_ += count;
      }

      void appendNumber(std::uint64_t number) noexcept {
        constexpr std::size_t digits = 20;
        ds::Array<char, digits> text{};
        const auto* const end = std::to_chars(text.dataMut(), std::to_address(text.viewMut().end()), number).ptr;

        append({text.data(), static_cast<std::size_t>(end - text.data())});
      }

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

    private:
      ds::Array<char, Capacity> bytes_{};
      std::size_t length_ = 0;
    };

    // Writes all of `text` to a descriptor that may not block; false when its reader is gone.
    bool writeAll(int descriptor, std::string_view text) noexcept {
      return writeText(descriptor, text, Clock::now() + request_timeout);
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
        socket.reset();
        return socket;
      }

      const int only = 1;

      if (address.storage.ss_family == AF_INET6) {
        static_cast<void>(::setsockopt(socket.get(), IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only)));
      }

      // A port a forward just left is taken again at once, not after its last connections
      // have been forgotten.
      static_cast<void>(::setsockopt(socket.get(), SOL_SOCKET, SO_REUSEADDR, &only, sizeof(only)));
      if (::bind(socket.get(), address.address(), address.length) != 0 || ::listen(socket.get(), listen_backlog) != 0) {
        socket.reset();
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

      // A port something answers on here is taken, also by a program that listens on every
      // address, beside which some systems would let this one listen.
      if (!connectLoopback(wanted, Clock::now() + taken_probe)) {
        local.four = listenOn(runtime::NetworkAddress::ipv4(loopback, wanted));
      }

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

    // Asks the gateway of a channel for a connection to `port` of its machine; false when the
    // request could not be sent.
    bool sendPort(Channel& channel, std::uint16_t port) noexcept {
      try {
        const ds::Array<std::uint8_t, 2> request{static_cast<std::uint8_t>(port >> byte_bits), static_cast<std::uint8_t>(port & byte_mask)};

        channel.send(request.view(), Clock::now() + exchange_timeout);
        return true;
      } catch (const ChannelFailure&) {
        return false;
      }
    }

    // The same, waiting for the gateway to say whether anything listens on the port.
    ds::Option<Reply> requestPort(Channel& channel, std::uint16_t port) noexcept {
      try {
        return sendPort(channel, port) ? ds::Option{receiveReply(channel)} : ds::none;
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
    ds::Array<char, std::size_t{2} * SHA256_DIGEST_LENGTH> digits{};
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

  Link::Link(const State& state, LinkPaths paths)
      : state_(state),
        paths_(std::move(paths)),
        identity_(Identity::loadOrCreate(state.directory())),
        contexts_(identity_) {
    runtime::createPrivateDirectory(paths_.directory.view());
    const auto control = paths_.control();

    std::ranges::copy(control.view(), control_file_.viewMut().begin());
    control_ = listenUnix(control.view());
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

    ::unlink(control_file_.data());
  }

  void Link::wake() const noexcept {
    const char byte = 0;

    static_cast<void>(::write(wake_[1], &byte, 1));
  }

  void Link::stop() noexcept {
    stopping_.store(true);
    wake();
  }

  bool Link::busy() const noexcept {
    const bool held = std::ranges::any_of(machines_, [](const Machine& machine) {
      return machine.used && machine.holds != 0;
    });

    const bool forwarding = std::ranges::any_of(forwards_, [](const Forward& forward) {
      return forward.used;
    });

    return held || forwarding || threads_.load() != 0;
  }

  void Link::Waits::add(int descriptor, Accepted role) noexcept {
    entries.atMut(count) = {.fd = descriptor, .events = POLLIN, .revents = 0};
    roles.atMut(count++) = role;
  }

  void Link::gather(Waits& waits) noexcept {
    waits.count = 0;
    waits.add(wake_[0], {});
    waits.add(control_.get(), {.role = Role::control});
    const std::scoped_lock lock{mutex_};

    for (std::size_t index = 0; index < machines_.size(); ++index) {
      if (machines_[index].used && machines_[index].listener) {
        waits.add(machines_[index].listener.get(), {.role = Role::machine, .index = index});
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
        waits.add(forward.listener.get(), {.role = Role::forward, .index = index, .generation = forward.generation});
      }

      if (forward.listener_six) {
        waits.add(forward.listener_six.get(), {.role = Role::forward, .index = index, .generation = forward.generation});
      }
    }
  }

  bool Link::admit(int listener, Accepted role) noexcept {
    bool admitted = false;

    for (auto socket = acceptConnection(listener); socket; socket = acceptConnection(listener)) {
      admitted = true;
      threads_.fetch_add(1);
      try {
        // The descriptor crosses as a number, and is the thread's once the thread has started:
        // one that could not start leaves the connection here, which closes it.
        runtime::startThread("Start a gateway connection", [this, descriptor = socket.get(), role] {
          answer(FileDescriptor{descriptor}, role);
        }).detach();

        static_cast<void>(socket.release());
      } catch (const SystemError&) {
        threads_.fetch_sub(1);
      }
    }

    return admitted;
  }

  void Link::run() noexcept {
    const auto wait_ms = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(idle_check).count());
    Waits waits;
    auto last_used = Clock::now();

    while (!stopping_.load()) {
      gather(waits);
      {
        const std::scoped_lock lock{mutex_};

        // A link nobody has used for a while ends, and so does one whose socket was removed,
        // with the directory it lived in or by a newer link: nothing could reach it again.
        last_used = busy() ? Clock::now() : last_used;
        if (Clock::now() - last_used >= idle_lifetime || ::access(control_file_.data(), F_OK) != 0) {
          return;
        }
      }

      if (::poll(waits.entries.dataMut(), static_cast<nfds_t>(waits.count), wait_ms) < 0 && sys::lastError() != EINTR) {
        return;
      }

      ds::Array<char, wake_bytes> drained{};

      while (::read(wake_[0], drained.dataMut(), drained.size()) > 0) {
      }

      for (std::size_t index = 1; index < waits.count; ++index) {
        if (waits.entries[index].revents != 0 && admit(waits.entries[index].fd, waits.roles[index])) {
          last_used = Clock::now();
        }
      }
    }
  }

  void Link::answer(FileDescriptor socket, Accepted accepted) noexcept {
    try {
      // A local port is for any program of this machine, as a forwarded port always is; the
      // sockets are for this account alone.
      if (accepted.role == Role::forward) {
        carry(socket.get(), accepted);
      } else if (ownedByUser(socket.get())) {
        if (accepted.role == Role::control) {
          control(socket.get());
        } else {
          attach(socket.get(), accepted);
        }
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a connection that fails ends alone; the others go on
    }

    threads_.fetch_sub(1);
  }

  void Link::control(int socket) {
    Line line{};
    const auto request = readLine(socket, line.viewMut(), Clock::now() + request_timeout);
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
    } else if (verb == "hold") {
      requestHold(socket, arguments);
    } else if (verb == "run") {
      requestRun(socket, arguments);
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
      const auto slot = machineSlot(endpoint);

      if (slot && !machines_[*slot].listener) {
        machines_.atMut(*slot).listener = listenUnix(path.view());
        wake();
      }

      reply.append(slot ? "ok " : "error the link already serves as many machines as it keeps");
      reply.append(slot ? path.view() : std::string_view{});
      reply.append("\n");
    }

    static_cast<void>(writeAll(socket, reply.view()));
  }

  ds::Option<std::size_t> Link::machineSlot(const Endpoint& endpoint) noexcept {
    // The machine's own slot, or the first vacant one until that is found.
    ds::Option<std::size_t> slot;

    for (std::size_t index = 0; index < machines_.size(); ++index) {
      if (machines_[index].used && sameMachine(machines_[index].endpoint, endpoint)) {
        slot = index;
        return slot;
      }

      if (!machines_[index].used && !slot) {
        slot = index;
      }
    }

    if (slot) {
      machines_.atMut(*slot).endpoint = endpoint;
      machines_.atMut(*slot).used = true;
    }

    return slot;
  }

  void Link::watchMachine(std::size_t machine) noexcept {
    auto& entry = machines_.atMut(machine);

    if (entry.watched || Clock::now() < entry.retry_at || stopping_.load()) {
      return;
    }

    entry.watched = true;
    threads_.fetch_add(1);
    try {
      runtime::startThread("Start a gateway connection", [this, machine] {
        watch(machine);
      }).detach();
    } catch (const SystemError&) {
      entry.watched = false;
      threads_.fetch_sub(1);
    }
  }

  void Link::watch(std::size_t machine) noexcept {
    Endpoint endpoint;

    {
      const std::scoped_lock lock{mutex_};

      endpoint = machines_[machine].endpoint;
    }

    // Whether the watch ended because nothing needed it, and not because the gateway was lost.
    bool unneeded = false;

    try {
      auto channel = Channel::dial(contexts_, endpoint, Service::ports, Clock::now() + dial_timeout);

      if (receiveReply(channel) == Reply::accepted) {
        unneeded = observe(channel, machine, endpoint);
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a gateway that cannot be heard is asked again later
    }

    {
      const std::scoped_lock lock{mutex_};

      // What the machine shared is no longer known to listen, so it is let go; what a program
      // here asked for stays until that program or a refused connection ends it.
      for (auto& forward : forwards_.viewMut()) {
        if (forward.used && forward.automatic && sameMachine(forward.endpoint, endpoint)) {
          forward.automatic = false;
          forward.holders -= std::min(forward.holders, 1U);
        }
      }

      // A gateway that was lost is asked again after a while; a watch nothing needed starts
      // again with the next forward or holder, at once.
      machines_.atMut(machine).watched = false;
      machines_.atMut(machine).retry_at = unneeded ? Clock::time_point{} : Clock::now() + watch_retry;
      wake();
    }

    threads_.fetch_sub(1);
  }

  bool Link::observe(Channel& channel, std::size_t machine, const Endpoint& endpoint) {
    // The ports of the machine this link asked the gateway to watch.
    ds::Array<std::uint16_t, maximum_forwards> asked{};
    std::size_t asked_count = 0;
    PortNotices notices;

    while (!stopping_.load() && notices.receive(channel)) {
      while (const auto notice = notices.next()) {
        if (notice->kind == PortNotice::Kind::shared) {
          static_cast<void>(openForward(endpoint, notice->port, notice->origin.view(), Opening::shared));
        } else if (notice->kind == PortNotice::Kind::closed) {
          const auto kept = std::ranges::remove(asked.viewMut().first(asked_count), notice->port);

          asked_count = static_cast<std::size_t>(kept.begin() - asked.viewMut().begin());
          closeForward(endpoint, notice->port);
        }
      }

      const auto needs = watchNeeds(machine, endpoint);
      if (!needs.needed) {
        return true;
      }

      const auto wanted = std::span{needs.wanted}.first(needs.wanted_count);

      // A port whose holder left is no longer watched there, so what is asked never outgrows
      // the forwards the link keeps.
      for (std::size_t index = asked_count; index > 0; --index) {
        const auto port = asked[index - 1];
        if (!std::ranges::contains(wanted, port)) {
          PortNotice{.kind = PortNotice::Kind::unwatch, .port = port}.send(channel);
          asked.atMut(index - 1) = asked[asked_count - 1];
          --asked_count;
        }
      }

      for (const auto port : wanted) {
        if (asked_count < asked.size() && !std::ranges::contains(std::span{asked}.first(asked_count), port)) {
          PortNotice{.kind = PortNotice::Kind::watch, .port = port}.send(channel);
          asked.atMut(asked_count++) = port;
        }
      }

      static_cast<void>(waitReady(channel.descriptor(), POLLIN, Clock::now() + watch_interval));
    }

    return false;
  }

  Link::WatchNeeds Link::watchNeeds(std::size_t machine, const Endpoint& endpoint) noexcept {
    WatchNeeds needs;
    const std::scoped_lock lock{mutex_};
    const bool held = machines_[machine].holds != 0;

    for (auto& forward : forwards_.viewMut()) {
      if (!forward.used || !forward.listener || !sameMachine(forward.endpoint, endpoint)) {
        continue;
      }

      // Nothing here holds the machine any more: what it shares is no longer forwarded.
      if (forward.automatic && !held) {
        forward.automatic = false;
        forward.holders -= std::min(forward.holders, 1U);
        wake();
      }

      needs.needed = needs.needed || forward.holders != 0;
      if (forward.holders != 0 && !forward.automatic && needs.wanted_count < needs.wanted.size()) {
        needs.wanted.atMut(needs.wanted_count++) = forward.remote;
      }
    }

    needs.needed = needs.needed || held;
    return needs;
  }

  void Link::makeReady(std::size_t machine) noexcept {
    Endpoint endpoint;

    {
      const std::scoped_lock lock{mutex_};
      auto& entry = machines_.atMut(machine);

      if (entry.readying || stopping_.load()) {
        return;
      }

      entry.readying = true;
      endpoint = entry.endpoint;
      threads_.fetch_add(1);
    }

    try {
      runtime::startThread("Start a gateway connection", [this, machine, endpoint] {
        ds::Option<Channel> channel;

        try {
          channel.emplace(Channel::dial(contexts_, endpoint, Service::run, Clock::now() + dial_timeout));
        } catch (const std::exception&) {
          channel.reset();
        }

        {
          const std::scoped_lock lock{mutex_};
          auto& entry = machines_.atMut(machine);

          entry.ready = std::move(channel);
          entry.ready_since = Clock::now();
          entry.readying = false;
        }

        threads_.fetch_sub(1);
      }).detach();
    } catch (const SystemError&) {
      const std::scoped_lock lock{mutex_};

      machines_.atMut(machine).readying = false;
      threads_.fetch_sub(1);
    }
  }

  void Link::requestRun(int socket, std::string_view destination) {
    Endpoint endpoint;
    ds::Option<std::size_t> slot;
    ds::Option<Channel> channel;

    try {
      endpoint = Endpoint::parse(destination);
    } catch (const std::invalid_argument&) {
      static_cast<void>(writeAll(socket, "error that is no gateway address\n"));
      return;
    }

    for (bool waiting = true; waiting && !stopping_.load();) {
      {
        const std::scoped_lock lock{mutex_};

        slot = machineSlot(endpoint);
        if (!slot) {
          break;
        }

        auto& entry = machines_.atMut(*slot);

        // The connection kept ready is used when its gateway has neither closed it nor could
        // have given up waiting for it.
        channel = entry.ready.take();
        if (channel && (Clock::now() - entry.ready_since >= ready_lifetime || channel->disturbed())) {
          channel.reset();
        }

        // One being made is ahead of any started now, so it is waited for.
        waiting = !channel && entry.readying;
      }

      if (waiting) {
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    }

    try {
      if (!channel) {
        channel.emplace(Channel::dial(contexts_, endpoint, Service::run, Clock::now() + dial_timeout));
      }
    } catch (const ChannelFailure& failure) {
      Text<LinkClient::line_bytes> reply;

      reply.append("error ");
      reply.append(failure.what());
      reply.append("\n");
      static_cast<void>(writeAll(socket, reply.view()));
      return;
    }

    // The next command of this machine finds a connection made while this one runs.
    if (slot) {
      makeReady(*slot);
    }

    if (writeAll(socket, "ok\n")) {
      relay(channel.getMut(), socket);
    }
  }

  void Link::requestHold(int socket, std::string_view destination) {
    Endpoint endpoint;
    ds::Option<std::size_t> slot;

    try {
      endpoint = Endpoint::parse(destination);
    } catch (const std::invalid_argument&) {
      static_cast<void>(writeAll(socket, "error that is no gateway address\n"));
      return;
    }

    {
      const std::scoped_lock lock{mutex_};

      slot = machineSlot(endpoint);
      if (slot) {
        ++machines_.atMut(*slot).holds;
        watchMachine(*slot);
      }
    }

    if (!slot) {
      static_cast<void>(writeAll(socket, "error the link already serves as many machines as it keeps\n"));
      return;
    }

    bool held = writeAll(socket, "ok\n");

    // The machine is held while its holder keeps this connection.
    while (held && !stopping_.load()) {
      char byte = 0;

      if (waitReady(socket, POLLIN, Clock::now() + hold_interval)) {
        held = ::read(socket, &byte, 1) > 0 || runtime::socketWouldBlock(sys::lastError());
      }

      const std::scoped_lock lock{mutex_};

      watchMachine(*slot);
    }

    const std::scoped_lock lock{mutex_};

    --machines_.atMut(*slot).holds;
  }

  void Link::attach(int socket, const Accepted& accepted) {
    Endpoint endpoint;

    {
      const std::scoped_lock lock{mutex_};

      endpoint = machines_[accepted.index].endpoint;
    }

    auto channel = Channel::dial(contexts_, endpoint, Service::attach, Clock::now() + dial_timeout);

    // What the window has to say travels with the handshake's last flight instead of waiting a
    // round trip for the gateway's answer.
    static_cast<void>(relayOnceAnswered(channel, socket));
  }

  ds::Option<std::size_t> Link::listeningForward(const Endpoint& endpoint, std::uint16_t port) const noexcept {
    for (std::size_t index = 0; index < forwards_.size(); ++index) {
      const auto& forward = forwards_[index];
      if (forward.used && forward.listener && forward.remote == port && sameMachine(forward.endpoint, endpoint)) {
        return index;
      }
    }

    return ds::none;
  }

  ds::Option<std::size_t> Link::openForward(const Endpoint& endpoint, std::uint16_t port, std::string_view origin, Opening opening) {
    const bool shared = opening == Opening::shared;

    {
      const std::scoped_lock lock{mutex_};
      const auto machine = machineSlot(endpoint);

      // A shared port is forwarded for the programs that hold its machine, and for nobody else.
      if (!machine || (shared && machines_[*machine].holds == 0)) {
        return ds::none;
      }

      if (const auto listening = listeningForward(endpoint, port)) {
        auto& forward = forwards_.atMut(*listening);

        if (!shared || !forward.automatic) {
          ++forward.holders;
        }

        forward.automatic = forward.automatic || shared;
        watchMachine(*machine);
        return *listening;
      }
    }

    // A port nothing listens on there is refused before any port is taken here; one the
    // machine shares is known to listen.
    if (!shared) {
      auto probe = Channel::dial(contexts_, endpoint, Service::forward, Clock::now() + dial_timeout);
      if (requestPort(probe, port) != Reply::accepted) {
        return ds::none;
      }
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
      forward.automatic = shared;
      ++forward.generation;
      forward.used = true;
      if (const auto machine = machineSlot(endpoint)) {
        watchMachine(*machine);
      }

      wake();
      return index;
    }

    return ds::none;
  }

  void Link::closeForward(const Endpoint& endpoint, std::uint16_t port) noexcept {
    for (std::size_t index = 0; index < forwards_.size(); ++index) {
      unsigned generation = 0;

      {
        const std::scoped_lock lock{mutex_};
        const auto& forward = forwards_[index];

        if (!forward.used || forward.remote != port || !sameMachine(forward.endpoint, endpoint)) {
          continue;
        }

        generation = forward.generation;
      }

      releaseForward({.index = index, .generation = generation}, true);
    }
  }

  void Link::releaseForward(HeldForward held, bool closed_there) noexcept {
    const std::scoped_lock lock{mutex_};
    auto& forward = forwards_.atMut(held.index);

    if (!forward.used || forward.generation != held.generation) {
      return;
    }

    // A port that closed there is released for every holder at once, and whoever still holds
    // it finds another generation in its place.
    forward.holders = closed_there ? 0 : forward.holders - std::min(forward.holders, 1U);
    if (closed_there) {
      forward.automatic = false;
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
      index = openForward(endpoint, *port, origin, Opening::asked);
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

    HeldForward forward{.index = *index};
    Text<LinkClient::line_bytes> reply;

    {
      const std::scoped_lock lock{mutex_};

      forward.generation = forwards_[*index].generation;
      reply.append("ok ");
      reply.appendNumber(forwards_[*index].local);
      reply.append("\n");
    }

    bool held = writeAll(socket, reply.view());

    // The forward lasts while its holder keeps this connection and the port stays open there.
    while (held && !stopping_.load()) {
      char byte = 0;

      if (!stillOpen(forward)) {
        static_cast<void>(writeAll(socket, "closed\n"));
        return;
      }

      if (waitReady(socket, POLLIN, Clock::now() + hold_interval)) {
        held = ::read(socket, &byte, 1) > 0 || runtime::socketWouldBlock(sys::lastError());
      }
    }

    releaseForward(forward, false);
  }

  bool Link::stillOpen(HeldForward held) noexcept {
    const std::scoped_lock lock{mutex_};
    const auto& forward = forwards_[held.index];

    if (!forward.used || forward.generation != held.generation || forward.holders == 0) {
      return false;
    }

    // A watch that ended, with the forward before this one or with a gateway that was lost
    // for a while, starts again: it is what tells this forward its port closed there.
    const Endpoint endpoint = forward.endpoint;

    if (const auto machine = machineSlot(endpoint)) {
      watchMachine(*machine);
    }

    return true;
  }

  void Link::carry(int socket, const Accepted& accepted) {
    Endpoint endpoint;
    std::uint16_t port = 0;

    {
      const std::scoped_lock lock{mutex_};
      auto& forward = forwards_.atMut(accepted.index);

      if (!forward.used || forward.generation != accepted.generation || forward.holders == 0) {
        return;
      }

      endpoint = forward.endpoint;
      port = forward.remote;
      ++forward.connections;
    }

    ds::Option<Reply> reply;

    try {
      auto channel = Channel::dial(contexts_, endpoint, Service::forward, Clock::now() + dial_timeout);

      // The connection's first bytes follow the request at once; the gateway's answer comes
      // back ahead of the port's.
      if (sendPort(channel, port)) {
        reply = relayOnceAnswered(channel, socket);
      }
    } catch (const ChannelFailure&) {
      // A gateway that cannot be reached says nothing of the port; the forward stays.
      reply = ds::none;
    }

    {
      const std::scoped_lock lock{mutex_};
      auto& forward = forwards_.atMut(accepted.index);

      forward.connections -= std::min(forward.connections, 1U);
      if (forward.connections == 0 && !forward.listener) {
        forward.used = false;
      }
    }

    // The gateway refuses a port nothing listens on any more, which closes the forward here.
    if (reply == Reply::refused) {
      releaseForward({.index = accepted.index, .generation = accepted.generation}, true);
    }
  }

  void Link::requestPorts(int socket, std::string_view destination) {
    Endpoint endpoint;
    Text<maximum_forwards*(origin_bytes + ports_row_bytes)> text;

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
        text.append(forward.automatic ? " shared " : " asked ");
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

      return socket && writeAll(socket.get(), "ping\n") && readLine(socket.get(), line.viewMut(), Clock::now() + request_timeout) == std::string_view{"ok"};
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

    const auto reply = readLine(socket.get(), line.viewMut(), Clock::now() + reply_timeout);
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

    const auto reply = readLine(socket.get(), line.viewMut(), Clock::now() + reply_timeout);
    if (!reply || !reply->starts_with("ok ")) {
      Text<line_bytes> message;

      message.append("telar gateway: ");
      message.append(reply ? runtime::textAfter(*reply, refusal_prefix.size()) : std::string_view{"the gateway link did not answer"});
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

    // Holding the connection holds the forward; the link ends it when the port closes there,
    // and says so. A link that ends without a word was stopped or lost.
    while (!waitReady(socket.get(), POLLIN, Clock::now() + reply_timeout)) {
    }

    if (readLine(socket.get(), line.viewMut(), Clock::now() + reply_timeout) == std::string_view{"closed"}) {
      return 0;
    }

    static_cast<void>(writeAll(STDERR_FILENO, "telar gateway: the gateway link ended\n"));
    return 1;
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

    while (const auto row = readLine(socket.get(), line.viewMut(), Clock::now() + request_timeout)) {
      Text<line_bytes> text;

      text.append(*row);
      text.append("\n");
      if (!writeAll(output, text.view())) {
        return 1;
      }
    }

    return 0;
  }

  FileDescriptor LinkClient::hold(const LinkPaths& paths, std::string_view destination) noexcept {
    try {
      Line line{};
      Text<line_bytes> request;
      auto socket = connectUnix(paths.control().view());

      request.append("hold ");
      request.append(destination);
      request.append("\n");
      if (socket && writeAll(socket.get(), request.view()) && readLine(socket.get(), line.viewMut(), Clock::now() + request_timeout) == std::string_view{"ok"}) {
        return socket;
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): without a link nothing is held, which the caller is told
    }

    return FileDescriptor{};
  }

  FileDescriptor LinkClient::run(const LinkPaths& paths, std::string_view destination) noexcept {
    try {
      Line line{};
      Text<line_bytes> request;
      auto socket = connectUnix(paths.control().view());

      request.append("run ");
      request.append(destination);
      request.append("\n");
      if (socket && writeAll(socket.get(), request.view()) && readLine(socket.get(), line.viewMut(), Clock::now() + reply_timeout) == std::string_view{"ok"}) {
        return socket;
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): without a link the caller connects by itself
    }

    return FileDescriptor{};
  }

  void LinkClient::stop(const LinkPaths& paths) noexcept {
    try {
      Line line{};
      const auto socket = connectUnix(paths.control().view());

      if (socket && writeAll(socket.get(), "stop\n")) {
        static_cast<void>(readLine(socket.get(), line.viewMut(), Clock::now() + request_timeout));
      }
    } catch (const std::exception&) {
      // No link runs where the path cannot even be formed.
      return;
    }
  }

  int runRemote(const State& state, const RemoteCommand& remote) noexcept {
    try {
      const auto endpoint = Endpoint::parse(remote.destination);
      // Through the link the command may find a connection already made to its machine; without
      // one it makes its own.
      auto through = remote.link != nullptr ? LinkClient::run(*remote.link, remote.destination) : FileDescriptor{};
      ds::Option<Identity> identity;
      ds::Option<Contexts> contexts;
      ds::Option<Channel> connection;

      if (through) {
        connection.emplace(Channel::local(std::move(through), Service::run));
      } else {
        identity.emplace(Identity::loadOrCreate(state.directory()));
        contexts.emplace(*identity);
        connection.emplace(Channel::dial(*contexts, endpoint, Service::run, Clock::now() + dial_timeout));
      }

      auto& channel = connection.getMut();
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

  int attachRemote(const State& state, std::string_view destination, int socket) noexcept {
    try {
      const auto endpoint = Endpoint::parse(destination);
      const auto identity = Identity::loadOrCreate(state.directory());
      const Contexts contexts{identity};
      auto channel = Channel::dial(contexts, endpoint, Service::attach, Clock::now() + dial_timeout);

      runtime::configureProxySocket(socket);
      // What the window has to say travels with the handshake's last flight instead of waiting a
      // round trip for the gateway's answer.
      const auto reply = relayOnceAnswered(channel, socket);
      if (reply != Reply::accepted) {
        Text<LinkClient::line_bytes> message;

        message.append("telar gateway: ");
        message.append(reply == Reply::refused ? describe(Reply::refused) : "the runtime there could not be reached or started");
        message.append("\n");
        static_cast<void>(writeAll(STDERR_FILENO, message.view()));
        return reply == Reply::refused ? connection_lost_status : 1;
      }

      return 0;
    } catch (const std::exception& failure) {
      Text<LinkClient::line_bytes> message;

      message.append("telar gateway: ");
      message.append(failure.what());
      message.append("\n");
      static_cast<void>(writeAll(STDERR_FILENO, message.view()));
      return connection_lost_status;
    }
  }

  Endpoint::Text enroll(const State& state, const Enrollment& enrollment) {
    const auto endpoint = Endpoint::parse(enrollment.address);
    if (!endpoint.secret) {
      throw std::invalid_argument{"Expected a pairing address, as `telar server pair` prints it"};
    }

    const auto identity = Identity::loadOrCreate(state.directory());
    const Contexts contexts{identity};
    auto channel = Channel::dial(contexts, endpoint, Service::pair, Clock::now() + dial_timeout);
    ds::Array<std::uint8_t, secret_bytes + 1 + AuthorizedClients::name_bytes> request{};
    const auto length = std::min(enrollment.name.size(), AuthorizedClients::name_bytes);

    std::ranges::copy(endpoint.secret->view(), request.viewMut().begin());
    request.atMut(secret_bytes) = static_cast<std::uint8_t>(length);
    std::ranges::copy(enrollment.name.substr(0, length), request.viewMut().subspan(secret_bytes + 1).begin());
    channel.send(request.view().first(secret_bytes + 1 + length), Clock::now() + exchange_timeout);
    if (receiveReply(channel) != Reply::accepted) {
      throw ChannelFailure{"The gateway refused the pairing code: it was used, it expired or it was mistyped"};
    }

    return endpoint.destination();
  }

}
