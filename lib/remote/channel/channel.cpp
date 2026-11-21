module telar.remote.channel;

import telar.platform.error;
import telar.platform.fs;
import telar.platform.net;
import telar.sys.posix;

namespace telar::remote {

  using runtime::FileDescriptor;
  using runtime::SystemError;

  namespace {

    constexpr ds::Array<std::string_view, service_count> service_names{
        "telar-attach/1",
        "telar-run/1",
        "telar-forward/1",
        "telar-ports/1",
        "telar-pair/1",
    };

    // The longest ALPN name a client offers, with its length byte.
    constexpr std::size_t offer_bytes = 32;

    constexpr int listen_backlog = 64;

    // A dead peer is noticed after this long without an answer: the idle time before the first
    // probe, then `keepalive_probes` of them `keepalive_interval` apart.
    constexpr int keepalive_idle = 30;
    constexpr int keepalive_interval = 10;
    constexpr int keepalive_probes = 3;

    void setOption(int socket, int level, int option, int value) noexcept {
      static_cast<void>(::setsockopt(socket, level, option, &value, sizeof(value)));
    }

    // A terminal's keystrokes are small and must not wait for more to fill a segment, and a
    // peer that vanished must not hold its connection open.
    void tuneTcp(int socket) noexcept {
      setOption(socket, IPPROTO_TCP, TCP_NODELAY, 1);
      setOption(socket, SOL_SOCKET, SO_KEEPALIVE, 1);
      setOption(socket, IPPROTO_TCP, sys::tcp_keepalive_idle, keepalive_idle);
      setOption(socket, IPPROTO_TCP, TCP_KEEPINTVL, keepalive_interval);
      setOption(socket, IPPROTO_TCP, TCP_KEEPCNT, keepalive_probes);
    }

    // Readies a connected or accepted socket for a relay; false when its peer already left.
    bool prepare(int socket) noexcept {
      try {
        runtime::configureProxySocket(socket);
      } catch (const SystemError&) {
        return false;
      }

      return true;
    }

    // Finishes a nonblocking connect; false when it failed or the deadline passed.
    bool connected(int socket, Clock::time_point deadline) noexcept {
      if (!waitReady(socket, POLLOUT, deadline)) {
        return false;
      }

      int error = 0;
      socklen_t length = sizeof(error);

      return ::getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
    }

    FileDescriptor connectAddress(const sockaddr* address, socklen_t length, Clock::time_point deadline) noexcept {
      FileDescriptor socket{::socket(address->sa_family, SOCK_STREAM, IPPROTO_TCP)};
      if (!socket || !prepare(socket.get())) {
        return FileDescriptor{};
      }

      if (::connect(socket.get(), address, length) != 0 && (sys::lastError() != EINPROGRESS || !connected(socket.get(), deadline))) {
        return FileDescriptor{};
      }

      tuneTcp(socket.get());
      return socket;
    }

    sockaddr_un unixAddress(std::string_view path) {
      sockaddr_un address{};

      if (path.empty() || path.front() != '/' || path.size() >= sizeof(address.sun_path)) {
        throw SystemError{"Invalid gateway socket path", ENAMETOOLONG};
      }

      address.sun_family = AF_UNIX;
      std::ranges::copy(path, std::span{address.sun_path}.begin());
      return address;
    }

    const sockaddr* generic(const sockaddr_un& address) noexcept {
      return reinterpret_cast<const sockaddr*>(&address); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    }

    // Accepts whatever certificate the peer presents: each end names the other by its key once
    // the handshake is over, so no chain is followed.
    int acceptAnyCertificate(X509_STORE_CTX* /*certificates*/, void* /*argument*/) noexcept {
      return 1;
    }

