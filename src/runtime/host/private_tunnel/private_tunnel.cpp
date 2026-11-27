module telar.runtime.host.private_tunnel;

import telar.platform.error;
import telar.base.ds;

#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
import telar.tbc;
#endif

#ifdef __linux__
namespace telar::runtime {

  PrivateTunnel::PrivateTunnel()
      : tunnel_(::open("/dev/net/tun", O_RDWR | O_CLOEXEC | O_NONBLOCK)) {
    if (!tunnel_) {
      throw SystemError{"Open private tunnel"};
    }

    ifreq request{};
    constexpr std::string_view pattern = "telar%d";
    std::ranges::copy(pattern, sys::interfaceName(request));
    sys::interfaceFlags(request) = IFF_TUN;
    if (::ioctl(tunnel_.get(), TUNSETIFF, &request) != 0) {
      throw SystemError{"Create private tunnel"};
    }
    name_.assign(sys::interfaceName(request));
    index_ = ::if_nametoindex(sys::interfaceName(request));
    if (index_ == 0) {
      throw SystemError{"Read private tunnel index"};
    }

    const FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &request) != 0) {
      throw SystemError{"Read private tunnel flags"};
    }
    sys::interfaceFlags(request) |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &request) != 0) {
      throw SystemError{"Enable private tunnel"};
    }
  }

  ssize_t PrivateTunnel::write(std::span<const std::uint8_t> bytes) const noexcept {
    constexpr std::size_t family_bytes = sizeof(std::uint32_t);
    if (bytes.size() < family_bytes) {
      sys::setLastError(EINVAL);
      return -1;
    }

    std::uint32_t family = 0;

    std::memcpy(&family, bytes.data(), sizeof(family));
    family = ntohl(family);
    if (family != AF_INET && family != AF_INET6) {
      sys::setLastError(EAFNOSUPPORT);
      return -1;
    }

    tun_pi header{};

    header.proto = htons(family == AF_INET ? ETH_P_IP : ETH_P_IPV6);
    const auto payload = bytes.subspan(family_bytes);
    const ds::Array buffers{iovec{&header, sizeof(header)}, iovec{tbc::raw(const_cast<std::uint8_t*>(payload.data())), payload.size()}};

    return ::writev(tunnel_.get(), buffers.data(), buffers.size());
  }

  int PrivateTunnel::descriptor() const noexcept {
    return tunnel_.get();
  }

  unsigned PrivateTunnel::index() const noexcept {
    return index_;
  }

  std::string_view PrivateTunnel::name() const noexcept {
    return name_.view();
  }

}

#endif

#ifdef __APPLE__
namespace telar::runtime {

  PrivateTunnel::PrivateTunnel()
      : tunnel_(::socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)) {
    if (!tunnel_) {
      throw SystemError{"Open redirect discovery tunnel"};
    }

    setCloseOnExec(tunnel_.get());
    ctl_info control{};
    constexpr std::string_view name = UTUN_CONTROL_NAME;

    std::ranges::copy(name, std::span{control.ctl_name}.begin());
    if (::ioctl(tunnel_.get(), CTLIOCGINFO, &control) != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Find redirect discovery control"};
    }

    sockaddr_ctl address{};

    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = control.ctl_id;
    if (::connect(tunnel_.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
      throw SystemError{"Create redirect discovery interface"};
    }

    ds::Array<char, IFNAMSIZ> interface{};
    socklen_t length = interface.size();
    if (::getsockopt(tunnel_.get(), SYSPROTO_CONTROL, UTUN_OPT_IFNAME, interface.dataMut(), &length) != 0 || interface.back() != '\0') {
      throw SystemError{"Read redirect discovery interface"};
    }

    name_.assign(interface.data());
    index_ = ::if_nametoindex(interface.data());
    if (index_ == 0) {
      throw SystemError{"Read redirect discovery interface index"};
    }

    FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM, 0)};
    ifreq flags{};

    std::ranges::copy(name_.view(), std::span{sys::interfaceName(flags)}.begin());
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &flags) != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Read discovery interface flags"};
    }

    auto& interface_flags = sys::interfaceFlags(flags);

    // The flag bits are combined unsigned.
    interface_flags = static_cast<short>(static_cast<unsigned>(interface_flags) | static_cast<unsigned>(IFF_UP));
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &flags) != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Enable redirect discovery interface"};
    }

    // utun creation does not attach IP protocol handlers. PF's ifnet_output
    // needs them even though this interface has no configured IP addresses.
    if (::ioctl(configuration.get(), SIOCPROTOATTACH, &flags) != 0 && sys::lastError() != EEXIST) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Attach discovery IPv4 protocol"};
    }

    FileDescriptor ipv6{::socket(AF_INET6, SOCK_DGRAM, 0)};
    in6_aliasreq request{};

    std::ranges::copy(name_.view(), std::span{request.ifra_name}.begin());
    if (!ipv6 || (::ioctl(ipv6.get(), SIOCPROTOATTACH_IN6, &request) != 0 && sys::lastError() != EEXIST)) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Attach discovery IPv6 protocol"};
    }

    setNonblocking(tunnel_.get());
  }

  ssize_t PrivateTunnel::write(std::span<const std::uint8_t> bytes) const noexcept {
    return ::write(tunnel_.get(), bytes.data(), bytes.size());
  }

  int PrivateTunnel::descriptor() const noexcept {
    return tunnel_.get();
  }

  unsigned PrivateTunnel::index() const noexcept {
    return index_;
  }

  std::string_view PrivateTunnel::name() const noexcept {
    return name_.view();
  }

}

#endif
