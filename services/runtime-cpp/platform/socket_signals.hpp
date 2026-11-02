#pragma once

#include "error.hpp"
#include <csignal>
#include <sys/socket.h>

namespace telar::runtime {

inline void suppressSocketSignals(int descriptor) {
#if defined(SO_NOSIGPIPE)
  const int enabled = 1;
  if (::setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
    throw SystemError{"Disable socket SIGPIPE"};
  }
#else
  (void)descriptor;
  if (::signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
    throw SystemError{"Disable socket SIGPIPE"};
  }
#endif
}

}
