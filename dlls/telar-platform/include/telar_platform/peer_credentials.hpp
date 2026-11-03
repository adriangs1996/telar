#pragma once

#include <optional>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace telar::runtime {

struct PeerCredentials {
  uid_t user;
  gid_t group;
};

inline std::optional<PeerCredentials> peerCredentials(int socket) noexcept {
#if defined(__APPLE__)
  PeerCredentials credentials{};
  if (::getpeereid(socket, &credentials.user, &credentials.group) != 0) {
    return std::nullopt;
  }
  return credentials;
#else
  ucred credentials{};
  socklen_t length = sizeof(credentials);
  if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials)) {
    return std::nullopt;
  }
  return PeerCredentials{credentials.uid, credentials.gid};
#endif
}

}
