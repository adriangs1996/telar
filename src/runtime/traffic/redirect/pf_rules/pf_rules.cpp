module telar.runtime.traffic.redirect.pf_rules;

import telar.tbc;
import telar.base.text.utf8;
import telar.platform.error;
import telar.platform.net;
import telar.plugins;
import telar.base.ds;

#ifdef __APPLE__
import telar.sys.apple;
#endif

namespace telar::runtime::redirect {

  namespace {

    // The minimum sizes of the headers a discovered SYN carries.
    constexpr std::size_t ipv4_header_bytes = 20;
    constexpr std::size_t ipv6_header_bytes = 40;
    constexpr std::size_t tcp_header_bytes = 20;

    // IPv4's header length and TCP's data offset count 32-bit words.
    constexpr std::size_t header_word_bytes = 4;
    constexpr unsigned nibble_bits = 4;
    constexpr unsigned low_nibble = 0x0f;

    // The IP version in the high nibble of the first byte.
    constexpr unsigned ipv4_version = 4;
    constexpr unsigned ipv6_version = 6;

    // Field offsets in the IPv4 header.
    constexpr std::size_t ipv4_total_length = 2;
    constexpr std::size_t ipv4_fragment = 6;
    constexpr std::size_t ipv4_protocol = 9;
    constexpr std::size_t ipv4_source = 12;
    constexpr std::size_t ipv4_destination = 16;
    // The more-fragments flag and the fragment offset.
    constexpr unsigned ipv4_fragment_mask = 0x3fff;

    // Field offsets in the IPv6 header.
    constexpr std::size_t ipv6_payload_length = 4;
    constexpr std::size_t ipv6_next_header = 6;
    constexpr std::size_t ipv6_source = 8;
    constexpr std::size_t ipv6_destination = 24;
    constexpr std::size_t maximum_extension_headers = 8;
    // Hop-by-hop, routing and destination options count 8-byte units past the first; an
    // authentication header counts 4-byte words past the first two.
    constexpr std::size_t extension_unit_bytes = 8;
    constexpr std::size_t authentication_word_bytes = 4;

    // Field offsets in the TCP header.
    constexpr std::size_t tcp_data_offset = 12;
    constexpr std::size_t tcp_flags = 13;
    // FIN, SYN, RST and ACK: a SYN carries only its own.
    constexpr unsigned handshake_flags = 0x17;
    constexpr unsigned syn_flag = 0x02;

    constexpr unsigned highNibble(Byte byte) noexcept {
      return static_cast<unsigned>(byte) >> nibble_bits;
    }

    constexpr unsigned lowNibble(Byte byte) noexcept {
      return static_cast<unsigned>(byte) & low_nibble;
    }

    // Where the TCP header starts behind an IPv6 header and the extension headers a SYN may carry.
    ds::Option<std::size_t> ipv6TcpOffset(std::span<const Byte> packet) noexcept {
      std::size_t offset = ipv6_header_bytes;
      unsigned next = packet[ipv6_next_header];

      for (std::size_t count = 0; next != IPPROTO_TCP; ++count) {
        if (count == maximum_extension_headers || offset + 2 > packet.size() || (next != IPPROTO_HOPOPTS && next != IPPROTO_ROUTING && next != IPPROTO_DSTOPTS && next != IPPROTO_AH)) {
          return ds::none;
        }

        const std::size_t units = packet[offset + 1];
        const auto length = next == IPPROTO_AH ? (units + 2) * authentication_word_bytes : (units + 1) * extension_unit_bytes;

        next = packet[offset];
        offset += length;
      }

      return offset;
    }

  }

  bool FlowKey::matches(const FlowKey& other) const noexcept {
    return same(source, other.source) && same(destination, other.destination);
  }

  bool FlowKey::same(const Target& left, const Target& right) noexcept {
    return left.port == right.port && left.host.view() == right.host.view();
  }

  ds::Option<FlowKey> FlowKey::syn(std::span<const Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      return ds::none;
    }