    // Answers with the first service the client offers that this gateway knows.
    int selectService(SSL* /*connection*/, const unsigned char** selected, unsigned char* length, const unsigned char* offered, unsigned offered_length, void* /*argument*/) noexcept { // NOLINT(readability-function-size): OpenSSL's ALPN callback takes six parameters
#pragma clang unsafe_buffer_usage begin
      // OpenSSL hands the offer as a pointer and its length.
      std::span<const unsigned char> names{offered, offered_length};
#pragma clang unsafe_buffer_usage end

      while (!names.empty()) {
        const auto size = names.front();

        names = names.subspan(1);
        if (size > names.size()) {
          return SSL_TLSEXT_ERR_ALERT_FATAL;
        }

        const std::string_view name{reinterpret_cast<const char*>(names.data()), size}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ALPN names are ASCII text
        if (namedService(name)) {
          // The offer outlives the callback's use of it: OpenSSL copies the selection.
          *selected = names.data();
          *length = size;
          return SSL_TLSEXT_ERR_OK;
        }

        names = names.subspan(size);
      }

      return SSL_TLSEXT_ERR_ALERT_FATAL;
    }

    runtime::TlsContext makeContext(const auto* method, const Identity& identity) {
      runtime::TlsContext context{SSL_CTX_new(method)};

      runtime::requireTls(context != nullptr, "Allocate the gateway TLS context");
      runtime::requireTls(SSL_CTX_set_min_proto_version(context.get(), TLS1_3_VERSION) == 1 && SSL_CTX_set_max_proto_version(context.get(), TLS1_3_VERSION) == 1, "Require TLS 1.3");
      runtime::requireTls(SSL_CTX_use_certificate(context.get(), identity.pair.certificate.get()) == 1 && SSL_CTX_use_PrivateKey(context.get(), identity.pair.key.get()) == 1, "Load the gateway identity");
      SSL_CTX_set_cert_verify_callback(context.get(), &acceptAnyCertificate, nullptr);
      SSL_CTX_set_options(context.get(), SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
      SSL_CTX_set_mode(context.get(), static_cast<long>(SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER));
      SSL_CTX_set_session_cache_mode(context.get(), SSL_SESS_CACHE_OFF);
      return context;
    }

    // One direction of a relay: the bytes read from one side and not yet written to the other.
    struct Half {
      static constexpr std::size_t capacity = std::size_t{64} * 1024;

      ds::Array<std::uint8_t, capacity> bytes;
      std::size_t begin = 0;
      std::size_t end = 0;
      // The source has no more to send.
      bool ended = false;
      // The sink was told so.
      bool closed = false;

      [[nodiscard]] bool empty() const noexcept {
        return begin == end;
      }

      [[nodiscard]] std::span<const std::uint8_t> pending() const noexcept {
        return bytes.view().subspan(begin, end - begin);
      }

      void filled(std::size_t count) noexcept {
        begin = 0;
        end = count;
      }

      void drained(std::size_t count) noexcept {
        begin += count;
      }
    };

    // What a relay waits for when no direction can move.
    struct Interest {
      short channel = 0;
      short local = 0;

      void note(Transfer::State state) noexcept {
        if (state == Transfer::State::wants_read) {
          channel = static_cast<short>(channel | POLLIN);
        } else if (state == Transfer::State::wants_write) {
          channel = static_cast<short>(channel | POLLOUT);
        }
      }
    };

    enum class Step : std::uint8_t {
      idle,
      moved,
      failed,
    };

    // Moves what it can from the channel to the local socket. While `answer` is awaited, the
    // first byte the channel delivers is the gateway's answer and is kept from the socket; an
    // answer other than `accepted` ends the relay.
    Step pumpDown(Channel& channel, int local, Half& half, Interest& interest, ds::Option<Reply>* answer = nullptr) noexcept {
      Step step = Step::idle;

      if (!half.ended && half.empty()) {
        const auto read = channel.read(half.bytes.viewMut());
        if (read.state == Transfer::State::failed) {
          return Step::failed;
        }

        if (read.state == Transfer::State::done) {
          half.filled(read.bytes);
          step = Step::moved;
          if (answer != nullptr && !answer->hasValue()) {
            const auto byte = half.bytes[0];

            *answer = byte <= static_cast<std::uint8_t>(Reply::unavailable) ? static_cast<Reply>(byte) : Reply::unavailable;
            half.drained(1);
            if (*answer != Reply::accepted) {
              return Step::failed;
            }
          }
        } else if (read.state == Transfer::State::ended) {
          half.ended = true;
          step = Step::moved;
        } else {
          interest.note(read.state);
        }
      }

      if (!half.empty()) {
        const auto pending = half.pending();
        const auto written = ::write(local, pending.data(), pending.size());
        if (written > 0) {
          half.drained(static_cast<std::size_t>(written));
          step = Step::moved;
        } else if (runtime::socketWouldBlock(sys::lastError())) {
          interest.local = static_cast<short>(interest.local | POLLOUT);
        } else {
          return Step::failed;
        }
      }

      if (half.ended && half.empty() && !half.closed) {
        static_cast<void>(::shutdown(local, SHUT_WR));
        half.closed = true;
        step = Step::moved;
      }

      return step;
    }

    // Moves what it can from the local socket to the channel.
    Step pumpUp(Channel& channel, int local, Half& half, Interest& interest) noexcept {
      Step step = Step::idle;

      if (!half.ended && half.empty()) {
        const auto read = ::read(local, half.bytes.dataMut(), half.bytes.size());
        if (read > 0) {
          half.filled(static_cast<std::size_t>(read));
          step = Step::moved;
        } else if (read == 0) {
          half.ended = true;
          step = Step::moved;
        } else if (runtime::socketWouldBlock(sys::lastError())) {
          interest.local = static_cast<short>(interest.local | POLLIN);
        } else {
          return Step::failed;
        }
      }

      if (!half.empty()) {
        const auto written = channel.write(half.pending());
        if (written.state == Transfer::State::failed || written.state == Transfer::State::ended) {
          return Step::failed;
        }

        if (written.state == Transfer::State::done) {
          half.drained(written.bytes);
          step = Step::moved;
        } else {
          interest.note(written.state);
        }
      }

      if (half.ended && half.empty() && !half.closed) {
        const auto finished = channel.finish();
        if (finished.state == Transfer::State::failed) {
          return Step::failed;
        }

        if (finished.state == Transfer::State::done) {
          half.closed = true;
          step = Step::moved;
        } else {
          interest.note(finished.state);
        }
      }

      return step;
    }

  }

