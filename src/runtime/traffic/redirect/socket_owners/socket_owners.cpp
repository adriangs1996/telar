module telar.runtime.traffic.redirect.socket_owners;

import telar.sys.socket;
import telar.sys.process;
import telar.config.runtime;
import telar.runtime.traffic.tap.frames;
import telar.base.text.utf8;
import telar.platform.net;
import telar.base.ds;
import telar.wire.vocabulary;

namespace telar::runtime::redirect {

  namespace {

    constexpr std::uint64_t microseconds_per_second = 1000000;

    // Whether two socket addresses of one family name the same host.
    bool sameHost(const sockaddr_storage& left, const sockaddr_storage& right) noexcept {
      if (left.ss_family == AF_INET) {
        return addressAs<sockaddr_in>(left).sin_addr.s_addr == addressAs<sockaddr_in>(right).sin_addr.s_addr;
      }

      return sameBytes(addressAs<sockaddr_in6>(left).sin6_addr, addressAs<sockaddr_in6>(right).sin6_addr);
    }

  }

#ifdef __APPLE__
  PfCommandError::PfCommandError(std::string_view output) noexcept
      : message_(output) {}

  const char* PfCommandError::what() const noexcept {
    return message_.cStr();
  }
#endif

  LocalAddresses::LocalAddresses()
      : addresses_(nullptr, &freeifaddrs) {
    ifaddrs* addresses = nullptr;
    if (::getifaddrs(&addresses) != 0) {
      throw SystemError{"Read local redirect addresses"};
    }

    addresses_.reset(addresses);
  }

  bool LocalAddresses::contains(const Target& target) const noexcept {
    for (const auto* interface = addresses_.get(); interface != nullptr; interface = interface->ifa_next) {
      if ((interface->ifa_addr == nullptr) || !anyFlag(interface->ifa_flags, IFF_UP) || anyFlag(interface->ifa_flags, IFF_LOOPBACK) || interface->ifa_addr->sa_family != target.endpoint.storage.ss_family) {
        continue;
      }

      // getifaddrs hands each address as its family's whole sockaddr.
      const auto family = interface->ifa_addr->sa_family;
      const auto local = NetworkAddress::copy(interface->ifa_addr, static_cast<socklen_t>(family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6)));
      if (local && sameHost(local->storage, target.endpoint.storage)) {
        return true;
      }
    }

    return false;
  }

  ds::Array<bool, Target::maximum_targets> LocalAddresses::selection(std::span<const Target> targets, Direction direction) {
    ds::Array<bool, Target::maximum_targets> selected{};
    if (targets.size() > selected.size() || (!allowsIncoming(direction) && !allowsOutgoing(direction))) {
      throw std::invalid_argument{"Invalid redirect address scope"};
    }

    if (!allowsIncoming(direction)) {
      return selected;
    }

    const LocalAddresses local;
    bool incoming = false;

    for (std::size_t index = 0; index < targets.size(); ++index) {
      selected.atMut(index) = local.contains(targets[index]);
      if (direction == Direction::inbound && !selected[index]) {
        throw std::invalid_argument{"Incoming redirect targets must be assigned to an active non-loopback interface"};
      }

      incoming |= selected[index];
    }

    if (!incoming) {
      throw std::invalid_argument{"Incoming redirection requires a local destination"};
    }

    return selected;
  }

#ifdef __APPLE__

  PfCommand::PfCommand(Memory& memory) noexcept
      : memory_(memory) {}

  ds::String<Memory> PfCommand::run(std::span<const std::string_view> arguments, std::string_view input) {
    constexpr std::size_t maximum_arguments = 12;
    constexpr auto command_timeout = std::chrono::seconds{5};

    if (arguments.size() >= maximum_arguments) {
      throw std::invalid_argument{"Too many PF command arguments"};
    }

    ds::Array<std::string_view, maximum_arguments> argv{};

    argv.atMut(0) = "/sbin/pfctl";
    std::ranges::copy(arguments, argv.viewMut().begin() + 1);
    const ds::Array<EnvironmentEntry, 2> environment{{{.name = "LC_ALL", .value = "C"}, {.name = "PATH", .value = "/usr/bin:/bin:/usr/sbin:/sbin"}}};
    Command command{memory_, Launch{.cwd = "/", .arguments = std::span{argv}.first(arguments.size() + 1), .environment_mode = EnvironmentMode::replace, .environment = environment}, CommandPurpose::administration};
    // pfctl reports some results, the token `-E` hands out among them, on its standard error,
    // so both streams make one output in the order they arrive.
    ds::String<Memory> output{memory_};
    const auto append = [&](std::span<const Byte> bytes) {
      constexpr std::size_t output_limit = std::size_t{256} * 1024;
      if (output.size() + bytes.size() > output_limit) {
        throw std::runtime_error{"PF command output exceeds its limit"};
      }

      output.append(textView(bytes));
      return true;
    };

    const ds::Array pieces{input};
    CommandOutput<Memory> process{memory_, 0};
    int status = 0;

    try {
      status = process.streamWithInput(command, std::chrono::steady_clock::now() + command_timeout, input.empty() ? std::span<const std::string_view>{} : std::span<const std::string_view>{pieces}, append, append);
    } catch (const RequestError&) {
      throw SystemError{"PF administration command timed out", ETIMEDOUT};
    }

    if (status != 0) {
      throw PfCommandError{output.view()};
    }

    return output;
  }
