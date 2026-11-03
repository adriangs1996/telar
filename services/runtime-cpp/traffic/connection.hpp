#include "../platform/socket_signals.hpp"
#include "telar_platform/peer_credentials.hpp"
#pragma once

#include "protocol.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

namespace telar::runtime::traffic {

inline FileDescriptor connect(std::string_view path) {
  sockaddr_un address{};
  if (path.empty() || path.front() != '/' || path.size() >= sizeof(address.sun_path) || path.contains('\0')) {
    throw std::invalid_argument{"Invalid traffic endpoint"};
  }

  std::ranges::copy(path, address.sun_path);
  address.sun_family = AF_UNIX;
  struct stat before{};
  if (::lstat(address.sun_path, &before) != 0 || !S_ISSOCK(before.st_mode) || (before.st_mode & 0077) != 0) {
    throw SystemError{"Traffic endpoint must be a private socket", EACCES};
  }

  FileDescriptor socket{::socket(AF_UNIX, SOCK_STREAM, 0)};
  if (!socket) {
    throw SystemError{"Create traffic connection"};
  }
  setCloseOnExec(socket.get());
  suppressSocketSignals(socket.get());
  if (::connect(socket.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
    throw SystemError{"Connect traffic endpoint"};
  }

  struct stat after{};
  const auto credentials = peerCredentials(socket.get());
  if (!credentials || credentials->user != before.st_uid || (::geteuid() != 0 && credentials->user != ::geteuid()) || ::lstat(address.sun_path, &after) != 0 || before.st_dev != after.st_dev || before.st_ino != after.st_ino) {
    throw SystemError{"Traffic endpoint identity changed", EACCES};
  }
  return socket;
}

inline void sendAll(int socket, std::span<const Byte> bytes) {
  while (!bytes.empty()) {
    const auto count = ::send(socket, bytes.data(), bytes.size(), 0);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      throw SystemError{"Send traffic frame"};
    }
    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
}

}