  std::string_view serviceName(Service service) noexcept {
    return service_names[static_cast<std::size_t>(service)];
  }

  ds::Option<Service> namedService(std::string_view name) noexcept {
    for (std::size_t index = 0; index < service_names.size(); ++index) {
      if (service_names[index] == name) {
        return static_cast<Service>(index);
      }
    }

    return ds::none;
  }

  ChannelFailure::ChannelFailure(const char* what) noexcept
      : what_(what) {}

  const char* ChannelFailure::what() const noexcept {
    return what_;
  }

  int pollTimeout(Clock::time_point deadline) noexcept {
    const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();

    return static_cast<int>(std::clamp<std::int64_t>(left, 0, std::numeric_limits<int>::max()));
  }

  Listener listenTcp(std::string_view host, std::uint16_t port) {
    runtime::NetworkAddress address = runtime::NetworkAddress::ipv6(in6_addr{}, port);
    bool every_family = host.empty();

    if (!host.empty()) {
      ds::Array<char, Endpoint::host_bytes + 1> name{};
      addrinfo hints{};
      addrinfo* found = nullptr;

      if (host.size() >= name.size()) {
        throw SystemError{"Invalid gateway listen address", EINVAL};
      }

      std::ranges::copy(host, name.viewMut().begin());
      hints.ai_family = AF_UNSPEC;
      hints.ai_socktype = SOCK_STREAM;
      hints.ai_flags = AI_PASSIVE;
      if (::getaddrinfo(name.data(), nullptr, &hints, &found) != 0 || found == nullptr) {
        throw SystemError{"Resolve the gateway listen address", EADDRNOTAVAIL};
      }

      const auto copied = runtime::NetworkAddress::copy(found->ai_addr, found->ai_addrlen);

      ::freeaddrinfo(found);
      if (!copied) {
        throw SystemError{"Resolve the gateway listen address", EAFNOSUPPORT};
      }

      address = *copied;
      address.setPort(port);
    }

    FileDescriptor socket{::socket(address.storage.ss_family, SOCK_STREAM, IPPROTO_TCP)};
    if (!socket && every_family) {
      // A machine without IPv6 listens on every IPv4 address instead.
      every_family = false;
      address = runtime::NetworkAddress::ipv4(in_addr{}, port);
      socket.reset(::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    }

    if (!socket) {
      throw SystemError{"Create the gateway listener"};
    }

    runtime::configureProxySocket(socket.get());
    setOption(socket.get(), SOL_SOCKET, SO_REUSEADDR, 1);
    if (every_family) {
      // One socket answers both families.
      setOption(socket.get(), IPPROTO_IPV6, IPV6_V6ONLY, 0);
    }

    if (::bind(socket.get(), address.address(), address.length) != 0 || ::listen(socket.get(), listen_backlog) != 0) {
      throw SystemError{"Listen on the gateway address"};
    }

    sockaddr_storage bound{};
    socklen_t length = sizeof(bound);

    if (::getsockname(socket.get(), reinterpret_cast<sockaddr*>(&bound), &length) != 0) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
      throw SystemError{"Read the gateway listener's port"};
    }

    const auto bound_port = bound.ss_family == AF_INET6
                                ? reinterpret_cast<const sockaddr_in6*>(&bound)->sin6_port // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the family names the address type
                                : reinterpret_cast<const sockaddr_in*>(&bound)->sin_port;  // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the family names the address type

    return {.socket = std::move(socket), .port = ntohs(bound_port)};
  }

