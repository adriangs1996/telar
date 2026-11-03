#include "telar_platform/socket_signals.hpp"
#pragma once

#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

namespace telar::runtime {

inline bool socketWouldBlock(int error) noexcept {
  return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
}

inline void configureProxySocket(int socket) {
  setCloseOnExec(socket);
  setNonblocking(socket);
  suppressSocketSignals(socket);
}

inline FileDescriptor openOriginSocket(int family) {
  FileDescriptor socket{::socket(family, SOCK_STREAM, IPPROTO_TCP)};
  if (!socket) {
    throw SystemError{"Create proxy origin socket"};
  }
  configureProxySocket(socket.get());

  struct Option {
    int level;
    int name;
    int value;
  };
  constexpr int enabled = 1;
  constexpr int idle_seconds = 60;
  constexpr int interval_seconds = 10;
  constexpr int probe_count = 6;
#if defined(__APPLE__)
  constexpr int idle_option = TCP_KEEPALIVE;
#else
  constexpr int idle_option = TCP_KEEPIDLE;
#endif
  constexpr Option options[] = {{SOL_SOCKET, SO_KEEPALIVE, enabled}, {IPPROTO_TCP, idle_option, idle_seconds}, {IPPROTO_TCP, TCP_KEEPINTVL, interval_seconds}, {IPPROTO_TCP, TCP_KEEPCNT, probe_count}};
  for (const auto &option : options) {
    if (::setsockopt(socket.get(), option.level, option.name, &option.value, sizeof(option.value)) != 0) {
      throw SystemError{"Configure proxy origin keepalive"};
    }
  }
  return socket;
}

}
