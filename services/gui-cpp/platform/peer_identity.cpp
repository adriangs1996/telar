#include "peer_identity.hpp"
#include <cstdint>
#include <sys/types.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/socket.h>
#endif

namespace telar::gui::platform {

std::uint32_t currentUserId() noexcept {
  return ::getuid();
}

bool isCurrentUser(std::intptr_t descriptor) noexcept {
#if defined(__APPLE__) || defined(__FreeBSD__)
  uid_t user = 0;
  gid_t group = 0;

  return ::getpeereid(static_cast<int>(descriptor), &user, &group) == 0 && user == ::geteuid();
#elifdef __linux__
  ucred credentials{};
  socklen_t size = sizeof(credentials);

  return ::getsockopt(static_cast<int>(descriptor), SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 && size == sizeof(credentials) && credentials.uid == ::geteuid();
#else
#error Unsupported peer identity platform
#endif
}

}
