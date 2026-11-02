#pragma once

#include "../error.hpp"
#include "../file_descriptor.hpp"
#include "../../memory/fixed_text.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <cstdint>
#include <fcntl.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <span>
#include <sys/ioctl.h>
#include <sys/uio.h>

namespace telar::runtime {

class PrivateTunnel {
public:
  PrivateTunnel() : tunnel_(::open("/dev/net/tun", O_RDWR | O_CLOEXEC | O_NONBLOCK)) {
    if (!tunnel_) {
      throw SystemError{"Open private tunnel"};
    }

    ifreq request{};
    constexpr std::string_view pattern = "telar%d";
    std::ranges::copy(pattern, request.ifr_name);
    request.ifr_flags = IFF_TUN;
    if (::ioctl(tunnel_.get(), TUNSETIFF, &request) != 0) {
      throw SystemError{"Create private tunnel"};
    }
    name_.assign(request.ifr_name);
    index_ = ::if_nametoindex(request.ifr_name);
    if (index_ == 0) {
      throw SystemError{"Read private tunnel index"};
    }

    const FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &request) != 0) {
      throw SystemError{"Read private tunnel flags"};
    }
    request.ifr_flags |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &request) != 0) {
      throw SystemError{"Enable private tunnel"};
    }
  }

  ssize_t write(std::span<const std::uint8_t> bytes) const noexcept {
    constexpr std::size_t family_bytes = sizeof(std::uint32_t);
    if (bytes.size() < family_bytes) {
      errno = EINVAL;
      return -1;
    }

    std::uint32_t family;
    std::memcpy(&family, bytes.data(), sizeof(family));
    family = ntohl(family);
    if (family != AF_INET && family != AF_INET6) {
      errno = EAFNOSUPPORT;
      return -1;
    }

    tun_pi header{};
    header.proto = htons(family == AF_INET ? ETH_P_IP : ETH_P_IPV6);
    const auto payload = bytes.subspan(family_bytes);
    const std::array buffers{iovec{&header, sizeof(header)}, iovec{const_cast<std::uint8_t *>(payload.data()), payload.size()}};
    return ::writev(tunnel_.get(), buffers.data(), buffers.size());
  }

  int descriptor() const noexcept { return tunnel_.get(); }
  unsigned index() const noexcept { return index_; }
  std::string_view name() const noexcept { return name_.view(); }

private:
  FileDescriptor tunnel_;
  FixedText<IFNAMSIZ> name_;
  unsigned index_ = 0;
};

}