#endif

  ProcessIdentity ProcessToken::parse(std::string_view value) {
    const auto separator = value.find('@');
    const auto pid = number(value.substr(0, separator));
    if (pid == 0 || pid > std::numeric_limits<std::int32_t>::max()) {
      throw std::invalid_argument{"Invalid selected process PID"};
    }

    ProcessIdentity process{.pid = static_cast<pid_t>(pid)};

    if (separator == std::string_view::npos) {
      return process;
    }

    value.remove_prefix(separator + 1);
    const auto dot = value.find('.');
    if (dot == std::string_view::npos) {
      throw std::invalid_argument{"Process identity requires creation seconds and microseconds"};
    }

    process.started_seconds = number(value.substr(0, dot));
    process.started_microseconds = number(value.substr(dot + 1));
    if (process.started_seconds == 0 || process.started_microseconds >= microseconds_per_second) {
      throw std::invalid_argument{"Invalid process creation time"};
    }

    return process;
  }

  auto ProcessToken::format(const ProcessIdentity& process) -> FixedText<maximum_bytes> {
    if (process.pid <= 0 || process.started_seconds == 0 || process.started_microseconds >= microseconds_per_second) {
      throw std::invalid_argument{"Process identity is not pinned"};
    }

    ds::Array<char, maximum_bytes> text{};
    const auto written = std::format_to_n(text.dataMut(), static_cast<std::ptrdiff_t>(text.size()), "{}@{}.{:06}", process.pid, process.started_seconds, process.started_microseconds);
    if (written.size <= 0 || std::cmp_greater_equal(written.size, text.size())) {
      throw std::invalid_argument{"Process identity is too long"};
    }

    FixedText<maximum_bytes> result;

    result.assign({text.data(), static_cast<std::size_t>(written.size)});
    return result;
  }

  std::uint64_t ProcessToken::number(std::string_view value) {
    const auto result = parseExact<std::uint64_t>(value);
    if (!result) {
      throw std::invalid_argument{"Invalid selected process identity"};
    }

    return *result;
  }

#ifdef __APPLE__

  SocketAccounts::SocketAccounts(Memory& memory) noexcept
      : memory_(memory) {}

  void SocketAccounts::validate() {
    refresh();
    decode(snapshot_->bytes().first(size_), {}, {});
  }

  ds::Option<uid_t> SocketAccounts::peer(int descriptor) {
    const auto local = socketAddress(descriptor, SocketEnd::local);
    if (!local) {
      throw SystemError{"Read origin socket identity"};
    }

    const auto remote = socketAddress(descriptor, SocketEnd::peer);
    if (!remote) {
      throw SystemError{"Read origin peer identity"};
    }

    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      refresh();
      if (const auto account = decode(snapshot_->bytes().first(size_), *local, *remote)) {
        return account;
      }

      if (attempt != 2) {
        ::poll(nullptr, 0, 1);
      }
    }

    return {};
  }

  ds::Option<uid_t> SocketAccounts::decode(std::span<const Byte> bytes, const sockaddr_storage& local, const sockaddr_storage& peer) {
    if (bytes.size() < sizeof(xinpgen)) {
      throw EncodingError{"Incomplete TCP account snapshot"};
    }

    const auto header = loadValue<xinpgen>(std::as_bytes(bytes));
    if (header.xig_len != sizeof(header)) {
      throw EncodingError{"Unsupported TCP account snapshot header"};
    }

    if (bytes.size() == sizeof(header) && header.xig_count == 0) {
      return {};
    }

    if (bytes.size() < 2 * sizeof(header)) {
      throw EncodingError{"Incomplete TCP account snapshot"};
    }

    bytes = bytes.subspan(sizeof(header));
    ds::Option<uid_t> account;

    while (bytes.size() > sizeof(xinpgen)) {
      const auto length = loadValue<std::uint32_t>(std::as_bytes(bytes));
      if (length != sizeof(xtcpcb64) || length > bytes.size() - sizeof(xinpgen)) {
        throw EncodingError{"Unsupported TCP account record"};
      }

      const auto entry = loadValue<xtcpcb64>(std::as_bytes(bytes));
      const auto& socket = entry.xt_inpcb.xi_socket;
      // Darwin's conversion leaves xi_len zero; the outer TCP record bounds
      // and the socket's own length still identify the supported SDK layout.
      if ((entry.xt_inpcb.xi_len != 0 && entry.xt_inpcb.xi_len != sizeof(xinpcb64)) || (socket.xso_protocol == IPPROTO_TCP && socket.xso_len != sizeof(xsocket64))) {
        throw EncodingError{"Unsupported TCP socket account layout"};
      }

      if (entry.t_state >= TCPS_SYN_RECEIVED && socket.so_type == SOCK_STREAM && socket.xso_protocol == IPPROTO_TCP && matches(entry.xt_inpcb, local, peer)) {
        if (account && *account != socket.so_uid) {
          throw EncodingError{"Ambiguous TCP peer account"};
        }

        account = socket.so_uid;
      }

      bytes = bytes.subspan(length);
    }

    if (bytes.size() != sizeof(xinpgen)) {
      throw EncodingError{"Incomplete TCP account snapshot footer"};
    }

    if (loadValue<xinpgen>(std::as_bytes(bytes)).xig_len != sizeof(xinpgen)) {
      throw EncodingError{"Unsupported TCP account snapshot footer"};
    }

    return account;
  }

  void SocketAccounts::refresh() {
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      std::size_t needed = 0;
      if (::sysctlbyname("net.inet.tcp.pcblist64", nullptr, &needed, nullptr, 0) != 0) {
        throw SystemError{"Query TCP account snapshot"};
      }

      if (needed < 2 * sizeof(xinpgen) || needed > maximum_bytes) {
        throw SystemError{"TCP account snapshot exceeds its bound", ENOSPC};
      }

      if (!snapshot_ || snapshot_->bytes().size() < needed) {
        snapshot_.emplace(memory_, std::min(maximum_bytes, needed + (needed / 4) + sizeof(xtcpcb64)));
      }

      size_ = snapshot_->bytes().size();
      if (::sysctlbyname("net.inet.tcp.pcblist64", snapshot_.getMut().bytesMut().data(), &size_, nullptr, 0) == 0) {
        return;
      }

      if (sys::lastError() != ENOMEM && sys::lastError() != EINTR) {
        throw SystemError{"Read TCP account snapshot"};
      }
    }

    throw SystemError{"TCP account snapshot changed repeatedly", EAGAIN};
  }

  bool SocketAccounts::matches(const xinpcb64& pcb, const sockaddr_storage& local, const sockaddr_storage& peer) noexcept {
    if (local.ss_family != peer.ss_family) {
      return false;
    }

    if (local.ss_family == AF_INET && anyFlag(pcb.inp_vflag, INP_IPV4)) {
      const auto origin = addressAs<sockaddr_in>(local);
      const auto server = addressAs<sockaddr_in>(peer);

      return pcb.inp_lport == server.sin_port && pcb.inp_fport == origin.sin_port && sys::localAddress(pcb).s_addr == server.sin_addr.s_addr && sys::foreignAddress(pcb).s_addr == origin.sin_addr.s_addr;
    }

    if (local.ss_family == AF_INET6 && anyFlag(pcb.inp_vflag, INP_IPV6)) {
      const auto origin = addressAs<sockaddr_in6>(local);
      const auto server = addressAs<sockaddr_in6>(peer);

      // Each address union holds the IPv6 address whole.
      return pcb.inp_lport == server.sin6_port && pcb.inp_fport == origin.sin6_port && sameBytes(pcb.inp_dependladdr, server.sin6_addr) && sameBytes(pcb.inp_dependfaddr, origin.sin6_addr);
    }

    return false;
  }
