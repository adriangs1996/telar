module telar.runtime.redirect.ingress;

import telar.native.pcap;
import telar.sys.socket;

namespace telar::runtime::redirect {

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

    return {host, static_cast<std::uint16_t>(port)};
  }

  Target Target::parse(std::string_view text) {
    const auto [host, port] = authority(text);
    if (host.size() >= INET6_ADDRSTRLEN) {
      throw std::invalid_argument{"Redirect target must be a numeric IP address"};
    }

    std::array<char, INET6_ADDRSTRLEN> terminated{};

    std::ranges::copy(host, terminated.begin());
    Target result;
    in_addr v4{};
    in6_addr v6{};

    if (::inet_pton(AF_INET, terminated.data(), &v4) == 1) {
      const auto address = ntohl(v4.s_addr);
      if (address == INADDR_ANY || address == INADDR_BROADCAST || IN_MULTICAST(address)) {
        throw std::invalid_argument{"Redirect target must be unicast"};
      }

      result.endpoint = NetworkAddress::ipv4(v4);
      ::inet_ntop(AF_INET, &v4, terminated.data(), terminated.size());
    } else if (::inet_pton(AF_INET6, terminated.data(), &v6) == 1) {
      if (IN6_IS_ADDR_UNSPECIFIED(&v6) || IN6_IS_ADDR_MULTICAST(&v6) || IN6_IS_ADDR_LINKLOCAL(&v6) || IN6_IS_ADDR_V4MAPPED(&v6)) {
        throw std::invalid_argument{"Redirect IPv6 target must be unicast without a scope"};
      }

      result.endpoint = NetworkAddress::ipv6(v6);
      ::inet_ntop(AF_INET6, &v6, terminated.data(), terminated.size());
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
    std::array<char, PCAP_ERRBUF_SIZE> error{};

    injection_.reset(pcap_open_live("lo0", 64, 0, 1, error.data()));
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
    if (::ioctl(descriptor, complete_headers, &complete) != 0) {
      throw SystemError{"Configure complete loopback injection headers"};
    }

    bpf_insn reject = BPF_STMT(BPF_RET | BPF_K, 0);
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

  tbc::view<std::span<Byte>, tbc::lt::a> Discovery::receive(tbc::view<std::span<Byte>, tbc::lt::a> bytes) {
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

    std::uint32_t family;

    std::memcpy(&family, frame.data(), sizeof(family));
    family = ntohl(family);
    std::memcpy(frame.data(), &family, sizeof(family));
    // utun uses network byte order; DLT_NULL requires the host-order family.
    const auto count = pcap_inject(injection_.get(), frame.data(), frame.size());
    if (count < 0 || static_cast<std::size_t>(count) != frame.size()) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, Kind kind, const Target& target) {
    plugins::FrameWriter writer{output};

    writer.integer(magic);
    writer.tag(kind);
    writer.text(target.host.view());
    writer.integer(target.port);
    return writer.finish();
  }

  void Protocol::send(int channel, const Connection& connection) {
    std::array<Byte, frame_bytes> output;
    const auto frame = encode(output, Kind::connection, connection.target);
    iovec vector{.iov_base = const_cast<Byte*>(frame.data()), .iov_len = frame.size()};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(descriptor_count * sizeof(int))> control{};
    msghdr message{};

    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    auto* header = CMSG_FIRSTHDR(&message);

    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(descriptor_count * sizeof(int));
    const std::array descriptors{connection.child.get(), connection.origin.get()};

    std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(descriptors));
    ssize_t written;

    do {
      written = ::sendmsg(channel, &message, 0);
    } while (written < 0 && sys::lastError() == EINTR);

    if (written <= 0) {
      throw SystemError{"Transfer redirected sockets"};
    }

    auto remaining = frame.subspan(static_cast<std::size_t>(written));

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
    iovec vector{.iov_base = bytes_.data() + size_, .iov_len = bytes_.size() - size_};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(8 * sizeof(int))> control{};
    msghdr message{};

    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    const auto count = ::recvmsg(channel, &message, 0);
    if (count < 0) {
      if (socketWouldBlock(sys::lastError())) {
        return false;
      }

      throw SystemError{"Receive redirected sockets"};
    }

    bool invalid = (message.msg_flags & MSG_CTRUNC) != 0;

    for (auto* header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
      if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) {
        invalid = true;
        continue;
      }

      const auto descriptors = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);

      for (std::size_t index = 0; index < descriptors; ++index) {
        int raw;

        std::memcpy(&raw, CMSG_DATA(header) + index * sizeof(int), sizeof(raw));
        FileDescriptor received{raw};

        if (received_ == sockets_.size()) {
          invalid = true;
        } else {
          sockets_[received_++] = std::move(received);
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

    std::array<char, Protocol::frame_bytes> address{};
    const auto count = std::snprintf(address.data(), address.size(), host.contains(':') ? "[%.*s]:%u" : "%.*s:%u", static_cast<int>(host.size()), host.data(), port);
    if (count < 0 || static_cast<std::size_t>(count) >= address.size()) {
      throw EncodingError{"Invalid redirect destination"};
    }

    auto target = Target::parse(address.data());

    for (const auto& socket : sockets_) {
      int type = 0;
      socklen_t length = sizeof(type);
      sockaddr_storage peer{};
      socklen_t peer_length = sizeof(peer);
      if (::getsockopt(socket.get(), SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM || ::getpeername(socket.get(), reinterpret_cast<sockaddr*>(&peer), &peer_length) != 0 || peer.ss_family != target.endpoint.storage.ss_family) {
        throw EncodingError{"Redirect handoff requires connected TCP sockets"};
      }

      configureProxySocket(socket.get());
    }

    sockaddr_storage actual{};
    socklen_t size = sizeof(actual);
    if (::getpeername(sockets_[1].get(), reinterpret_cast<sockaddr*>(&actual), &size) != 0) {
      throw SystemError{"Inspect redirected origin"};
    }

    const bool matches = actual.ss_family == AF_INET
                             ? reinterpret_cast<const sockaddr_in*>(&actual)->sin_port == htons(target.port) && reinterpret_cast<const sockaddr_in*>(&actual)->sin_addr.s_addr == reinterpret_cast<const sockaddr_in*>(&target.endpoint.storage)->sin_addr.s_addr
                             : reinterpret_cast<const sockaddr_in6*>(&actual)->sin6_port == htons(target.port) && std::memcmp(&reinterpret_cast<const sockaddr_in6*>(&actual)->sin6_addr, &reinterpret_cast<const sockaddr_in6*>(&target.endpoint.storage)->sin6_addr, sizeof(in6_addr)) == 0;
    if (!matches) {
      throw EncodingError{"Redirected origin does not match its original destination"};
    }

    return {.child = std::move(sockets_[0]), .origin = std::move(sockets_[1]), .target = target};
  }

  bool PrivilegedPeer::allows(uid_t uid) noexcept {
    return uid == 0;
  }
}
