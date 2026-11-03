#pragma once

#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <net/if.h>
#include <net/if_utun.h>
#include <netinet6/in6_var.h>
#include <span>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>

namespace telar::runtime {

class PrivateTunnel {
public:
  PrivateTunnel() : tunnel_(::socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)) {
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
    if (::connect(tunnel_.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
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
    std::copy(name_.view().begin(), name_.view().end(), flags.ifr_name);
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &flags) != 0) {
      throw SystemError{"Read discovery interface flags"};
    }
    flags.ifr_flags |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &flags) != 0) {
      throw SystemError{"Enable redirect discovery interface"};
    }
    // utun creation does not attach IP protocol handlers. PF's ifnet_output
    // needs them even though this interface has no configured IP addresses.
    constexpr unsigned long attach_ipv4 = _IOWR('i', 80, ifreq); // SIOCPROTOATTACH
    if (::ioctl(configuration.get(), attach_ipv4, &flags) != 0 && errno != EEXIST) {
      throw SystemError{"Attach discovery IPv4 protocol"};
    }
    FileDescriptor ipv6{::socket(AF_INET6, SOCK_DGRAM, 0)};
    in6_aliasreq request{};
    std::copy(name_.view().begin(), name_.view().end(), request.ifra_name);
    constexpr unsigned long attach_ipv6 = _IOWR('i', 110, in6_aliasreq); // SIOCPROTOATTACH_IN6
    if (!ipv6 || (::ioctl(ipv6.get(), attach_ipv6, &request) != 0 && errno != EEXIST)) {
      throw SystemError{"Attach discovery IPv6 protocol"};
    }
    setNonblocking(tunnel_.get());
  }

  ssize_t write(std::span<const std::uint8_t> bytes) const noexcept { return ::write(tunnel_.get(), bytes.data(), bytes.size()); }

  int descriptor() const noexcept { return tunnel_.get(); }
  unsigned index() const noexcept { return index_; }
  std::string_view name() const noexcept { return name_.view(); }

private:
  FileDescriptor tunnel_;
  FixedText<IFNAMSIZ> name_;
  unsigned index_ = 0;
};

}