#endif

#ifdef __linux__

  bool LinuxTcpSocket::matches(const Target& source, const Target& destination) const noexcept {
    return endpointMatches(local, source.endpoint.storage) && endpointMatches(remote, destination.endpoint.storage);
  }

  ds::Option<LinuxTcpSocket> LinuxTcpSocket::parse(std::string_view line, int family) noexcept {
    constexpr std::size_t required_fields = 10;
    ds::Array<std::string_view, required_fields> fields;
    for (auto& field : fields.viewMut()) {
      const auto first = line.find_first_not_of(" \t");
      if (first == std::string_view::npos) {
        return ds::none;
      }
      line.remove_prefix(first);
      const auto separator = line.find_first_of(" \t");
      field = line.substr(0, separator);
      line = separator == std::string_view::npos ? std::string_view{} : line.substr(separator);
    }

    LinuxTcpSocket socket;
    if (!endpoint(fields[1], family, socket.local) || !endpoint(fields[2], family, socket.remote) || !number(fields[3], socket.state, 16) || !number(fields[7], socket.user, 10) || !number(fields[9], socket.inode, 10)) {
      return ds::none;
    }
    return socket;
  }

  template <typename Integer>
  bool LinuxTcpSocket::number(std::string_view input, Integer& output, int base) noexcept {
    const auto parsed = parseExact<Integer>(input, base);
    if (parsed) {
      output = *parsed;
    }
    return parsed.hasValue();
  }

  bool LinuxTcpSocket::endpoint(std::string_view input, int family, sockaddr_storage& output) noexcept {
    constexpr std::size_t word_digits = sizeof(std::uint32_t) * 2;
    const auto address_digits = family == AF_INET ? word_digits : word_digits * 4;
    if (input.size() != address_digits + 1 + sizeof(std::uint16_t) * 2 || input[address_digits] != ':') {
      return false;
    }

    std::uint16_t port = 0;
    if (!number(input.substr(address_digits + 1), port, 16)) {
      return false;
    }
    ds::Array<std::uint32_t, 4> words{};
    for (std::size_t index = 0; index < address_digits / word_digits; ++index) {
      if (!number(input.substr(index * word_digits, word_digits), words.atMut(index), 16)) {
        return false;
      }
    }

    if (family == AF_INET) {
      auto& address = reinterpret_cast<sockaddr_in&>(output);
      address.sin_family = AF_INET;
      address.sin_port = htons(port);
      std::memcpy(&address.sin_addr, words.data(), sizeof(address.sin_addr));
    } else {
      auto& address = reinterpret_cast<sockaddr_in6&>(output);
      address.sin6_family = AF_INET6;
      address.sin6_port = htons(port);
      std::memcpy(&address.sin6_addr, words.data(), sizeof(address.sin6_addr));
    }
    return true;
  }

  bool LinuxTcpSocket::endpointMatches(const sockaddr_storage& left, const sockaddr_storage& right) noexcept {
    if (left.ss_family != right.ss_family) {
      return false;
    }
    if (left.ss_family == AF_INET) {
      const auto& actual = reinterpret_cast<const sockaddr_in&>(left);
      const auto& expected = reinterpret_cast<const sockaddr_in&>(right);
      return actual.sin_port == expected.sin_port && actual.sin_addr.s_addr == expected.sin_addr.s_addr;
    }
    const auto& actual = reinterpret_cast<const sockaddr_in6&>(left);
    const auto& expected = reinterpret_cast<const sockaddr_in6&>(right);
    return actual.sin6_port == expected.sin6_port && std::memcmp(&actual.sin6_addr, &expected.sin6_addr, sizeof(in6_addr)) == 0;
  }
