#pragma once

#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <cstdio>
#include <net/if.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>

namespace telar::runtime::redirect {

class LogInterface {
public:
  static constexpr unsigned maximum = 16;

  static unsigned create() {
    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) { throw SystemError{"Open PF log interface control"}; }
    for (unsigned candidate = maximum; candidate != 0; --candidate) {
      ifreq request{};
      std::snprintf(request.ifr_name, sizeof(request.ifr_name), "pflog%u", candidate - 1);
      if (::ioctl(control.get(), SIOCIFCREATE, &request) == 0) { return candidate - 1; }
      if (errno != EEXIST) { throw SystemError{"Create private PF log interface"}; }
    }
    throw SystemError{"No private PF log interface available", ENOSPC};
  }

  static void remove(unsigned index) {
    if (index >= maximum) { throw std::invalid_argument{"Invalid private PF log interface"}; }
    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) { throw SystemError{"Open PF log interface control"}; }
    ifreq request{};
    std::snprintf(request.ifr_name, sizeof(request.ifr_name), "pflog%u", index);
    if (::ioctl(control.get(), SIOCIFDESTROY, &request) != 0 && errno != ENXIO && errno != ENODEV) {
      throw SystemError{"Remove private PF log interface"};
    }
  }
};

}
