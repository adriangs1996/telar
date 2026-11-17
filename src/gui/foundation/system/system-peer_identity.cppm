export module telar.gui.foundation.system:peer_identity;

import std;

export {
  namespace telar::gui::inline foundation::inline system {

    [[nodiscard]] std::uint32_t currentUserId() noexcept;

    bool isCurrentUser(std::intptr_t descriptor) noexcept;

  }
}