#endif

  SocketOwners::SocketOwners(uid_t uid, std::span<const ProcessIdentity> selected)
      : inspector_(builtinManifests(), uid) {
    if (selected.size() > maximum_processes) {
      throw std::invalid_argument{"Too many selected processes"};
    }

    for (const auto& requested : selected) {
      const auto current = inspector_.identity(requested.pid);
      if (!current || (requested.started_seconds != 0 && !current->sameInstance(requested))) {
        throw std::invalid_argument{"Selected process is unavailable, replaced or belongs to another account"};
      }

      if (std::ranges::any_of(std::span{processes_}.first(count_), [&](const auto& other) {
            return other.pid == current->pid;
          })) {
        throw std::invalid_argument{"Duplicate selected process"};
      }

      processes_.atMut(count_++) = *current;
    }
  }

  bool SocketOwners::enabled() const noexcept {
    return count_ != 0;
  }

  std::span<const ProcessIdentity> SocketOwners::processes() const noexcept {
    return std::span{processes_}.first(count_);
  }

#ifdef __APPLE__

  bool matchesMacosSocket(const in_sockinfo& socket, const FlowKey& flow) noexcept {
    if (ntohs(static_cast<std::uint16_t>(socket.insi_lport)) != flow.source.port || ntohs(static_cast<std::uint16_t>(socket.insi_fport)) != flow.destination.port) {
      return false;
    }

    const auto family = flow.source.endpoint.storage.ss_family;
    if (family != flow.destination.endpoint.storage.ss_family) {
      return false;
    }

    if (family == AF_INET && anyFlag(socket.insi_vflag, INI_IPV4)) {
      const auto local = addressAs<sockaddr_in>(flow.source.endpoint.storage).sin_addr;
      const auto remote = addressAs<sockaddr_in>(flow.destination.endpoint.storage).sin_addr;

      return socket.insi_laddr.ina_46.i46a_addr4.s_addr == local.s_addr && socket.insi_faddr.ina_46.i46a_addr4.s_addr == remote.s_addr; // NOLINT(cppcoreguidelines-pro-type-union-access): Darwin's in_sockinfo keeps either family's address in a union
    }

    if (family == AF_INET6 && anyFlag(socket.insi_vflag, INI_IPV6)) {
      const auto local = addressAs<sockaddr_in6>(flow.source.endpoint.storage).sin6_addr;
      const auto remote = addressAs<sockaddr_in6>(flow.destination.endpoint.storage).sin6_addr;

      // Each address union holds the IPv6 address whole.
      return sameBytes(socket.insi_laddr, local) && sameBytes(socket.insi_faddr, remote);
    }

    return false;
  }

  namespace {

    // Whether a descriptor of `pid` is the flow's TCP socket; `complete` turns false when one could
    // not be read for another reason than having closed.
    bool ownsFlowSocket(pid_t pid, const proc_fdinfo& descriptor, const FlowKey& flow, bool& complete) noexcept {
      if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) {
        return false;
      }

      socket_fdinfo information{};
      if (::proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, sizeof(information)) != sizeof(information)) {
        if (sys::lastError() != EBADF && sys::lastError() != ESRCH) {
          complete = false;
        }

        return false;
      }

      const auto& socket = information.psi;
      if (socket.soi_kind != SOCKINFO_TCP || socket.soi_type != SOCK_STREAM || socket.soi_protocol != IPPROTO_TCP) {
        return false;
      }

      const auto& tcp = socket.soi_proto.pri_tcp; // NOLINT(cppcoreguidelines-pro-type-union-access): Darwin's socket_info keeps each protocol's state in a union that soi_kind selects

      return tcp.tcpsi_state != TSI_S_CLOSED && tcp.tcpsi_state != TSI_S_LISTEN && matchesMacosSocket(tcp.tcpsi_ini, flow);
    }

  }

  SocketOwners::Result SocketOwners::find(const FlowKey& flow) noexcept {
    Result result;

    for (const auto& selected : processes()) {
      const auto current = inspector_.identity(selected.pid);
      if (!current || !current->sameInstance(selected)) {
        continue;
      }

      const auto bytes = ::proc_pidinfo(selected.pid, PROC_PIDLISTFDS, 0, descriptors_.dataMut(), sizeof(descriptors_));
      if (bytes <= 0 || std::cmp_greater_equal(bytes, sizeof(descriptors_)) || static_cast<std::size_t>(bytes) % sizeof(proc_fdinfo) != 0) {
        result.complete = false;
        continue;
      }

      const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);

      for (const auto& descriptor : std::span{descriptors_}.first(count)) {
        if (!ownsFlowSocket(selected.pid, descriptor, flow, result.complete)) {
          continue;
        }

        const auto verified = inspector_.identity(selected.pid);
        if (verified && verified->sameInstance(selected)) {
          result.process = *verified;
          result.complete = true;
          return result;
        }
      }
    }

    return result;
  }
