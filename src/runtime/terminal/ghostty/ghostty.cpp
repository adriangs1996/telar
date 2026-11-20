module telar.runtime.terminal.ghostty;
import telar.base.ds;

namespace telar::runtime {

  TerminalError::TerminalError(GhosttyResult result, std::source_location location) noexcept
      : result_(result),
        location_(location) {}

  const char* TerminalError::what() const noexcept {
    return "libghostty-vt operation failed";
  }

  void checkGhostty(GhosttyResult result, std::source_location location) {
    if (result != GHOSTTY_SUCCESS) {
      throw TerminalError{result, location};
    }
  }

  TrackedRow TrackedRow::active(GhosttyTerminal terminal, std::uint32_t row) noexcept {
    TrackedRow tracked;
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {.x = 0, .y = row}}};
    if (ghostty_terminal_grid_ref_track(terminal, point, &tracked.ref_) != GHOSTTY_SUCCESS) {
      tracked.ref_ = nullptr;
    }

    return tracked;
  }

  TrackedRow::TrackedRow(TrackedRow&& other) noexcept
      : ref_(std::exchange(other.ref_, nullptr)) {}

  TrackedRow& TrackedRow::operator=(TrackedRow&& other) noexcept {
    if (this != &other) {
      release();
      ref_ = std::exchange(other.ref_, nullptr);
    }

    return *this;
  }

  TrackedRow::~TrackedRow() {
    release();
  }

  ds::Option<std::uint32_t> TrackedRow::row(GhosttyTerminal terminal) const noexcept {
    auto reference = ghosttySized<GhosttyGridRef>();
    if (ref_ == nullptr || ghostty_tracked_grid_ref_snapshot(ref_, &reference) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    GhosttyPointCoordinate coordinate{};
    if (ghostty_terminal_point_from_grid_ref(terminal, &reference, GHOSTTY_POINT_TAG_SCREEN, &coordinate) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return coordinate.y;
  }

  void TrackedRow::release() noexcept {
    if (ref_ != nullptr) {
      ghostty_tracked_grid_ref_free(ref_);
      ref_ = nullptr;
    }
  }

}