  FileDescriptor connectTcp(std::string_view host, std::uint16_t port, Clock::time_point deadline) noexcept {
    ds::Array<char, Endpoint::host_bytes + 1> name{};
    ds::Array<char, Endpoint::port_digits + 1> service{};
    addrinfo hints{};
    addrinfo* found = nullptr;

    if (host.empty() || host.size() >= name.size()) {
      return FileDescriptor{};
    }

    std::ranges::copy(host, name.viewMut().begin());
    static_cast<void>(std::to_chars(service.dataMut(), service.dataMut() + Endpoint::port_digits, port));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (::getaddrinfo(name.data(), service.data(), &hints, &found) != 0) {
      return FileDescriptor{};
    }

    FileDescriptor socket;

    for (const auto* candidate = found; candidate != nullptr && !socket; candidate = candidate->ai_next) {
      socket = connectAddress(candidate->ai_addr, candidate->ai_addrlen, deadline);
    }

    ::freeaddrinfo(found);
    return socket;
  }

  FileDescriptor connectLoopback(std::uint16_t port, Clock::time_point deadline) noexcept {
    const auto six = runtime::NetworkAddress::ipv6(in6addr_loopback, port);
    auto socket = connectAddress(six.address(), six.length, deadline);

    if (!socket) {
      const auto four = runtime::NetworkAddress::ipv4(in_addr{.s_addr = htonl(INADDR_LOOPBACK)}, port);

      socket = connectAddress(four.address(), four.length, deadline);
    }

    return socket;
  }

  FileDescriptor listenUnix(std::string_view path) {
    constexpr mode_t owner_only = 0600;
    const auto address = unixAddress(path);
    // The socket's directory must be the user's own, as the runtime's is.
    const auto parent = runtime::openPrivateParent(path);
    FileDescriptor socket{::socket(AF_UNIX, SOCK_STREAM, 0)};

    if (!socket) {
      throw SystemError{"Create the gateway socket"};
    }

    runtime::configureProxySocket(socket.get());
    if (::bind(socket.get(), generic(address), sizeof(address)) != 0) {
      if (sys::lastError() != EADDRINUSE || connectUnix(path)) {
        throw SystemError{"Bind the gateway socket", EADDRINUSE};
      }

      // Nobody listens on the socket a gateway that died left behind.
      if (::unlink(address.sun_path) != 0 || ::bind(socket.get(), generic(address), sizeof(address)) != 0) {
        throw SystemError{"Replace the stale gateway socket"};
      }
    }

    if (::chmod(address.sun_path, owner_only) != 0 || ::listen(socket.get(), listen_backlog) != 0) {
      throw SystemError{"Listen on the gateway socket"};
    }

    return socket;
  }

