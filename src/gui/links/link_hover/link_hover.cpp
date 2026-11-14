module telar.gui.links.link_hover;

namespace telar::gui {

  bool LinkHit::operator==(const LinkHit& other) const noexcept {
    return pane_id == other.pane_id && generation == other.generation && sameTab(location, other.location) && content == other.content && scroll_offset == other.scroll_offset && area == other.area && match == other.match;
  }

  void LinkGesture::begin(const LinkHit& hit, ViewVersion version) {
    pressed_ = hit;
    version_ = version;
  }

  void LinkGesture::validate(const std::optional<LinkHit>& current, ViewVersion version) {
    if (pressed_ && (version_ != version || current != pressed_)) {
      cancel();
    }
  }

  std::optional<LinkHit> LinkGesture::finish(const std::optional<LinkHit>& current, ViewVersion version) {
    validate(current, version);

    return std::exchange(pressed_, std::nullopt);
  }

  void LinkGesture::cancel() noexcept {
    pressed_.reset();
  }

  bool LinkGesture::active() const noexcept {
    return pressed_.has_value();
  }

  bool LinkHover::assign(std::optional<LinkHit> hit, const TerminalSurface& surface, bool frame_presented) {
    const auto changed = hit != current_;

    current_ = std::move(hit);
    if (current_ && frame_presented && surfaceVisible(surface)) {
      shown_ = current_;
    }

    return changed;
  }

  void LinkHover::clear() noexcept {
    current_.reset();
    shown_.reset();
  }

  bool LinkHover::openable(const TerminalSurface& surface) const noexcept {
    return current_ && current_ == shown_ && surfaceVisible(surface);
  }

  bool LinkHover::surfaceVisible(const TerminalSurface& surface) const noexcept {
    return shown_surface_ && *shown_surface_ == surface;
  }

  bool LinkHover::covers(Point point) const noexcept {
    return shown_cover_ && shown_cover_->contains(point);
  }

  bool LinkHover::needsPresentation(const TerminalSurface& surface, const std::optional<Rect>& cover) const noexcept {
    return !surfaceVisible(surface) || shown_ != current_ || shown_cover_ != cover;
  }

  LinkPresentation LinkHover::prepare(const TerminalSurface& surface, std::optional<Rect> cover) const {
    return {.surface = surface, .link = current_, .cover = cover};
  }

  void LinkHover::present(const LinkPresentation& frame, bool delivered) {
    if (delivered) {
      shown_ = frame.link;
      shown_surface_ = frame.surface;
      shown_cover_ = frame.cover;
    }
  }

  const std::optional<LinkHit>& LinkHover::current() const noexcept {
    return current_;
  }

  bool LinkOpening::request(const LinkTarget& target) {
    if (active_) {
      pending_ = target;

      return false;
    }

    active_ = true;

    return true;
  }

  std::optional<LinkTarget> LinkOpening::complete() {
    auto next = std::move(pending_);

    pending_.reset();
    active_ = next.has_value();

    return next;
  }

  void LinkOpening::schedulingFailed() noexcept {
    active_ = false;
  }

  bool LinkOpening::active() const noexcept {
    return active_;
  }

  LinkRegions::LinkRegions(const LinkMatch& match, LinkGrid grid, std::span<const MetadataRun> runs)
      : LinkRegions(match, grid, runs, {.columns = grid.columns, .rows = grid.rows}) {}

  LinkRegions::LinkRegions(const LinkMatch& match, LinkGrid grid, std::span<const MetadataRun> runs, Viewport viewport)
      : match_(match),
        grid_(grid),
        runs_(runs),
        viewport_{.columns = std::min(grid.columns, viewport.columns), .rows = std::min(grid.rows, viewport.rows)},
        row_(std::max(grid.scroll.offset, match.start.y)) {}

  std::optional<LinkRegion> LinkRegions::next() noexcept {
    if (grid_.columns == 0) {
      return {};
    }

    if (const auto index = match_.metadata_index) {
      return nextMetadataRun(*index);
    }

    while (row_ <= match_.end.y && row_ - grid_.scroll.offset < viewport_.rows) {
      const auto row = row_++;
      const auto relative = static_cast<std::uint32_t>(row - grid_.scroll.offset);
      auto right = row == match_.end.y ? match_.end.x : grid_.columns;

      if (relative < grid_.row_flags.size() && (grid_.row_flags[relative] & static_cast<Byte>(RowFlag::wide_padding)) != 0) {
        right = std::min<std::uint16_t>(right, grid_.columns - 1);
      }

      if (const auto area = clipped(relative, row == match_.start.y ? match_.start.x : 0, right)) {
        return area;
      }
    }

    return {};
  }

  std::optional<LinkRegion> LinkRegions::nextMetadataRun(std::uint16_t link_index) noexcept {
    while (run_index_ < runs_.size()) {
      const auto& run = runs_[run_index_++];
      if (run.link_index != link_index) {
        continue;
      }

      const auto column = run.start % grid_.columns;
      if (const auto area = clipped(run.start / grid_.columns, column, column + run.len)) {
        return area;
      }
    }

    return {};
  }

  std::optional<LinkRegion> LinkRegions::clipped(std::uint32_t row, std::uint32_t left, std::uint32_t right) const noexcept {
    right = std::min<std::uint32_t>(right, viewport_.columns);
    if (row >= viewport_.rows || left >= right) {
      return {};
    }

    return LinkRegion{.x = static_cast<std::uint16_t>(left), .y = static_cast<std::uint16_t>(row), .width = static_cast<std::uint16_t>(right - left)};
  }

}
