module;
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

#if defined(__linux__)

#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/uio.h>

#endif

#if defined(__APPLE__)

#include <net/if.h>
#include <net/if_utun.h>
#include <netinet6/in6_var.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>

#endif

module telar.runtime.platform.private_tunnel;

#if defined(__linux__)
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

    std::uint32_t family;
    std::memcpy(&family, bytes.data(), sizeof(family));
    family = ntohl(family);
    if (family != AF_INET && family != AF_INET6) {
      sys::setLastError(EAFNOSUPPORT);
      return -1;
    }

    tun_pi header{};
    header.proto = htons(family == AF_INET ? ETH_P_IP : ETH_P_IPV6);
    const auto payload = bytes.subspan(family_bytes);
    const std::array buffers{iovec{&header, sizeof(header)}, iovec{const_cast<std::uint8_t*>(payload.data()), payload.size()}};
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

#if defined(__APPLE__)
namespace telar::runtime {

  PrivateTunnel::PrivateTunnel()
      : tunnel_(::socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)) {
    if (!tunnel_) {
      throw SystemError{"Open redirect discovery tunnel"};
    }

    setCloseOnExec(tunnel_.get());
    ctl_info control{};
    constexpr std::string_view name = UTUN_CONTROL_NAME;

    std::copy(name.begin(), name.end(), control.ctl_name);
    if (::ioctl(tunnel_.get(), CTLIOCGINFO, &control) != 0) {
      throw SystemError{"Find redirect discovery control"};
    }

    sockaddr_ctl address{};

    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = control.ctl_id;
    if (::connect(tunnel_.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
      throw SystemError{"Create redirect discovery interface"};
    }

    std::array<char, IFNAMSIZ> interface{};
    socklen_t length = interface.size();
    if (::getsockopt(tunnel_.get(), SYSPROTO_CONTROL, UTUN_OPT_IFNAME, interface.data(), &length) != 0 || interface.back() != '\0') {
      throw SystemError{"Read redirect discovery interface"};
    }

    name_.assign(interface.data());
    index_ = ::if_nametoindex(interface.data());
    if (index_ == 0) {
      throw SystemError{"Read redirect discovery interface index"};
    }

    FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM, 0)};
    ifreq flags{};

    std::copy(name_.view().begin(), name_.view().end(), sys::interfaceName(flags));
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &flags) != 0) {
      throw SystemError{"Read discovery interface flags"};
    }

    sys::interfaceFlags(flags) |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &flags) != 0) {
      throw SystemError{"Enable redirect discovery interface"};
    }

    // utun creation does not attach IP protocol handlers. PF's ifnet_output
    // needs them even though this interface has no configured IP addresses.
    constexpr unsigned long attach_ipv4 = _IOWR('i', 80, ifreq); // SIOCPROTOATTACH
    if (::ioctl(configuration.get(), attach_ipv4, &flags) != 0 && sys::lastError() != EEXIST) {
      throw SystemError{"Attach discovery IPv4 protocol"};
    }

    FileDescriptor ipv6{::socket(AF_INET6, SOCK_DGRAM, 0)};
    in6_aliasreq request{};

    std::copy(name_.view().begin(), name_.view().end(), request.ifra_name);
    constexpr unsigned long attach_ipv6 = _IOWR('i', 110, in6_aliasreq); // SIOCPROTOATTACH_IN6
    if (!ipv6 || (::ioctl(ipv6.get(), attach_ipv6, &request) != 0 && sys::lastError() != EEXIST)) {
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
