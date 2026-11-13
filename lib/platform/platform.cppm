module;
#include <cerrno>
#include <csignal>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

export module telar.platform;

import std;

export import telar.base.memory;
export import telar.base.text;
export import telar.platform.daemon;
export import telar.platform.error;
export import telar.platform.events;
export import telar.platform.fs;
export import telar.platform.graphics;
export import telar.platform.paths;
export import telar.platform.process;
export import telar.platform.sha256;
export import telar.platform.thread;

// Every platform family, for the importers that still take all of them. The socket helpers
// below stay here until the net family takes them.

// Interface: telar_platform/peer_credentials.cppm
export {
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
}

// Interface: telar_platform/socket_would_block.cppm
export {
  namespace telar::runtime {

    // Whether a nonblocking socket call that failed with `error` may simply be tried again later.
    inline bool socketWouldBlock(int error) noexcept {
      return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
    }

  }
}

// Interface: telar_platform/socket_signals.cppm
export {
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
}