#endif

#ifndef __APPLE__

  SocketOwners::Result SocketOwners::find(const FlowKey& flow) noexcept {
    Result result;
    try {
      ds::Option<std::uint64_t> inode;
      visitLinuxTcpSockets([&](const LinuxTcpSocket& socket) {
        if (socket.inode != 0 && socket.matches(flow.source, flow.destination)) {
          inode = socket.inode;
          return false;
        }
        return true;
      });
      if (!inode) {
        return result;
      }

      for (const auto& selected : processes()) {
        const auto current = inspector_.identity(selected.pid);
        if (!current || !current->sameInstance(selected)) {
          continue;
        }

        ds::Array<char, PATH_MAX> path;
        std::snprintf(path.dataMut(), path.size(), "/proc/%d/fd", selected.pid);
        DirectoryStream directory{FileDescriptor{::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)}};
        std::size_t count = 0;
        while (const auto* entry = directory.next()) {
          if (++count > maximum_descriptors) {
            result.complete = false;
            break;
          }
          ds::Array<char, 64> target;
          const auto length = ::readlinkat(directory.descriptor(), entry->d_name, target.dataMut(), target.size());
          if (length < 0 && sys::lastError() == ENOENT) {
            continue;
          }
          if (length <= 0 || static_cast<std::size_t>(length) >= target.size()) {
            result.complete = false;
            continue;
          }

          std::string_view name{target.data(), static_cast<std::size_t>(length)};
          if (!name.starts_with("socket:[") || !name.ends_with(']')) {
            continue;
          }
          name = name.substr(sizeof("socket:[") - 1, name.size() - sizeof("socket:["));
          if (parseExact<std::uint64_t>(name) != *inode) {
            continue;
          }
          const auto verified = inspector_.identity(selected.pid);
          if (verified && verified->sameInstance(selected)) {
            result.process = *verified;
            result.complete = true;
            return result;
          }
        }
      }
    } catch (...) {
      result.complete = false;
    }
    return result;
  }
#endif

