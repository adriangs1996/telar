module telar.runtime.redirect.ingress;

import telar.native.pcap;
import telar.sys.socket;
import telar.base.ds;

namespace telar::runtime::redirect {

  namespace {

    // Whether the peer of a redirected origin socket is the destination its target names.
    bool reaches(const sockaddr_storage& actual, const Target& target) noexcept {
      if (actual.ss_family == AF_INET) {
        const auto origin = addressAs<sockaddr_in>(actual);
        const auto expected = addressAs<sockaddr_in>(target.endpoint.storage);

        return origin.sin_port == htons(target.port) && origin.sin_addr.s_addr == expected.sin_addr.s_addr;
      }

      const auto origin = addressAs<sockaddr_in6>(actual);
      const auto expected = addressAs<sockaddr_in6>(target.endpoint.storage);

      return origin.sin6_port == htons(target.port) && sameBytes(origin.sin6_addr, expected.sin6_addr);
    }

    // How many descriptors an SCM_RIGHTS message carries whose data starts `offset` bytes into
    // `control`; none for another message, or one that overruns the buffer.
    ds::Option<std::size_t> rightsCount(const cmsghdr& header, std::span<const std::byte> control, std::size_t offset) noexcept {
      if (header.cmsg_level != SOL_SOCKET || header.cmsg_type != SCM_RIGHTS || header.cmsg_len < CMSG_LEN(0)) {
        return ds::none;
      }

      const auto descriptors = (header.cmsg_len - CMSG_LEN(0)) / sizeof(int);
      if (offset > control.size() || descriptors > (control.size() - offset) / sizeof(int)) {
        return ds::none;
      }

      return descriptors;
    }

  }

  ds::Option<sockaddr_storage> socketAddress(int socket, SocketEnd end) noexcept {
    sockaddr_storage address{};
    socklen_t length = sizeof(address);
    auto* const generic = reinterpret_cast<sockaddr*>(&address); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    const auto result = end == SocketEnd::local ? ::getsockname(socket, generic, &length) : ::getpeername(socket, generic, &length);
    if (result != 0) {
      return ds::none;
    }

    return address;
  }

  tbc::val_a<std::string_view> formatAuthority(tbc::val_a<std::span<char>> output, std::string_view host, std::uint16_t port) {
    const bool bracketed = host.contains(':');
    const auto written = std::format_to_n(output.data(), static_cast<std::ptrdiff_t>(output.size()), "{}{}{}:{}", bracketed ? "[" : "", host, bracketed ? "]" : "", port);
    if (std::cmp_greater_equal(written.size, output.size())) {
      return {};
    }

    return {output.data(), static_cast<std::size_t>(written.size)};
  }

  ProxyTarget Target::authority(std::string_view text) {
    const auto colon = text.rfind(':');
    if (colon == std::string_view::npos) {
      throw std::invalid_argument{"Redirect target requires a host and port"};
    }

    auto host = text.substr(0, colon);
    if (host.starts_with('[') && host.ends_with(']')) {
      host = host.substr(1, host.size() - 2);
    } else if (host.contains(':')) {
      throw std::invalid_argument{"IPv6 redirect targets require brackets"};
    }

    const auto port = parseExact<std::uint16_t>(text.substr(colon + 1)).valueOr(0);
    if (port == 0 || !ProxyHostname::validTarget(host)) {
      throw std::invalid_argument{"Invalid redirect target"};
    }

    return {.hostname = host, .port = static_cast<std::uint16_t>(port)};
  }

  Target Target::parse(std::string_view text) {
    const auto [host, port] = authority(text);
    if (host.size() >= INET6_ADDRSTRLEN) {
      throw std::invalid_argument{"Redirect target must be a numeric IP address"};
    }

    ds::Array<char, INET6_ADDRSTRLEN> terminated{};

    std::ranges::copy(host, terminated.viewMut().begin());
    Target result;
    in_addr ipv4{};
    in6_addr ipv6{};

    if (::inet_pton(AF_INET, terminated.data(), &ipv4) == 1) {
      const auto address = ntohl(ipv4.s_addr);
      if (address == INADDR_ANY || address == INADDR_BROADCAST || IN_MULTICAST(address)) {
        throw std::invalid_argument{"Redirect target must be unicast"};
      }

      result.endpoint = NetworkAddress::ipv4(ipv4);
      ::inet_ntop(AF_INET, &ipv4, terminated.dataMut(), terminated.size());
    } else if (::inet_pton(AF_INET6, terminated.data(), &ipv6) == 1) {
      if (IN6_IS_ADDR_UNSPECIFIED(&ipv6) || IN6_IS_ADDR_MULTICAST(&ipv6) || IN6_IS_ADDR_LINKLOCAL(&ipv6) || IN6_IS_ADDR_V4MAPPED(&ipv6)) {
        throw std::invalid_argument{"Redirect IPv6 target must be unicast without a scope"};
      }

      result.endpoint = NetworkAddress::ipv6(ipv6);
      ::inet_ntop(AF_INET6, &ipv6, terminated.dataMut(), terminated.size());
    } else {
      throw std::invalid_argument{"Redirect target must be a numeric IP address"};
    }

    result.host.assign(terminated.data());
    result.port = port;
    result.endpoint.setPort(result.port);
    return result;
  }

