#pragma once

#include <cstddef>
#include <sys/un.h>

namespace telar::gui::platform {

struct SocketLimits {
  static constexpr std::size_t path_bytes = sizeof(sockaddr_un{}.sun_path) - 1;
};

}