#ifdef __APPLE__

  namespace {

    // The signals that stop the helper and remove its rules; closing its terminal sends SIGHUP.
    constexpr ds::Array<int, 4> shutdown_signals{SIGINT, SIGTERM, SIGHUP, SIGQUIT};

    bool shutdownPending() noexcept {
      sigset_t pending{};

      return ::sigpending(&pending) == 0 && std::ranges::any_of(shutdown_signals, [&](int code) {
        return sigismember(&pending, code) != 0;
      });
    }

    // Reports why an incoming origin connection failed.
    void reportOriginFailure(int code) noexcept {
      constexpr std::size_t error_text_bytes = 128;
      ds::Array<char, error_text_bytes> text{};
      // strerror_r writes at most the size it is given.
#pragma clang unsafe_buffer_usage begin
      const auto* const message = ::strerror_r(code, text.dataMut(), text.size()) == 0 ? text.data() : "Unknown error";
#pragma clang unsafe_buffer_usage end

      writeErrorLine("telar redirect: incoming origin connection failed: {}", message);
    }

  }

  Listener::Listener(const Target& target, bool incoming)
      : target_(target),
        socket_(openOriginSocket(target.endpoint.storage.ss_family)),
        incoming_(incoming) {
    NetworkAddress local = target.endpoint;

    local.setPort(0);
    if (!incoming && local.storage.ss_family == AF_INET) {
      auto address = addressAs<sockaddr_in>(local.storage);

      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      storeValue(std::as_writable_bytes(std::span{&local.storage, 1}), address);
    } else if (!incoming) {
      auto address = addressAs<sockaddr_in6>(local.storage);

      address.sin6_addr = in6addr_loopback;
      storeValue(std::as_writable_bytes(std::span{&local.storage, 1}), address);
    }

    if (local.storage.ss_family == AF_INET6) {
      const int enabled = 1;
      if (::setsockopt(socket_.get(), IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Configure IPv6 redirect listener"};
      }
    }

    constexpr int listen_backlog = 128;
    if (::bind(socket_.get(), local.address(), local.length) != 0 || ::listen(socket_.get(), listen_backlog) != 0) {
      throw SystemError{"Bind transparent redirect listener"};
    }

    const auto bound = socketAddress(socket_.get(), SocketEnd::local);
    if (!bound) {
      throw SystemError{"Read redirect listener port"};
    }

    port_ = ntohs(bound->ss_family == AF_INET ? addressAs<sockaddr_in>(*bound).sin_port : addressAs<sockaddr_in6>(*bound).sin6_port);
  }

  int Listener::descriptor() const noexcept {
    return socket_.get();
  }

  Mapping Listener::mapping() const noexcept {
    return {.target = target_, .listener_port = port_, .incoming = incoming_};
  }

  FileDescriptor Listener::accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (child) {
      configureProxySocket(child.get());
    } else if (!socketWouldBlock(sys::lastError())) {
      throw SystemError{"Accept redirected TCP connection"};
    }

    return child;
  }

  ShutdownSignals::ShutdownSignals() {
    sigemptyset(&selected_);
    for (const int code : shutdown_signals) {
      sigaddset(&selected_, code);
    }

    const auto result = ::pthread_sigmask(SIG_BLOCK, &selected_, &previous_);
    if (result != 0) {
      throw SystemError{"Block redirect shutdown signals", result};
    }
  }

  ShutdownSignals::~ShutdownSignals() {
    // Consume the handled shutdown signal before restoring the old mask.
    if (shutdownPending()) {
      int received = 0;

      ::sigwait(&selected_, &received);
    }

    ::pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
  }

  bool ShutdownSignals::stopping() noexcept {
    return shutdownPending();
  }

  Helper::Helper(Memory& memory, std::string_view endpoint, std::span<const Target> targets, std::span<const ProcessIdentity> processes, Direction direction)
      : memory_(memory),
        endpoint_(memory, endpoint),
        direction_(direction) {
    if (processes.size() > selected_processes_.size()) {
      throw std::invalid_argument{"Too many selected processes"};
    }

    if (targets.empty() || (allowsIncoming(direction) && !processes.empty())) {
      throw std::invalid_argument{"Incoming redirect selects local services by account; process selection is outbound only"};
    }

    const auto incoming = LocalAddresses::selection(targets, direction);

    std::ranges::copy(processes, selected_processes_.viewMut().begin());
    process_count_ = processes.size();
    endpoint_.append(socket_suffix);
    for (const auto& target : targets) {
      listeners_.atMut(count_).emplace(target, incoming[count_]);
      mappings_.atMut(count_) = listeners_[count_]->mapping();
      ++count_;
    }
  }

  ds::String<Memory> Helper::plan(uid_t uid, const PfIdentity<Memory>& identity, bool dry_run) const {
    ds::Array<FlowKey, maximum_flows> keys;
    ds::Array<FlowKey, maximum_flows> incoming;
    ds::Array<Bypass, maximum_flows> bypasses;
    std::size_t size = 0;
    std::size_t bypass_size = 0;
    std::size_t incoming_size = 0;

    for (const auto& flow : flows_) {
      if (flow && flow->bypass) {
        bypasses.atMut(bypass_size++) = {.key = flow->key, .route = *flow->bypass};
      } else if (flow && flow->incoming) {
        incoming.atMut(incoming_size++) = flow->key;
      } else if (flow) {
        keys.atMut(size++) = flow->key;
      }
    }

    ds::Option<unsigned> log_interface;

    if (packet_log_) {
      log_interface = packet_log_->index();
    } else if (dry_run && allowsIncoming(direction_)) {
      log_interface = 0U;
    }

    const PfScope scope{
        .uid = uid,
        .label = identity.label,
        .discovery_interface = discovery_ ? discovery_->name() : "utun0",
        .flows = std::span{keys}.first(size),
        .log_interface = log_interface,
        .bypasses = std::span{bypasses}.first(bypass_size),
        .log_all = process_count_ != 0 || allowsIncoming(direction_),
        .direction = direction_,
        .incoming_flows = std::span{incoming}.first(incoming_size),
    };

    return pfRules(memory_, std::span{mappings_}.first(count_), scope);
  }

  void Helper::run(const PfIdentity<Memory>& identity) {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Transparent redirection requires the privileged helper"};
    }

    const ShutdownSignals signals;
    const auto monitor = traffic::connect(endpoint_);

    greet(monitor.get());
    discovery_.emplace();
    nat_.emplace();
    Record<Memory> state{memory_, identity, endpoint_};
    PfCommand command{memory_};
    PfLoopback<PfCommand> interface{command};
    RedirectLoopback loopback{memory_, interface, identity.label};
    RedirectSession session{command, state, identity, loopback};

    session.start(plan(uid_, identity));
    if (watchesPacketLog()) {
      packet_log_.emplace(session.stateMut(), uid_, direction_);
      session.replace(plan(uid_, identity));
      writeErrorLine("telar redirect: TCP discovery on pflog{}", packet_log_->index());
    }

    writeErrorLine("telar redirect: active for uid {}, {} TCP destinations, anchor {}, discovery {}", uid_, count_, identity.anchor.view(), discovery_->name());
    const auto active = static_cast<Byte>(MonitorUpdate::active);

    traffic::sendAll(monitor.get(), {&active, 1});
    while (!ShutdownSignals::stopping()) {
      Descriptors descriptors{};

      pollEvents(descriptors, monitor.get());
      if (anyFlag(descriptors[0].revents, POLLIN)) {
        Byte request = 0;
        const auto received = ::recv(monitor.get(), &request, 1, 0);
        if (received == 1 && request != stop_request) {
          throw EncodingError{"Invalid redirect stop request"};
        }

        break;
      }

      if (anyFlag(descriptors[0].revents, POLLHUP, POLLERR, POLLNVAL)) {
        break;
      }

      if (expireFlows(descriptors)) {
        session.replace(plan(uid_, identity));
      }

      acceptReady(descriptors);
      completePending(descriptors);
      if (anyFlag(descriptors[1].revents, POLLIN)) {
        discover(session, uid_, identity);
      }

      if (packet_log_) {
        drainPacketLog(session, identity);
      }
    }

    packet_log_.reset();
    session.stop();
    const auto stopped = static_cast<Byte>(MonitorUpdate::stopped);

    ::send(monitor.get(), &stopped, 1, 0);
  }

  void Helper::greet(int monitor) {
    const auto credentials = peerCredentials(monitor);
    if (!credentials || credentials->user == 0) {
      throw SystemError{"Redirect runtime must belong to an unprivileged account", EACCES};
    }

    uid_ = credentials->user;
    if (process_count_ != 0) {
      owners_.emplace(uid_, std::span{selected_processes_}.first(process_count_));
    }

    if (allowsIncoming(direction_)) {
      accounts_.emplace(memory_);
      accounts_.getMut().validate();
    }

    ds::Array<Byte, Protocol::frame_bytes> hello{};

    traffic::sendAll(monitor, Protocol::encode(hello.viewMut(), Kind::monitor, {}));
    ds::Array<Byte, sizeof(std::uint32_t)> reply{};

    readAll(monitor, reply.viewMut());
    plugins::FrameReader reader{reply};
    if (reader.integer<std::uint32_t>() != uid_) {
      throw EncodingError{"Redirect runtime account does not match its socket credentials"};
    }
  }

  bool Helper::watchesPacketLog() const {
    return owners_ || allowsIncoming(direction_) || std::ranges::any_of(std::span{mappings_}.first(count_), [](const auto& mapping) {
      return mapping.target.host.view() == "::1";
    });
  }

  void Helper::pollEvents(Descriptors& descriptors, int monitor) const {
    descriptors.atMut(0) = {.fd = monitor, .events = POLLIN, .revents = 0};
    descriptors.atMut(1) = {.fd = discovery_->descriptor(), .events = POLLIN, .revents = 0};
    descriptors.atMut(2) = {.fd = packet_log_ ? packet_log_->descriptor() : -1, .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < Target::maximum_targets; ++index) {
      descriptors.atMut(index + 3) = {.fd = listeners_[index] ? listeners_[index]->descriptor() : -1, .events = POLLIN, .revents = 0};
    }

    for (std::size_t index = 0; index < pending_.size(); ++index) {
      descriptors.atMut(pending_offset + index) = {.fd = pending_[index] ? pending_[index]->connection.origin.get() : -1, .events = POLLOUT, .revents = 0};
    }

    for (std::size_t index = 0; index < flows_.size(); ++index) {
      descriptors.atMut(pending_offset + maximum_pending + index) = {.fd = flows_[index] ? flows_[index]->lifetime.get() : -1, .events = POLLIN, .revents = 0};
    }

    constexpr int poll_ms = 100;
    if (::poll(descriptors.dataMut(), descriptors.size(), poll_ms) < 0 && sys::lastError() != EINTR) {
      throw SystemError{"Poll transparent TCP helper"};
    }
  }

  bool Helper::expireFlows(const Descriptors& descriptors) {
    bool changed = false;

    for (std::size_t index = 0; index < flows_.size(); ++index) {
      if (flows_[index] && (anyFlag(descriptors[pending_offset + maximum_pending + index].revents, POLLIN, POLLHUP, POLLERR, POLLNVAL) || std::chrono::steady_clock::now() >= flows_[index]->deadline)) {
        flows_.atMut(index).reset();
        changed = true;
      }
    }

    return changed;
  }

  void Helper::acceptReady(const Descriptors& descriptors) {
    for (std::size_t index = 0; index < count_; ++index) {
      if (anyFlag(descriptors[index + 3].revents, POLLIN)) {
        accept(index);
      }
    }
  }

  void Helper::completePending(const Descriptors& descriptors) {
    for (std::size_t index = 0; index < pending_.size(); ++index) {
      auto& pending = pending_.atMut(index);
      if (!pending) {
        continue;
      }

      if (!flows_[pending->flow]) {
        pending.reset();
        continue;
      }

      if (anyFlag(descriptors[pending_offset + index].revents, POLLOUT, POLLERR, POLLHUP)) {
        int failure = 0;
        socklen_t length = sizeof(failure);
        // The connection leaves the pending table before the handoff, which updates the flows.
        const auto connected = std::move(pending.getMut());

        pending.reset();
        if (::getsockopt(connected.connection.origin.get(), SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0) {
          handoff(connected.connection, connected.flow);
        } else if (flows_[connected.flow]->incoming) {
          reportOriginFailure((failure != 0) ? failure : sys::lastError());
        }
      } else if (std::chrono::steady_clock::now() >= pending->deadline) {
        if (flows_[pending->flow]->incoming) {
          writeErrorLine("telar redirect: incoming origin connection timed out");
        }

        pending.reset();
      }
    }
  }

  void Helper::drainPacketLog(RedirectSession& session, const PfIdentity<Memory>& identity) {
    // A logged packet and its metadata are copied out of the log before discovery updates the flows.
    ds::Array<Byte, PacketLog::frame_bytes> copied; // NOLINT(cppcoreguidelines-pro-type-member-init): each packet is copied in before it is read; zeroing 64 KiB on every turn of the loop is wasted work

    for (std::size_t count = 0; count < maximum_accept_batch; ++count) {
      const auto logged = packet_log_.getMut().receive();
      if (logged.empty()) {
        break;
      }

      if (logged.size() > copied.size()) {
        continue;
      }

      std::ranges::copy(logged, copied.viewMut().begin());
      const auto metadata = packet_log_->metadata();

      discovered(session, uid_, identity, copied.viewMut().first(logged.size()), &metadata);
    }
  }

  bool Helper::selects(const FlowKey& key, bool incoming) const {
    if (incoming ? !allowsIncoming(direction_) : !allowsOutgoing(direction_)) {
      return false;
    }

    return std::ranges::any_of(std::span{mappings_}.first(count_), [&](const auto& mapping) {
      return (!incoming || mapping.incoming) && FlowKey::same(mapping.target, key.destination);
    });
  }

  bool Helper::reachesLocally(const PacketLog::Metadata& metadata, const Target& destination) const {
    return metadata.interface_index != 0 && metadata.interface.view() != "lo0" && metadata.interface.view() != discovery_->name() && LocalAddresses{}.contains(destination);
  }

  Helper::Tracking Helper::track(const FlowKey& key, bool incoming, const PacketLog::Metadata* metadata) {
    const auto* const found = std::ranges::find_if(flows_, [&](const auto& flow) {
      return flow && flow->incoming == incoming && flow->key.matches(key);
    });
    if (found != flows_.end()) {
      return Tracking::known;
    }

    const auto flows = flows_.viewMut();
    const auto empty = std::ranges::find_if(flows, [](const auto& flow) {
      return !flow;
    });
    if (empty == flows.end()) {
      return Tracking::full;
    }

    Flow flow{.key = key, .incoming = incoming};

    if (owners_) {
      const auto owner = owners_.getMut().find(key);
      if (!owner.process) {
        if (metadata == nullptr || metadata->interface_index == 0) {
          throw SystemError{"Original process route is unavailable", ENXIO};
        }

        flow.bypass = RoutePath::lookup(key.destination, metadata->interface_index);
        flow.deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
        if (!owner.complete) {
          writeErrorLine("telar redirect: incomplete process ownership lookup; retaining the direct route");
        }
      }
    }

    empty->emplace(std::move(flow));
    return Tracking::added;
  }

  void Helper::readAll(int socket, std::span<Byte> bytes) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};

    while (!bytes.empty()) {
      pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};
      constexpr int poll_ms = 50;
      if (::poll(&descriptor, 1, poll_ms) > 0) {
        const auto count = ::recv(socket, bytes.data(), bytes.size(), MSG_DONTWAIT);
        if (count > 0) {
          bytes = bytes.subspan(static_cast<std::size_t>(count));
        } else if (count == 0 || !socketWouldBlock(sys::lastError())) {
          throw SystemError{"Redirect runtime disconnected", ECONNRESET};
        }
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect runtime reply timed out", ETIMEDOUT};
      }
    }
  }

  void Helper::accept(std::size_t listener) {
    for (std::size_t round = 0; round < maximum_accept_batch; ++round) {
      auto child = listeners_[listener]->accept();
      if (!child) {
        return;
      }

      const auto pending = pending_.viewMut();
      const auto slot = std::ranges::find_if(pending, [](const auto& value) {
        return !value;
      });
      if (slot == pending.end()) {
        continue;
      }

      const auto target = listeners_[listener]->mapping().target;
      const auto flows = flows_.viewMut();
      const auto flow = std::ranges::find_if(flows, [&](const auto& value) {
        return value && !value->bypass && !value->accepted && FlowKey::same(value->key.destination, target) && NatLookup::peerMatches(child.get(), value->key);
      });
      if (flow == flows.end() || !nat_->matches(child.get(), (*flow)->key)) {
        writeErrorLine("telar redirect: rejected connection without selected NAT state");
        continue;
      }

      const auto index = static_cast<std::size_t>(flow - flows.begin());

      if (owners_ && !owners_.getMut().find((*flow)->key).process) {
        writeErrorLine("telar redirect: selected process no longer owns the accepted socket");
        continue;
      }

      // The accepted flow waits for its origin as long as the pending connection does, not until
      // the deadline its SYN set.
      const auto deadline = std::chrono::steady_clock::now() + connection_grace;

      flow->getMut().accepted = true;
      flow->getMut().deadline = deadline;
      if ((*flow)->incoming) {
        writeErrorLine("telar redirect: accepted incoming TCP for destination port {}", target.port);
      }

      Connection connection{.child = std::move(child), .origin = openOriginSocket(target.endpoint.storage.ss_family), .target = target};
      if (::connect(connection.origin.get(), target.endpoint.address(), target.endpoint.length) == 0) {
        handoff(connection, index);
      } else if (sys::lastError() == EINPROGRESS || sys::lastError() == EINTR) {
        slot->emplace(Pending{.connection = std::move(connection), .deadline = deadline, .flow = index});
      } else if ((*flow)->incoming) {
        reportOriginFailure(sys::lastError());
      }
    }
  }

  void Helper::handoff(const Connection& connection, std::size_t flow) {
    if (flows_[flow]->incoming && (!accounts_ || accounts_.getMut().peer(connection.origin.get()) != uid_)) {
      writeErrorLine("telar redirect: rejected incoming origin without the runtime account");
      flows_.atMut(flow).getMut().deadline = std::chrono::steady_clock::now();
      return;
    }

    auto channel = traffic::connect(endpoint_);

    Protocol::send(channel.get(), connection);
    ds::Array<Byte, 1> admitted{};

    readAll(channel.get(), admitted.viewMut());
    if (admitted[0] != 1) {
      writeErrorLine("telar redirect: runtime connection capacity reached");
      return;
    }

    flows_.atMut(flow).getMut().lifetime = std::move(channel);
    flows_.atMut(flow).getMut().deadline = std::chrono::steady_clock::time_point::max();
    if (flows_[flow]->incoming) {
      writeErrorLine("telar redirect: handed incoming TCP to runtime for destination port {}", connection.target.port);
    }
  }

#endif

}
