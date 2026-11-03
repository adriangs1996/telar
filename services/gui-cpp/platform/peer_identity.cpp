#include "peer_identity.hpp"
#include "telar_platform/peer_credentials.hpp"
#include <cstdint>
#include <unistd.h>

namespace telar::gui::platform {

std::uint32_t currentUserId() noexcept {
  return ::getuid();
}

bool isCurrentUser(std::intptr_t descriptor) noexcept {
  const auto peer = runtime::peerCredentials(static_cast<int>(descriptor));

  return peer && peer->user == ::geteuid();
}

}
