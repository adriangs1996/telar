#pragma once

#include "platform/window.hpp"
#include <cstddef>
#include <cstdint>

namespace telar::gui::platform {

struct NativeBlurFunctions {
  using Connection = void *(*)();
  using SetRadius = std::int32_t (*)(void *, std::size_t, int);

  Connection connection = nullptr;
  SetRadius set_radius = nullptr;
};

struct NativeBlurTarget {
  std::int64_t number = 0;
  std::uint64_t style = 0;

  bool operator==(const NativeBlurTarget &) const noexcept = default;
};

class BlurRadius {
public:
  explicit BlurRadius(NativeBlurFunctions functions) noexcept
      : functions_(functions) {}

  [[nodiscard]] bool apply(NativeBlurTarget target, WindowAppearance appearance) noexcept {
    const auto radius = appearance.background_opacity >= 1 ? std::uint8_t{0} : appearance.background_blur;
    if (applied_ && target == target_ && radius == radius_) {
      return numeric_;
    }

    target_ = target;
    radius_ = radius;
    applied_ = true;
    numeric_ = target.number > 0 && functions_.connection != nullptr && functions_.set_radius != nullptr && functions_.set_radius(functions_.connection(), static_cast<std::size_t>(target.number), radius) == 0;
    return numeric_;
  }

private:
  NativeBlurFunctions functions_;
  NativeBlurTarget target_;
  std::uint8_t radius_ = 0;
  bool applied_ = false;
  bool numeric_ = false;
};

}
