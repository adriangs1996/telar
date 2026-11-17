module telar.gui.foundation.system;

import std;
import telar.sys.posix;

import telar.platform.net;

namespace telar::gui::inline foundation::inline system {

  std::uint32_t currentUserId() noexcept {
    return ::getuid();
  }

  bool isCurrentUser(std::intptr_t descriptor) noexcept {
    const auto peer = runtime::peerCredentials(static_cast<int>(descriptor));

    return peer && peer->user == ::geteuid();
  }

}
