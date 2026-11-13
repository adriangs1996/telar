module;

#include <cstdint>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

module telar.gui.platform.private_file_stamp;

import std;

import telar.platform;


namespace telar::gui::platform {

std::uint32_t currentUserId() noexcept {
  return ::getuid();
}

bool isCurrentUser(std::intptr_t descriptor) noexcept {
  const auto peer = runtime::peerCredentials(static_cast<int>(descriptor));

  return peer && peer->user == ::geteuid();
}

}