    const auto family = ntohl(loadValue<std::uint32_t>(std::as_bytes(frame)));
    const auto packet = frame.subspan(sizeof(std::uint32_t));
    std::size_t offset = 0;
    std::size_t source = 0;
    std::size_t destination = 0;

    if (family == AF_INET && packet.size() >= ipv4_header_bytes && highNibble(packet[0]) == ipv4_version) {
      offset = std::size_t{lowNibble(packet[0])} * header_word_bytes;
      if (offset < ipv4_header_bytes || offset > packet.size() || number(packet, ipv4_total_length) != packet.size() || (static_cast<unsigned>(number(packet, ipv4_fragment)) & ipv4_fragment_mask) != 0 || packet[ipv4_protocol] != IPPROTO_TCP) {
        return ds::none;
      }

      source = ipv4_source;
      destination = ipv4_destination;
    } else if (family == AF_INET6 && packet.size() >= ipv6_header_bytes && highNibble(packet[0]) == ipv6_version) {
      if (number(packet, ipv6_payload_length) + ipv6_header_bytes != packet.size()) {
        return ds::none;
      }

      const auto tcp = ipv6TcpOffset(packet);
      if (!tcp) {
        return ds::none;
      }

      offset = *tcp;
      source = ipv6_source;
      destination = ipv6_destination;
    } else {
      return ds::none;
    }

    if (offset + tcp_header_bytes > packet.size() || (static_cast<unsigned>(packet[offset + tcp_flags]) & handshake_flags) != syn_flag) {
      return ds::none;
    }

    const auto header = std::size_t{highNibble(packet[offset + tcp_data_offset])} * header_word_bytes;
    if (header < tcp_header_bytes || header > packet.size() - offset) {
      return ds::none;
    }

    try {
      return FlowKey{.source = endpoint(family, packet.subspan(source), number(packet, offset)), .destination = endpoint(family, packet.subspan(destination), number(packet, offset + 2))};
    } catch (const std::invalid_argument&) {
      return ds::none;
    }
  }

  std::uint16_t FlowKey::number(std::span<const Byte> bytes, std::size_t offset) noexcept {
    constexpr unsigned byte_bits = 8;

    return static_cast<std::uint16_t>((static_cast<unsigned>(bytes[offset]) << byte_bits) | static_cast<unsigned>(bytes[offset + 1]));
  }

  Target FlowKey::endpoint(unsigned family, std::span<const Byte> bytes, std::uint16_t port) {
    ds::Array<char, INET6_ADDRSTRLEN> host{};
    if (::inet_ntop(static_cast<int>(family), bytes.data(), host.dataMut(), host.size()) == nullptr) {
      throw std::invalid_argument{"Invalid discovery address"};
    }

    // Room for the brackets, the colon and the port.
    constexpr std::size_t port_text_bytes = 16;
    ds::Array<char, INET6_ADDRSTRLEN + port_text_bytes> text{};

    return Target::parse(formatAuthority(text.viewMut(), std::string_view{host.data()}, port));
  }