  Discovery::Discovery()
      : injection_(nullptr, &pcap_close) {
    // Injection captures nothing: the snapshot length only has to be valid.
    constexpr int snapshot_bytes = 64;
    ds::Array<char, PCAP_ERRBUF_SIZE> error{};

    injection_.reset(pcap_open_live("lo0", snapshot_bytes, 0, 1, error.dataMut()));
    if (!injection_) {
      throw std::runtime_error{error.data()};
    }

    if (pcap_datalink(injection_.get()) != DLT_NULL) {
      throw std::runtime_error{"Loopback injection requires DLT_NULL"};
    }

    const auto descriptor = pcap_fileno(injection_.get());

    setCloseOnExec(descriptor);
    unsigned complete = 1;
    constexpr unsigned long complete_headers = sys::ioctlWrite<unsigned int>('B', 117); // Darwin BIOCSHDRCMPLT
    if (::ioctl(descriptor, complete_headers, &complete) != 0) {                        // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Configure complete loopback injection headers"};
    }

    constexpr auto return_constant = static_cast<unsigned short>(combineFlags(BPF_RET, BPF_K));
    bpf_insn reject = BPF_STMT(return_constant, 0);
    bpf_program filter{.bf_len = 1, .bf_insns = &reject};
    if (pcap_setfilter(injection_.get(), &filter) != 0) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

  int Discovery::descriptor() const noexcept {
    return tunnel_.descriptor();
  }

  std::string_view Discovery::name() const noexcept {
    return tunnel_.name();
  }

  tbc::val_a<std::span<Byte>> Discovery::receive(tbc::val_a<std::span<Byte>> bytes) {
    const auto size = ::read(tunnel_.descriptor(), bytes.data(), bytes.size());
    if (size < 0 && socketWouldBlock(sys::lastError())) {
      return {};
    }

    if (size <= 0) {
      throw SystemError{"Read discovery packet"};
    }

    return bytes.first(static_cast<std::size_t>(size));
  }

  void Discovery::inject(std::span<Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      throw std::invalid_argument{"Truncated discovery frame"};
    }

    // utun uses network byte order; DLT_NULL requires the host-order family.
    const auto family = ntohl(loadValue<std::uint32_t>(std::as_bytes(frame)));

    storeValue(std::as_writable_bytes(frame), family);

    const auto count = pcap_inject(injection_.get(), frame.data(), frame.size());
    if (count < 0 || static_cast<std::size_t>(count) != frame.size()) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

  tbc::val_a<std::span<const Byte>> Protocol::encode(tbc::val_a<std::span<Byte>> output, Kind kind, const Target& target) {
    plugins::FrameWriter writer{output};

    writer.integer(magic);
    writer.tag(kind);
    writer.text(target.host.view());
    writer.integer(target.port);
    return writer.finish();
  }

  void Protocol::send(int channel, const Connection& connection) {
    ds::Array<Byte, frame_bytes> output{};
    const auto frame_size = encode(output.viewMut(), Kind::connection, connection.target).size();
    auto frame = output.viewMut().first(frame_size);
    iovec vector{.iov_base = frame.data(), .iov_len = frame.size()};
    constexpr std::size_t descriptor_bytes = descriptor_count * sizeof(int);
    alignas(cmsghdr) ds::Array<Byte, CMSG_SPACE(descriptor_bytes)> control{};
    auto control_bytes = std::as_writable_bytes(control.viewMut());
    const ds::Array descriptors{connection.child.get(), connection.origin.get()};
    // One control message: its header at the front, the descriptors where CMSG_DATA finds them.
    const cmsghdr header{.cmsg_len = CMSG_LEN(descriptor_bytes), .cmsg_level = SOL_SOCKET, .cmsg_type = SCM_RIGHTS};

    storeValue(control_bytes, header);
    storeValue(control_bytes.subspan(CMSG_LEN(0)), descriptors);
    msghdr message{};

    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.dataMut();
    message.msg_controllen = control.size();
    auto written = ::sendmsg(channel, &message, 0);

    while (written < 0 && sys::lastError() == EINTR) {
      written = ::sendmsg(channel, &message, 0);
    }

    if (written <= 0) {
      throw SystemError{"Transfer redirected sockets"};
    }

    auto remaining = std::span<const Byte>{frame}.subspan(static_cast<std::size_t>(written));

    while (!remaining.empty()) {
      written = ::send(channel, remaining.data(), remaining.size(), 0);
      if (written < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (written <= 0) {
        throw SystemError{"Finish redirected socket transfer"};
      }

      remaining = remaining.subspan(static_cast<std::size_t>(written));
    }

    ::shutdown(channel, SHUT_WR);
  }

  bool Incoming::receive(int channel) {
    auto unread = bytes_.viewMut().subspan(size_);
    iovec vector{.iov_base = unread.data(), .iov_len = unread.size()};
    // Room for more descriptors than a frame carries: extra ones are adopted, closed and fail it.
    constexpr std::size_t descriptor_room = 8;
    alignas(cmsghdr) ds::Array<Byte, CMSG_SPACE(descriptor_room * sizeof(int))> control{};
    msghdr message{};

    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.dataMut();
    message.msg_controllen = control.size();
    const auto count = ::recvmsg(channel, &message, 0);
    if (count < 0) {
      if (socketWouldBlock(sys::lastError())) {
        return false;
      }

      throw SystemError{"Receive redirected sockets"};
    }

    bool invalid = anyFlag(message.msg_flags, MSG_CTRUNC);
    const auto control_bytes = std::as_bytes(control.view());

    for (auto* header = CMSG_FIRSTHDR(&message); header != nullptr; header = CMSG_NXTHDR(&message, header)) {
      const auto data = static_cast<std::size_t>(CMSG_DATA(header) - control.data());
      const auto descriptors = rightsCount(*header, control_bytes, data);
      if (!descriptors) {
        invalid = true;
        continue;
      }

      const auto payload = control_bytes.subspan(data, *descriptors * sizeof(int));

      for (std::size_t index = 0; index < *descriptors; ++index) {
        FileDescriptor received{loadValue<int>(payload.subspan(index * sizeof(int)))};

        if (received_ == sockets_.size()) {
          invalid = true;
        } else {
          sockets_.atMut(received_++) = std::move(received);
        }
      }
    }

    if (invalid) {
      throw EncodingError{"Invalid redirected socket descriptors"};
    }

    for (std::size_t index = 0; index < received_; ++index) {
      setCloseOnExec(sockets_[index].get());
    }

    if (count > 0 && size_ + static_cast<std::size_t>(count) == bytes_.size()) {
      throw EncodingError{"Invalid redirect frame"};
    }

    if (count > 0) {
      size_ += static_cast<std::size_t>(count);
      if (size_ < Protocol::header_bytes) {
        return false;
      }

      auto length = std::span<const Byte>{bytes_}.first(size_).subspan(sizeof(std::uint32_t) + sizeof(Byte));
      const auto host_bytes = LittleEndian<std::uint32_t>::decode(length);
      const auto expected = Protocol::header_bytes + static_cast<std::size_t>(host_bytes) + Protocol::tail_bytes;
      if (expected > bytes_.size() || size_ > expected) {
        throw EncodingError{"Invalid redirect frame length"};
      }

      return size_ == expected;
    }

    throw EncodingError{"Truncated redirect frame"};
  }

  Kind Incoming::kind() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    if (reader.integer<std::uint32_t>() != Protocol::magic) {
      throw EncodingError{"Incompatible redirect protocol"};
    }

    const auto kind = reader.tag(Kind::connection);
    if (kind != Kind::monitor && kind != Kind::connection) {
      throw EncodingError{"Unknown redirect operation"};
    }

    return kind;
  }

  void Incoming::validateMonitor() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};

    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    if (!reader.text().empty() || reader.integer<std::uint16_t>() != 0 || received_ != 0) {
      throw EncodingError{"A redirect monitor cannot carry sockets or a target"};
    }

