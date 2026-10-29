#pragma once

#include <cstdint>

namespace telar::gui::platform {

[[nodiscard]] std::uint32_t currentUserId() noexcept;

bool isCurrentUser(std::intptr_t descriptor) noexcept;

}