  FileDescriptor connectUnix(std::string_view path) noexcept {
    sockaddr_un address{};

    if (path.empty() || path.size() >= sizeof(address.sun_path)) {
      return FileDescriptor{};
    }

    address.sun_family = AF_UNIX;
    std::ranges::copy(path, std::span{address.sun_path}.begin());
    FileDescriptor socket{::socket(AF_UNIX, SOCK_STREAM, 0)};

    // A local connect completes or fails at once, so it is made before the socket stops blocking.
    if (!socket || ::connect(socket.get(), generic(address), sizeof(address)) != 0 || !prepare(socket.get())) {
      return FileDescriptor{};
    }

    return socket;
  }

  FileDescriptor acceptConnection(int listener) noexcept {
    FileDescriptor connection{::accept(listener, nullptr, nullptr)};

    if (!connection || !prepare(connection.get())) {
      return FileDescriptor{};
    }

    return connection;
  }

  bool waitReady(int descriptor, short events, Clock::time_point deadline) noexcept {
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

  bool writeText(int descriptor, std::string_view text, Clock::time_point deadline) noexcept {
    while (!text.empty()) {
      const auto written = ::write(descriptor, text.data(), text.size());
      if (written > 0) {
        text.remove_prefix(static_cast<std::size_t>(written));
      } else if (!runtime::socketWouldBlock(sys::lastError()) || !waitReady(descriptor, POLLOUT, deadline)) {
        return false;
      }
    }

    return true;
  }

  ds::Option<std::string_view> readLine(int descriptor, std::span<char> line, Clock::time_point deadline) noexcept {
    std::size_t length = 0;

    while (length < line.size()) {
      char byte = 0;
      const auto count = ::read(descriptor, &byte, 1);
      if (count == 1) {
        if (byte == '\n') {
          return std::string_view{line.data(), length};
        }

        line[length++] = byte;
      } else if (count == 0 || !runtime::socketWouldBlock(sys::lastError()) || !waitReady(descriptor, POLLIN, deadline)) {
        return ds::none;
      }
    }

    return ds::none;
  }

  Contexts::Contexts(const Identity& identity)
      : server_(makeContext(TLS_server_method(), identity)),
        client_(makeContext(TLS_client_method(), identity)) {
    // A gateway asks every client for its certificate; a client always checks the gateway's.
    SSL_CTX_set_verify(server_.get(), SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nullptr);
    SSL_CTX_set_verify(client_.get(), SSL_VERIFY_PEER, nullptr);
    SSL_CTX_set_alpn_select_cb(server_.get(), &selectService, nullptr);
    runtime::requireTls(SSL_CTX_set_num_tickets(server_.get(), 0) == 1, "Disable TLS session tickets");
  }

  SSL_CTX* Contexts::server() const noexcept {
    return server_.get();
  }

  SSL_CTX* Contexts::client() const noexcept {
    return client_.get();
  }

  Channel::Channel(FileDescriptor socket, runtime::TlsConnection connection) noexcept
      : socket_(std::move(socket)),
        connection_(std::move(connection)) {}

  Channel Channel::accept(const Contexts& contexts, FileDescriptor socket, Clock::time_point deadline) {
    runtime::TlsConnection connection{SSL_new(contexts.server())};

    if (!connection || SSL_set_fd(connection.get(), socket.get()) != 1) {
      throw ChannelFailure{"Allocate the TLS connection"};
    }

    tuneTcp(socket.get());
    SSL_set_accept_state(connection.get());
    Channel channel{std::move(socket), std::move(connection)};

    channel.handshake(deadline);
    channel.identifyPeer();
    const unsigned char* name = nullptr;
    unsigned length = 0;

    SSL_get0_alpn_selected(channel.connection_.get(), &name, &length);
    const auto service = namedService({reinterpret_cast<const char*>(name), length}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ALPN names are ASCII text
    if (!service) {
      throw ChannelFailure{"The client asked for no service"};
    }

    channel.service_ = *service;
    return channel;
  }

  Channel Channel::dial(const Contexts& contexts, const Endpoint& endpoint, Service service, Clock::time_point deadline) {
    auto socket = connectTcp(endpoint.host.view(), endpoint.port, deadline);
    if (!socket) {
      throw ChannelFailure{"The gateway does not answer at its address"};
    }

    runtime::TlsConnection connection{SSL_new(contexts.client())};
    ds::Array<unsigned char, offer_bytes> offer{};
    const auto name = serviceName(service);

    offer.atMut(0) = static_cast<unsigned char>(name.size());
    std::ranges::copy(name, offer.viewMut().subspan(1).begin());
    if (!connection || SSL_set_fd(connection.get(), socket.get()) != 1 || SSL_set_alpn_protos(connection.get(), offer.data(), static_cast<unsigned>(name.size() + 1)) != 0) {
      throw ChannelFailure{"Allocate the TLS connection"};
    }

    SSL_set_connect_state(connection.get());
    Channel channel{std::move(socket), std::move(connection)};

    channel.handshake(deadline);
    channel.identifyPeer();
    if (!sameBytes(channel.peer_.view(), endpoint.key.view())) {
      throw ChannelFailure{"The gateway holds another key than the one its address pins"};
    }

    const unsigned char* selected = nullptr;
    unsigned length = 0;

    SSL_get0_alpn_selected(channel.connection_.get(), &selected, &length);
    if (std::string_view{reinterpret_cast<const char*>(selected), length} != name) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ALPN names are ASCII text
      throw ChannelFailure{"The gateway does not offer the service"};
    }

    channel.service_ = service;
    return channel;
  }

  Channel Channel::local(FileDescriptor socket, Service service) noexcept {
    Channel channel{std::move(socket), runtime::TlsConnection{}};

    channel.service_ = service;
    return channel;
  }

  bool Channel::disturbed() const noexcept {
    pollfd entry{.fd = socket_.get(), .events = POLLIN, .revents = 0};

    return buffered() || ::poll(&entry, 1, 0) != 0;
  }

  Service Channel::service() const noexcept {
    return service_;
  }

  const PublicKey& Channel::peer() const noexcept {
    return peer_;
  }

  int Channel::descriptor() const noexcept {
    return socket_.get();
  }

  void Channel::handshake(Clock::time_point deadline) {
    for (;;) {
      ERR_clear_error();
      const int status = SSL_do_handshake(connection_.get());
      if (status == 1) {
        return;
      }

      const int error = SSL_get_error(connection_.get(), status);
      if (error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) {
        throw ChannelFailure{"The TLS handshake failed"};
      }

      if (!waitReady(socket_.get(), error == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT, deadline)) {
        throw ChannelFailure{"The TLS handshake timed out"};
      }
    }
  }

  void Channel::identifyPeer() {
    const runtime::TlsCertificate certificate{SSL_get1_peer_certificate(connection_.get())};

    if (!certificate) {
      throw ChannelFailure{"The peer presented no key"};
    }

    peer_ = runtime::publicKeyDigest(certificate.get());
  }

  Transfer Channel::result(int status, std::size_t bytes) noexcept {
    if (status == 1) {
      return {.state = Transfer::State::done, .bytes = bytes};
    }

    switch (SSL_get_error(connection_.get(), status)) {
    case SSL_ERROR_WANT_READ:
      return {.state = Transfer::State::wants_read};
    case SSL_ERROR_WANT_WRITE:
      return {.state = Transfer::State::wants_write};
    case SSL_ERROR_ZERO_RETURN:
      return {.state = Transfer::State::ended};
    default:
      return {.state = Transfer::State::failed};
    }
  }

  namespace {

    // What a read or a write of a local socket did, as a channel reports it.
    Transfer localResult(ssize_t count, bool reading) noexcept {
      if (count > 0) {
        return {.state = Transfer::State::done, .bytes = static_cast<std::size_t>(count)};
      }

      if (count == 0 && reading) {
        return {.state = Transfer::State::ended};
      }

      if (runtime::socketWouldBlock(sys::lastError())) {
        return {.state = reading ? Transfer::State::wants_read : Transfer::State::wants_write};
      }

      return {.state = Transfer::State::failed};
    }

  }

  Transfer Channel::read(std::span<std::uint8_t> bytes) noexcept {
    std::size_t count = 0;

    if (!connection_) {
      return localResult(::read(socket_.get(), bytes.data(), bytes.size()), true);
    }

    ERR_clear_error();
    return result(SSL_read_ex(connection_.get(), bytes.data(), bytes.size(), &count), count);
  }

  Transfer Channel::write(std::span<const std::uint8_t> bytes) noexcept {
    std::size_t count = 0;

    if (!connection_) {
      return localResult(::write(socket_.get(), bytes.data(), bytes.size()), false);
    }

    ERR_clear_error();
    return result(SSL_write_ex(connection_.get(), bytes.data(), bytes.size(), &count), count);
  }

  Transfer Channel::finish() noexcept {
    if (!connection_) {
      static_cast<void>(::shutdown(socket_.get(), SHUT_WR));
      return {};
    }

    ERR_clear_error();
    const int status = SSL_shutdown(connection_.get());

    // Zero says the notice went out and the peer's has not come yet, which is all this end awaits.
    return status >= 0 ? Transfer{} : result(status, 0);
  }

  bool Channel::buffered() const noexcept {
    return connection_ && SSL_pending(connection_.get()) > 0;
  }

  void Channel::send(std::span<const std::uint8_t> bytes, Clock::time_point deadline) {
    while (!bytes.empty()) {
      const auto written = write(bytes);
      if (written.state == Transfer::State::done) {
        bytes = bytes.subspan(written.bytes);
        continue;
      }

      if (written.state != Transfer::State::wants_read && written.state != Transfer::State::wants_write) {
        throw ChannelFailure{"The connection to the gateway broke"};
      }

      if (!waitReady(socket_.get(), written.state == Transfer::State::wants_read ? POLLIN : POLLOUT, deadline)) {
        throw ChannelFailure{"The gateway stopped answering"};
      }
    }
  }

  void Channel::receive(std::span<std::uint8_t> bytes, Clock::time_point deadline) {
    while (!bytes.empty()) {
      const auto taken = read(bytes);
      if (taken.state == Transfer::State::done) {
        bytes = bytes.subspan(taken.bytes);
        continue;
      }

      if (taken.state != Transfer::State::wants_read && taken.state != Transfer::State::wants_write) {
        throw ChannelFailure{"The connection to the gateway broke"};
      }

      if (!waitReady(socket_.get(), taken.state == Transfer::State::wants_read ? POLLIN : POLLOUT, deadline)) {
        throw ChannelFailure{"The gateway stopped answering"};
      }
    }
  }

  void conclude(Channel& channel) noexcept {
    constexpr auto patience = std::chrono::seconds{2};
    ds::Array<std::uint8_t, 512> discarded{};
    const auto deadline = Clock::now() + patience;

    static_cast<void>(channel.finish());
    for (;;) {
      const auto taken = channel.read(discarded.viewMut());
      if (taken.state == Transfer::State::done) {
        continue;
      }

      const bool waits = taken.state == Transfer::State::wants_read || taken.state == Transfer::State::wants_write;
      if (!waits || !waitReady(channel.descriptor(), taken.state == Transfer::State::wants_read ? POLLIN : POLLOUT, deadline)) {
        return;
      }
    }
  }

  namespace {

    // Carries both directions until each has ended or either fails; with `answer`, the first
    // byte from the channel is taken as the gateway's answer.
    void carry(Channel& channel, int local, ds::Option<Reply>* answer) noexcept {
      // The buffers of both directions are this call's own: a relay runs on a thread whose stack
      // is sized to hold them.
      Half down;
      Half up;

      while (!down.closed || !up.closed) {
        Interest interest;
        const auto moved_down = pumpDown(channel, local, down, interest, answer);
        const auto moved_up = pumpUp(channel, local, up, interest);

        if (moved_down == Step::failed || moved_up == Step::failed) {
          return;
        }

        if (moved_down == Step::moved || moved_up == Step::moved) {
          continue;
        }

        ds::Array<pollfd, 2> entries{
            pollfd{.fd = channel.descriptor(), .events = interest.channel, .revents = 0},
            pollfd{.fd = local, .events = interest.local, .revents = 0},
        };

        if (::poll(entries.dataMut(), entries.size(), -1) < 0 && sys::lastError() != EINTR) {
          return;
        }
      }
    }

  }

  ds::Option<Reply> relayOnceAnswered(Channel& channel, int local) noexcept {
    ds::Option<Reply> answer;

    carry(channel, local, &answer);
    return answer;
  }

  void relay(Channel& channel, int local) noexcept {
    carry(channel, local, nullptr);
  }

  void sendReply(Channel& channel, Reply reply) {
    const ds::Array<std::uint8_t, 1> byte{static_cast<std::uint8_t>(reply)};

    channel.send(byte.view(), Clock::now() + exchange_timeout);
  }

  Reply receiveReply(Channel& channel) {
    ds::Array<std::uint8_t, 1> byte{};

    channel.receive(byte.viewMut(), Clock::now() + exchange_timeout);
    return byte[0] <= static_cast<std::uint8_t>(Reply::unavailable) ? static_cast<Reply>(byte[0]) : Reply::unavailable;
  }

  void PortNotice::send(Channel& channel) const {
    constexpr unsigned byte_bits = 8;
    constexpr unsigned byte_mask = 0xff;
    ds::Array<std::uint8_t, maximum_bytes> frame{};
    const auto text = origin.view();

    frame.atMut(0) = static_cast<std::uint8_t>(kind);
    frame.atMut(1) = static_cast<std::uint8_t>(port >> byte_bits);
    frame.atMut(2) = static_cast<std::uint8_t>(port & byte_mask);
    frame.atMut(3) = static_cast<std::uint8_t>(text.size());
    std::ranges::copy(text, frame.viewMut().subspan(header_bytes).begin());
    channel.send(frame.view().first(header_bytes + text.size()), Clock::now() + exchange_timeout);
  }

  bool PortNotices::receive(Channel& channel) noexcept {
    for (;;) {
      if (begin_ == end_) {
        begin_ = 0;
        end_ = 0;
      } else if (begin_ != 0) {
        std::memmove(bytes_.dataMut(), bytes_.data() + begin_, end_ - begin_);
        end_ -= begin_;
        begin_ = 0;
      }

      if (end_ == bytes_.size()) {
        return true;
      }

      const auto taken = channel.read(bytes_.viewMut().subspan(end_));
      if (taken.state != Transfer::State::done) {
        return taken.state == Transfer::State::wants_read || taken.state == Transfer::State::wants_write;
      }

      end_ += taken.bytes;
    }
  }

  ds::Option<PortNotice> PortNotices::next() noexcept {
    constexpr unsigned byte_bits = 8;
    const auto pending = bytes_.view().subspan(begin_, end_ - begin_);

    if (pending.size() < PortNotice::header_bytes) {
      return ds::none;
    }

    const std::size_t length = pending[3];
    if (length > PortNotice::origin_bytes || pending[0] < static_cast<std::uint8_t>(PortNotice::Kind::watch) || pending[0] > static_cast<std::uint8_t>(PortNotice::Kind::closed)) {
      // A frame no gateway sends: what follows cannot be read either, so it is all dropped.
      begin_ = end_;
      return ds::none;
    }

    if (pending.size() < PortNotice::header_bytes + length) {
      return ds::none;
    }

    PortNotice notice{
        .kind = static_cast<PortNotice::Kind>(pending[0]),
        .port = static_cast<std::uint16_t>((static_cast<unsigned>(pending[1]) << byte_bits) | pending[2]),
    };

    notice.origin.assign({reinterpret_cast<const char*>(pending.data() + PortNotice::header_bytes), length}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the origin's bytes are read as text
    begin_ += PortNotice::header_bytes + length;
    return notice;
  }

}