    reader.finish();
  }

  Connection Incoming::take() {
    if (kind() != Kind::connection || received_ != Protocol::descriptor_count) {
      throw EncodingError{"A redirected connection requires two sockets"};
    }

    plugins::FrameReader reader{std::span{bytes_}.first(size_)};

    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    const auto host = reader.text();
    const auto port = reader.integer<std::uint16_t>();

    reader.finish();
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      throw EncodingError{"Invalid redirected host"};
    }

    ds::Array<char, Protocol::frame_bytes> address{};
    const auto authority = formatAuthority(address.viewMut(), host, port);
    if (authority.empty()) {
      throw EncodingError{"Invalid redirect destination"};
    }

    const auto target = Target::parse(authority);

    for (const auto& socket : sockets_) {
      int type = 0;
      socklen_t length = sizeof(type);
      if (::getsockopt(socket.get(), SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM) {
        throw EncodingError{"Redirect handoff requires connected TCP sockets"};
      }

      const auto peer = socketAddress(socket.get(), SocketEnd::peer);
      if (!peer || peer->ss_family != target.endpoint.storage.ss_family) {
        throw EncodingError{"Redirect handoff requires connected TCP sockets"};
      }

      configureProxySocket(socket.get());
    }

    const auto actual = socketAddress(sockets_[1].get(), SocketEnd::peer);
    if (!actual) {
      throw SystemError{"Inspect redirected origin"};
    }

    if (!reaches(*actual, target)) {
      throw EncodingError{"Redirected origin does not match its original destination"};
    }

    return {.child = std::move(sockets_.atMut(0)), .origin = std::move(sockets_.atMut(1)), .target = target};
  }

  bool PrivilegedPeer::allows(uid_t uid) noexcept {
    return uid == 0;
  }
}