#ifdef __APPLE__

  namespace {

    constexpr std::size_t maximum_label_bytes = 48;
    // Every flow, incoming flow and bypass is a rule of its own.
    constexpr std::size_t maximum_scope_entries = 256;
    constexpr unsigned maximum_log_interfaces = 16;
    constexpr std::string_view tunnel_prefix = "utun";
    constexpr std::string_view label_characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    constexpr std::string_view interface_characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-";

    std::string_view familyName(const Target& target) noexcept {
      return target.endpoint.storage.ss_family == AF_INET6 ? "inet6" : "inet";
    }

    std::string_view loopbackHost(const Target& target) noexcept {
      return target.endpoint.storage.ss_family == AF_INET6 ? "::1" : "127.0.0.1";
    }

    bool validLabel(std::string_view label) noexcept {
      return !label.empty() && label.size() <= maximum_label_bytes && label.find_first_not_of(label_characters) == std::string_view::npos;
    }

    bool validDiscoveryInterface(std::string_view interface) {
      return interface.starts_with(tunnel_prefix) && interface.size() > tunnel_prefix.size() && interface.size() < IFNAMSIZ && interface.substr(tunnel_prefix.size()).find_first_not_of("0123456789") == std::string_view::npos;
    }

    // At least one direction, and flows only in the directions the scope allows.
    bool validDirections(const PfScope& scope) noexcept {
      const bool incoming = allowsIncoming(scope.direction);
      const bool outgoing = allowsOutgoing(scope.direction);

      return (incoming || outgoing) && (outgoing || (scope.flows.empty() && scope.bypasses.empty())) && (incoming || scope.incoming_flows.empty());
    }

    void validateListeners(std::span<const Mapping> mappings) {
      for (const auto& mapping : mappings) {
        if (mapping.listener_port == 0 || (mapping.target.host.view() == "127.0.0.1" && mapping.listener_port == mapping.target.port) || (mapping.target.host.view() == "::1" && mapping.listener_port == mapping.target.port)) {
          throw std::invalid_argument{"Redirect listener overlaps its destination"};
        }
      }
    }

    // Discovery has already selected the account. Exact tuples survive loopback
    // metadata changes and cannot match the helper's distinct upstream sockets.
    void validateIncomingFlows(std::span<const Mapping> mappings, std::span<const FlowKey> flows) {
      for (const auto& flow : flows) {
        if (!std::ranges::any_of(mappings, [&](const auto& mapping) {
              return mapping.incoming && FlowKey::same(mapping.target, flow.destination);
            })) {
          throw std::invalid_argument{"Incoming flow is outside the local destination scope"};
        }
      }
    }

    void validateBypass(const Bypass& bypass, std::string_view discovery_interface, std::span<const Mapping> mappings) {
      const auto& flow = bypass.key;
      const auto name = bypass.route.interface.view();
      const auto gateway = bypass.route.gateway.view();
      const auto family = flow.destination.endpoint.storage.ss_family;
      ds::Array<char, INET6_ADDRSTRLEN> text{};
      ds::Array<Byte, sizeof(in6_addr)> address{};

      if (name.empty() || name.size() >= IFNAMSIZ || name == discovery_interface || name.find_first_not_of(interface_characters) != std::string_view::npos || gateway.empty() || gateway.size() >= text.size() || family != flow.source.endpoint.storage.ss_family || !std::ranges::any_of(mappings, [&](const auto& mapping) {
            return FlowKey::same(mapping.target, flow.destination);
          })) {
        throw std::invalid_argument{"Invalid original route bypass"};
      }

      std::ranges::copy(gateway, text.viewMut().begin());
      if (::inet_pton(family, text.dataMut(), address.dataMut()) != 1) {
        throw std::invalid_argument{"Bypass gateway must be numeric"};
      }
    }

    void validateScope(std::span<const Mapping> mappings, const PfScope& scope) {
      if (scope.uid == 0 || mappings.empty() || mappings.size() > Target::maximum_targets || !validLabel(scope.label) || !validDiscoveryInterface(scope.discovery_interface) || scope.flows.size() + scope.incoming_flows.size() + scope.bypasses.size() > maximum_scope_entries || !validDirections(scope)) {
        throw std::invalid_argument{"Invalid transparent redirect scope"};
      }

      if ((scope.log_interface && *scope.log_interface >= maximum_log_interfaces) || (allowsIncoming(scope.direction) && !std::ranges::any_of(mappings, [](const auto& mapping) {
            return mapping.incoming;
          }))) {
        throw std::invalid_argument{"Invalid incoming discovery scope"};
      }

      validateListeners(mappings);
      validateIncomingFlows(mappings, scope.incoming_flows);
      for (const auto& bypass : scope.bypasses) {
        validateBypass(bypass, scope.discovery_interface, mappings);
      }
    }

    // The mapping that redirects a discovered flow's destination.
    tbc::ref_a<Mapping> selectedMapping(tbc::val_a<std::span<const Mapping>> mappings, const FlowKey& flow) {
      const auto selected = std::ranges::find_if(mappings, [&](const auto& mapping) {
        return FlowKey::same(mapping.target, flow.destination);
      });
      if (selected == mappings.end() || flow.source.endpoint.storage.ss_family != flow.destination.endpoint.storage.ss_family) {
        throw std::invalid_argument{"Discovered flow is outside the redirect scope"};
      }

      return *selected;
    }

    // A rule never outgrows its line: every field it formats is bounded.
    constexpr std::size_t rule_bytes = 512;

    // Where the rules go, a line at a time.
    struct Rules {
      ds::Function<void(std::string_view)> append;
      ds::Array<char, rule_bytes> line{};
    };

    template <typename... Arguments>
    void emit(Rules& rules, std::format_string<Arguments...> format, Arguments&&... arguments) {
      const auto written = std::format_to_n(rules.line.dataMut(), static_cast<std::ptrdiff_t>(rules.line.size()), format, std::forward<Arguments>(arguments)...);
      if (std::cmp_greater(written.size, rules.line.size())) {
        throw std::length_error{"PF rule exceeds its bound"};
      }

      rules.append(std::string_view{rules.line.data(), static_cast<std::size_t>(written.size)});
    }

    // Translates each discovered flow to its listener on loopback.
    void writeRedirects(Rules& rules, std::span<const Mapping> mappings, std::span<const FlowKey> flows) {
      for (const auto& flow : flows) {
        const auto& selected = selectedMapping(mappings, flow);

        emit(rules, "rdr on lo0 {} proto tcp from {} port {} to {} port {} -> {} port {}\n", familyName(flow.destination), flow.source.host.view(), flow.source.port, flow.destination.host.view(), flow.destination.port, selected.listenerAddress(), selected.listener_port);
      }
    }

    // Sends a flow the process selection leaves alone out its original route.
    void writeBypasses(Rules& rules, std::span<const Bypass> bypasses, uid_t uid) {
      for (const auto& bypass : bypasses) {
        const auto& flow = bypass.key;

        emit(rules, "pass out quick route-to ({} {}) {} proto tcp from {} port {} to {} port {} user {} flags S/SA no state\n", bypass.route.interface.view(), bypass.route.gateway.view(), familyName(flow.destination), flow.source.host.view(), flow.source.port, flow.destination.host.view(), flow.destination.port, uid);
      }
    }

    // Lets each translated flow reach its listener, labeled for the session.
    void writeListenerPasses(Rules& rules, std::span<const Mapping> mappings, std::span<const FlowKey> flows, std::string_view label) {
      for (const auto& flow : flows) {
        const auto& selected = selectedMapping(mappings, flow);

        emit(rules, "pass in quick on lo0 {} proto tcp from {} port {} to {} port {} flags S/SA keep state label \"{}\"\n", familyName(flow.destination), flow.source.host.view(), flow.source.port, selected.listenerAddress(), selected.listener_port, label);
      }
    }

    // Routes each discovered flow through loopback, where the redirect translates it.
    void writeLoopbackRoutes(Rules& rules, std::span<const FlowKey> flows, std::string_view rule, uid_t uid) {
      for (const auto& flow : flows) {
        emit(rules, "{} route-to (lo0 {}) {} proto tcp from {} port {} to {} port {} user {} flags any no state\n", rule, loopbackHost(flow.destination), familyName(flow.destination), flow.source.host.view(), flow.source.port, flow.destination.host.view(), flow.destination.port, uid);
      }
    }

    // Routes each destination's new connections through the discovery tunnel.
    void writeDiscovery(Rules& rules, std::span<const Mapping> mappings, const PfScope& scope) {
      const auto interface = scope.discovery_interface;

      for (const auto& mapping : mappings) {
        const auto host = mapping.target.host.view();
        const bool logged = (host == "::1" || scope.log_all) && scope.log_interface;
        if (logged && *scope.log_interface >= maximum_log_interfaces) {
          throw std::invalid_argument{"Invalid discovery log interface"};
        }

        if (allowsOutgoing(scope.direction)) {
          emit(rules, "pass out");
          if (logged) {
            emit(rules, " log (user, to pflog{})", *scope.log_interface);
          }

          emit(rules, " quick on ! {} route-to {} {} proto tcp from any to {} port {} user {} flags S/SA no state\n", interface, interface, familyName(mapping.target), host, mapping.target.port, scope.uid);
        }

        if (allowsIncoming(scope.direction) && mapping.incoming && scope.log_interface) {
          emit(rules, "pass in log (user, to pflog{}) quick on ! lo0 route-to {} {} proto tcp from any to {} port {} user {} flags S/SA no state\n", *scope.log_interface, interface, familyName(mapping.target), host, mapping.target.port, scope.uid);
        }
      }
    }

  }

  void writePfRules(std::span<const Mapping> mappings, const PfScope& scope, ds::Function<void(std::string_view)> append) {
    validateScope(mappings, scope);
    Rules rules{.append = std::move(append)};

    writeRedirects(rules, mappings, scope.flows);
    writeRedirects(rules, mappings, scope.incoming_flows);
    writeBypasses(rules, scope.bypasses, scope.uid);
    writeListenerPasses(rules, mappings, scope.flows, scope.label);
    writeListenerPasses(rules, mappings, scope.incoming_flows, scope.label);
    writeLoopbackRoutes(rules, scope.flows, "pass out quick", scope.uid);
    writeLoopbackRoutes(rules, scope.incoming_flows, "pass in quick on ! lo0", scope.uid);
    writeDiscovery(rules, mappings, scope);
  }

  NatLookup::NatLookup()
      : device_(::open("/dev/pf", combineFlags(O_RDWR, O_CLOEXEC, O_NOFOLLOW))) { // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!device_) {
      throw SystemError{"Open redirect NAT lookup"};
    }
  }

  bool NatLookup::matches(int socket, const FlowKey& flow) const {
    const auto peer = socketAddress(socket, SocketEnd::peer);
    if (!peer) {
      return false;
    }

    const auto local = socketAddress(socket, SocketEnd::local);
    if (!local || peer->ss_family != local->ss_family || peer->ss_family != flow.source.endpoint.storage.ss_family) {
      return false;
    }

    Request request;

    request.family = peer->ss_family;
    address(*peer, request.source.viewMut(), request.source_port);
    address(*local, request.destination.viewMut(), request.destination_port);
    if (::ioctl(device_.get(), lookup, &request) != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      return false;
    }

    ds::Array<Byte, address_bytes> expected{};
    std::uint32_t port = 0;

    address(flow.destination.endpoint.storage, expected.viewMut(), port);
    return expected == request.translated_destination && port == request.translated_destination_port;
  }

  bool NatLookup::peerMatches(int socket, const FlowKey& flow) {
    const auto peer = socketAddress(socket, SocketEnd::peer);
    if (!peer || peer->ss_family != flow.source.endpoint.storage.ss_family) {
      return false;
    }

    ds::Array<Byte, address_bytes> actual{};
    ds::Array<Byte, address_bytes> expected{};
    std::uint32_t actual_port = 0;
    std::uint32_t expected_port = 0;

    address(*peer, actual.viewMut(), actual_port);
    address(flow.source.endpoint.storage, expected.viewMut(), expected_port);
    return actual == expected && actual_port == expected_port;
  }

  void NatLookup::address(const sockaddr_storage& socket, std::span<Byte, address_bytes> bytes, std::uint32_t& port) {
    if (socket.ss_family == AF_INET) {
      const auto value = addressAs<sockaddr_in>(socket);

      storeValue(std::as_writable_bytes(bytes), value.sin_addr);
      port = value.sin_port;
    } else {
      const auto value = addressAs<sockaddr_in6>(socket);

      storeValue(std::as_writable_bytes(bytes), value.sin6_addr);
      port = value.sin6_port;
    }
  }

  RoutePath RoutePath::lookup(const Target& target, unsigned scope) {
    if (scope > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"Invalid route interface scope"};
    }

    FileDescriptor socket{::socket(PF_ROUTE, SOCK_RAW, 0)};
    if (!socket) {
      throw SystemError{"Open route lookup socket"};
    }

    setCloseOnExec(socket.get());
    setNonblocking(socket.get());
    // The request: the header, the destination and the interface to scope the route to.
    const auto destination_bytes = aligned(target.endpoint.length);
    rt_msghdr message{};
    sockaddr_dl interface{};
    auto destination = target.endpoint;

    message.rtm_msglen = static_cast<unsigned short>(sizeof(message) + destination_bytes + aligned(sizeof(interface)));
    message.rtm_version = RTM_VERSION;
    message.rtm_type = RTM_GET;
    message.rtm_index = static_cast<unsigned short>(scope);
    message.rtm_flags = combineFlags(RTF_UP, RTF_HOST, scope != 0 ? RTF_IFSCOPE : 0);
    message.rtm_addrs = combineFlags(RTA_DST, RTA_IFP);
    message.rtm_pid = ::getpid();
    message.rtm_seq = 1;
    destination.setPort(0);
    interface.sdl_len = sizeof(interface);
    interface.sdl_family = AF_LINK;
    interface.sdl_index = static_cast<unsigned short>(scope);
    ds::Array<Byte, maximum_message_bytes> bytes{};
    const auto request = std::as_writable_bytes(bytes.viewMut());

    storeValue(request, message);
    std::ranges::copy(std::as_bytes(std::span{&destination.storage, 1}).first(destination.length), request.subspan(sizeof(message)).begin());
    storeValue(request.subspan(sizeof(message) + destination_bytes), interface);
    auto sent = ::write(socket.get(), bytes.data(), message.rtm_msglen);

    while (sent < 0 && sys::lastError() == EINTR) {
      sent = ::write(socket.get(), bytes.data(), message.rtm_msglen);
    }

    if (std::cmp_not_equal(sent, message.rtm_msglen)) {
      throw SystemError{"Request original route"};
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{500};

    while (std::chrono::steady_clock::now() < deadline) {
      constexpr int poll_ms = 25;
      pollfd ready{.fd = socket.get(), .events = POLLIN, .revents = 0};
      if (::poll(&ready, 1, poll_ms) < 0 && sys::lastError() != EINTR) {
        throw SystemError{"Wait for original route"};
      }

      if (!anyFlag(ready.revents, POLLIN)) {
        continue;
      }

      const auto received = ::read(socket.get(), bytes.dataMut(), bytes.size());
      if (received < 0 && socketWouldBlock(sys::lastError())) {
        continue;
      }

      if (std::cmp_less(received, sizeof(message))) {
        throw SystemError{"Read original route", EIO};
      }

      const auto reply = loadValue<rt_msghdr>(std::as_bytes(bytes.view()));
      if (reply.rtm_pid != message.rtm_pid || reply.rtm_seq != message.rtm_seq || reply.rtm_type != RTM_GET) {
        continue;
      }

      auto result = decode(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(received)), target);
      if (scope != 0 && result.index != scope) {
        throw SystemError{"Original route changed interface", ENETUNREACH};
      }

      return result;
    }

    throw SystemError{"Original route lookup timed out", ETIMEDOUT};
  }

  RoutePath RoutePath::decode(std::span<const Byte> bytes, const Target& target) {
    if (bytes.size() < sizeof(rt_msghdr)) {
      throw EncodingError{"Truncated route reply"};
    }

    const auto message = loadValue<rt_msghdr>(std::as_bytes(bytes));
    if (message.rtm_msglen != bytes.size() || message.rtm_version != RTM_VERSION || message.rtm_type != RTM_GET) {
      throw EncodingError{"Invalid route reply"};
    }

    if (message.rtm_errno != 0) {
      throw SystemError{"Resolve original route", message.rtm_errno};
    }

    if (anyFlag(message.rtm_flags, RTF_REJECT, RTF_BLACKHOLE)) {
      throw SystemError{"Original route does not forward traffic", ENETUNREACH};
    }

    RoutePath path;

    path.index = message.rtm_index;
    std::size_t offset = sizeof(message);

    for (unsigned index = 0; index < RTAX_MAX; ++index) {
      if ((static_cast<unsigned>(message.rtm_addrs) & (1U << index)) == 0) {
        continue;
      }

      if (offset + 2 > bytes.size()) {
        throw EncodingError{"Truncated route address"};
      }

      const auto size = aligned(bytes[offset]);
      if (size > bytes.size() - offset) {
        throw EncodingError{"Invalid route address size"};
      }

      if (index == RTAX_GATEWAY && anyFlag(message.rtm_flags, RTF_GATEWAY)) {
        gatewayText(path.gateway, bytes.subspan(offset, size));
      }

      offset += size;
    }

    ds::Array<char, IFNAMSIZ> name{};
    if (path.index == 0 || (::if_indextoname(path.index, name.dataMut()) == nullptr)) {
      throw SystemError{"Original route interface is unavailable", ENXIO};
    }

    path.interface.assign(name.data());
    if (path.gateway.view().empty()) {
      path.gateway.assign(target.host.view());
    }

    return path;
  }

  std::size_t RoutePath::aligned(std::size_t size) noexcept {
    return size == 0 ? address_alignment : (size + address_alignment - 1) & ~(address_alignment - 1);
  }

  void RoutePath::gatewayText(FixedText<INET6_ADDRSTRLEN>& target, std::span<const Byte> address) {
    const auto length = address[0];
    const auto family = address[1];
    ds::Array<char, INET6_ADDRSTRLEN> text{};
    const char* formatted = nullptr;

    if (family == AF_INET && length >= sizeof(sockaddr_in)) {
      const auto gateway = loadValue<sockaddr_in>(std::as_bytes(address));

      formatted = ::inet_ntop(AF_INET, &gateway.sin_addr, text.dataMut(), text.size());
    } else if (family == AF_INET6 && length >= sizeof(sockaddr_in6)) {
      auto gateway = loadValue<sockaddr_in6>(std::as_bytes(address));
      if (IN6_IS_ADDR_LINKLOCAL(&gateway.sin6_addr)) {
        // Darwin embeds the interface scope in the second 16-bit word.
        std::ranges::fill(std::span{sys::addressBytes(gateway.sin6_addr)}.subspan(sizeof(std::uint16_t), sizeof(std::uint16_t)), Byte{0});
      }

      formatted = ::inet_ntop(AF_INET6, &gateway.sin6_addr, text.dataMut(), text.size());
    } else {
      throw EncodingError{"Unsupported original route gateway"};
    }

    if (formatted == nullptr) {
      throw SystemError{"Format original route gateway"};
    }

    target.assign(text.data());
  }

  std::string_view Mapping::listenerAddress() const noexcept {
    if (incoming) {
      return target.host.view();
    }

    return loopbackHost(target);
  }

  template <Allocator Memory>
  PfIdentity<Memory>::PfIdentity(Memory& memory, std::string_view endpoint)
      : anchor(memory),
        label(memory) {
    ds::formatTo(label, "tlr_{:016x}", plugins::stableId(endpoint));
    anchor.assign("com.apple/telar-redirect-");
    anchor.append(label);
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> pfRules(tbc::mut_a<Memory> memory, std::span<const Mapping> mappings, const PfScope& scope) {
    ds::String<Memory> rules{memory};

    writePfRules(mappings, scope, [&rules](std::string_view rule) {
      rules.append(rule);
    });

    return rules;
  }

  template class PfIdentity<Memory>;
  template class PfIdentity<ConcurrentMemory>;
  template ds::String<Memory> pfRules<Memory>(Memory& memory, std::span<const Mapping> mappings, const PfScope& scope);
  template ds::String<ConcurrentMemory> pfRules<ConcurrentMemory>(ConcurrentMemory& memory, std::span<const Mapping> mappings, const PfScope& scope);
#endif

}
