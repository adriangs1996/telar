#pragma once

#include "core/terminal_surface.hpp"

#include "core/geometry.hpp"
#include "link_hit.hpp"
#include <optional>
#include <utility>

namespace telar::gui {

struct LinkPresentation {
  TerminalSurface surface;
  std::optional<LinkHit> link;
  std::optional<Rect> cover;
};

class LinkHover {
public:
  [[nodiscard]] bool assign(std::optional<LinkHit> hit, const TerminalSurface &surface, bool frame_presented) {
    const auto changed = hit != current_;
    current_ = std::move(hit);
    if (current_ && frame_presented && surfaceVisible(surface)) {
      shown_ = current_;
    }

    return changed;
  }

  void clear() noexcept {
    current_.reset();
    shown_.reset();
  }

  [[nodiscard]] bool openable(const TerminalSurface &surface) const noexcept {
    return current_ && current_ == shown_ && surfaceVisible(surface);
  }

  [[nodiscard]] bool surfaceVisible(const TerminalSurface &surface) const noexcept {
    return shown_surface_ && *shown_surface_ == surface;
  }

  [[nodiscard]] bool covers(Point point) const noexcept {
    return shown_cover_ && shown_cover_->contains(point);
  }

  [[nodiscard]] bool needsPresentation(const TerminalSurface &surface, const std::optional<Rect> &cover) const noexcept {
    return !surfaceVisible(surface) || shown_ != current_ || shown_cover_ != cover;
  }

  [[nodiscard]] LinkPresentation prepare(const TerminalSurface &surface, std::optional<Rect> cover) const {
    return {.surface = surface, .link = current_, .cover = cover};
  }

  void present(const LinkPresentation &frame, bool delivered = true) {
    if (delivered) {
      shown_ = frame.link;
      shown_surface_ = frame.surface;
      shown_cover_ = frame.cover;
    }
  }

  [[nodiscard]] const std::optional<LinkHit> &current() const noexcept {
    return current_;
  }

private:
  std::optional<LinkHit> current_;
  std::optional<LinkHit> shown_;
  std::optional<TerminalSurface> shown_surface_;
  std::optional<Rect> shown_cover_;
};

}
