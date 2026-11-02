#pragma once

#include "core/view_version.hpp"
#include "link_hit.hpp"
#include <optional>
#include <utility>

namespace telar::gui {

class LinkGesture {
public:
  void begin(const LinkHit &hit, ViewVersion version) {
    pressed_ = hit;
    version_ = version;
  }

  void validate(const std::optional<LinkHit> &current, ViewVersion version) {
    if (pressed_ && (version_ != version || current != pressed_)) {
      cancel();
    }
  }

  [[nodiscard]] std::optional<LinkHit> finish(const std::optional<LinkHit> &current, ViewVersion version) {
    validate(current, version);

    return std::exchange(pressed_, std::nullopt);
  }

  void cancel() noexcept {
    pressed_.reset();
  }

  [[nodiscard]] bool active() const noexcept {
    return pressed_.has_value();
  }

private:
  std::optional<LinkHit> pressed_;
  ViewVersion version_;
};

}
