#pragma once

#include "link_target.hpp"
#include <optional>
#include <utility>

namespace telar::gui {

class LinkOpening {
public:
  [[nodiscard]] bool request(const LinkTarget &target) {
    if (active_) {
      pending_ = target;

      return false;
    }

    active_ = true;

    return true;
  }

  [[nodiscard]] std::optional<LinkTarget> complete() {
    auto next = std::move(pending_);
    pending_.reset();
    active_ = next.has_value();

    return next;
  }

  void schedulingFailed() noexcept {
    active_ = false;
  }

  [[nodiscard]] bool active() const noexcept {
    return active_;
  }

private:
  bool active_ = false;
  std::optional<LinkTarget> pending_;
};

}
