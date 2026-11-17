module telar.gui.presentation.frame_pacer;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;

namespace telar::gui {

  void AttentionFades::begin() noexcept {
    seen_.fill(false);
  }

  AttentionFrame AttentionFades::sample(PaneAttentionKey key, std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    auto index = find(key);
    if (!index) {
      if (count_ == entries_.size()) {
        return {};
      }

      index = count_++;
      entries_[*index] = {.key = key, .started_ns = now_ns};
    }

    seen_[*index] = true;
    const auto started = entries_[*index].started_ns;
    if (now_ns < started) {
      return {.alpha = 0, .deadline_ns = started};
    }

    const auto elapsed = now_ns - started;
    if (elapsed >= duration_ns) {
      return {};
    }

    const auto alpha = static_cast<float>(elapsed) / static_cast<float>(duration_ns);

    return {.alpha = alpha, .deadline_ns = std::min(after(now_ns, interval_ns), after(started, duration_ns))};
  }

  void AttentionFades::end() noexcept {
    std::size_t kept = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (seen_[index]) {
        entries_[kept++] = entries_[index];
      }
    }

    count_ = kept;
  }

  std::size_t AttentionFades::size() const noexcept {
    return count_;
  }

  std::uint64_t AttentionFades::after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  std::optional<std::size_t> AttentionFades::find(PaneAttentionKey key) const noexcept {
    const auto entries = std::span{entries_}.first(count_);

    for (std::size_t index = 0; index < entries.size(); ++index) {
      if (entries[index].key == key) {
        return index;
      }
    }

    return std::nullopt;
  }

  std::uint64_t FramePacer::resolveInterval(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    const auto cap_interval_ns = maximum_fps ? nanoseconds_per_second / std::max<std::uint16_t>(*maximum_fps, 1) : 0;

    return std::clamp(std::max(display_interval_ns, cap_interval_ns), minimum_interval_ns, maximum_interval_ns);
  }

  std::uint64_t FramePacer::configure(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    interval_ns_ = resolveInterval(display_interval_ns, maximum_fps);

    return interval_ns_;
  }

  std::uint64_t FramePacer::interval() const noexcept {
    return interval_ns_;
  }

  void FramePacer::noteInput(Pane pane, std::uint64_t now_ns) noexcept {
    if (!pane.attached || pane.pane_id == 0) {
      return;
    }

    std::optional<std::size_t> vacant;
    std::size_t oldest = 0;
    auto oldest_started_ns = std::numeric_limits<std::uint64_t>::max();

    for (std::size_t index = 0; index < inputs_.size(); ++index) {
      const auto& previous = inputs_[index];
      if (!previous) {
        if (!vacant) {
          vacant = index;
        }

        continue;
      }

      if (previous->pane.pane_id == pane.pane_id) {
        if (!previous->rejects(pane, now_ns)) {
          inputs_[index] = InputGrace{.pane = pane, .started_ns = now_ns};
        }

        return;
      }

      if (previous->started_ns < oldest_started_ns) {
        oldest = index;
        oldest_started_ns = previous->started_ns;
      }
    }

    inputs_[vacant.value_or(oldest)] = InputGrace{.pane = pane, .started_ns = now_ns};
  }

  bool FramePacer::canAdvanceInput(Pane pane, std::uint64_t now_ns) const noexcept {
    constexpr std::uint64_t idle_intervals = 2;
    if (last_preparation_ns_ && (now_ns < *last_preparation_ns_ || now_ns - *last_preparation_ns_ < interval_ns_ * idle_intervals)) {
      return false;
    }

    return std::ranges::any_of(inputs_, [&](const auto& grace) {
      return grace && grace->active(now_ns) && grace->includes(pane);
    });
  }

  std::optional<std::uint64_t> FramePacer::waitUntil(std::span<const Pane> panes, std::uint64_t now_ns) const noexcept {
    if (ordinaryAvailable(now_ns)) {
      return std::nullopt;
    }

    for (const auto& grace : inputs_) {
      if (grace && grace->active(now_ns) && std::ranges::any_of(panes, [&](Pane pane) {
            return grace->includes(pane);
          })) {
        return std::nullopt;
      }
    }

    return after(anchor_ns_.value_or(now_ns), interval_ns_);
  }

  void FramePacer::record(std::span<const Pane> panes, std::uint64_t now_ns) noexcept {
    const auto due_ns = anchor_ns_ ? std::optional{after(*anchor_ns_, interval_ns_)} : std::nullopt;
    const bool scheduled = due_ns && *due_ns <= now_ns && now_ns - *due_ns < interval_ns_;
    const bool ordinary_available = ordinaryAvailable(now_ns);

    for (auto& grace : inputs_) {
      if (!grace || now_ns < grace->started_ns || (!ordinary_available && !grace->active(now_ns))) {
        continue;
      }

      const auto matched = std::ranges::find_if(panes, [&](Pane pane) {
        return grace->includes(pane);
      });
      if (matched == panes.end()) {
        continue;
      }

      if (!ordinary_available && !scheduled && grace->frames_left != 0) {
        --grace->frames_left;
      }

      grace->pane = *matched;
    }

    anchor_ns_ = scheduled ? *due_ns : now_ns;
    last_preparation_ns_ = now_ns;
  }

  bool FramePacer::InputGrace::includes(Pane candidate) const noexcept {
    return candidate.attached && candidate.pane_id == pane.pane_id && candidate.attachment_generation == pane.attachment_generation && candidate.frame_id >= pane.frame_id && candidate.graphics_revision >= pane.graphics_revision && (candidate.frame_id > pane.frame_id || candidate.graphics_revision > pane.graphics_revision);
  }

  bool FramePacer::InputGrace::rejects(Pane candidate, std::uint64_t now_ns) const noexcept {
    return pane.attachment_generation > candidate.attachment_generation || now_ns < started_ns || (pane.attachment_generation == candidate.attachment_generation && (pane.frame_id > candidate.frame_id || pane.graphics_revision > candidate.graphics_revision));
  }

  bool FramePacer::InputGrace::active(std::uint64_t now_ns) const noexcept {
    return now_ns >= started_ns && now_ns - started_ns < input_grace_ns && frames_left != 0;
  }

  std::uint64_t FramePacer::after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  bool FramePacer::ordinaryAvailable(std::uint64_t now_ns) const noexcept {
    return !anchor_ns_ || (now_ns >= *anchor_ns_ && now_ns - *anchor_ns_ >= interval_ns_);
  }

  void TabMotionFrame::begin(std::uint64_t timestamp) noexcept {
    now_ns = std::max(now_ns, timestamp);
    deadline_ns.reset();
  }

  void TabMotionFrame::request(std::uint64_t started, std::uint64_t duration) noexcept {
    std::uint64_t next = 0;

    if (now_ns < started) {
      next = started;
    } else if (duration != 0 && now_ns - started < duration) {
      next = std::min(add(now_ns, interval_ns), add(started, duration));
    } else {
      return;
    }

    if (!deadline_ns || next < *deadline_ns) {
      deadline_ns = next;
    }
  }

  std::uint64_t TabMotionFrame::add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

  TabCardPose TabCardMotion::mix(TabCardPose start, TabCardPose end, float progress) noexcept {
    const auto remaining = 1 - std::clamp(progress, 0.0F, 1.0F);
    const auto eased = 1 - (remaining * remaining * remaining);

    return {.x = start.x + ((end.x - start.x) * eased), .y = start.y + ((end.y - start.y) * eased), .rotation = start.rotation + ((end.rotation - start.rotation) * eased), .scale = start.scale + ((end.scale - start.scale) * eased)};
  }

  std::uint64_t TabCardMotion::duration() const noexcept {
    return hop ? duration_ns : settle_ns;
  }

  bool TabCardMotion::lifted(std::uint64_t now_ns) const noexcept {
    return hop && now_ns >= started && now_ns - started < lift_ns;
  }

  TabCardPose TabCardMotion::value(std::uint64_t now_ns) const noexcept {
    if (now_ns < started) {
      return from;
    }

    const auto elapsed = now_ns - started;

    if (hop) {
      return elapsed < lift_ns ? mix(from, lift, static_cast<float>(elapsed) / static_cast<float>(lift_ns)) : mix(lift, to, static_cast<float>(elapsed - lift_ns) / static_cast<float>(settle_ns));
    }

    return mix(from, to, static_cast<float>(elapsed) / static_cast<float>(settle_ns));
  }

  void TabCardMotions::begin() noexcept {
    for (auto& motion : std::span{entries_}.first(count_)) {
      motion.seen = false;
    }
  }

  std::size_t TabCardMotions::place(std::span<const TabCardInput> panes, std::span<TabCardPlacement> placed, TabMotionFrame& frame) noexcept {
    std::array<TabCardMotion*, capacity> ordered{};
    std::size_t known = 0;

    for (const auto& pane : panes) {
      auto* motion = find(pane.pane);
      const auto fresh = motion == nullptr;
      if (fresh && count_ < entries_.size()) {
        motion = &entries_[count_++];
        *motion = {.pane = pane.pane};
      }

      if (motion == nullptr) {
        continue;
      }

      motion->seen = true;
      // A newly seen tab settles immediately instead of playing its whole history.
      if (pane.focused && (fresh || motion->rank != 0)) {
        motion->used = ++clock_;
      }

      ordered[known++] = motion;
    }

    const auto input = [&](const TabCardMotion* motion) {
      return *std::ranges::find(panes, motion->pane, &TabCardInput::pane);
    };

    std::stable_sort(ordered.begin(), ordered.begin() + known, [&](const TabCardMotion* left, const TabCardMotion* right) {
      const auto a = input(left);
      const auto b = input(right);
      if (a.focused != b.focused) {
        return a.focused;
      }

      if (a.attention != b.attention) {
        return a.attention;
      }

      return left->used != right->used ? left->used > right->used : left->pane < right->pane;
    });

    std::size_t written = 0;

    for (std::size_t rank = 0; rank < known; ++rank) {
      auto& motion = *ordered[rank];
      const auto target = TabCardMotion::rest[std::min(rank, TabCardMotion::rest.size() - 1)];
      if (motion.to != target) {
        const auto settled = motion.to == TabCardPose{};

        motion.from = settled ? target : motion.value(frame.now_ns);
        motion.to = target;
        motion.hop = !settled && rank == 0 && motion.rank != 0;
        motion.started = settled ? 0 : frame.now_ns;
      }

      motion.rank = rank;
      if (motion.started != 0) {
        frame.request(motion.started, motion.duration());
      }

      if (rank < placed.size()) {
        placed[written++] = {.pane = motion.pane, .rank = rank, .pose = motion.started == 0 ? motion.to : motion.value(frame.now_ns), .lifted = motion.lifted(frame.now_ns)};
      }
    }

    return written;
  }

  void TabCardMotions::finish() noexcept {
    std::size_t kept = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (entries_[index].seen) {
        if (kept != index) {
          entries_[kept] = entries_[index];
        }

        ++kept;
      }
    }

    count_ = kept;
  }

  TabCardMotion* TabCardMotions::find(std::uint64_t pane) noexcept {
    for (auto& motion : std::span{entries_}.first(count_)) {
      if (motion.pane == pane) {
        return &motion;
      }
    }

    return nullptr;
  }

  void PaneMotions::update(std::span<const PaneMotionSlot> placements, std::uint64_t now_ns, bool immediate) noexcept {
    if (placements.size() > entries_.size()) {
      count_ = 0;
      return;
    }

    bool shared = false;
    bool unchanged = placements.size() == count_;

    for (const auto& slot : placements) {
      const auto* old = find(slot.id);

      shared |= old != nullptr;
      unchanged &= old != nullptr && old->to == slot.bounds;
    }

    if (unchanged && !immediate) {
      return;
    }

    const bool animate = !immediate && shared && placements.size() != count_;
    const auto duration = placements.size() > count_ ? opening_ns : closing_ns;
    std::array<Motion, PaneLayout::maximum_panes> next;

    for (std::size_t index = 0; index < placements.size(); ++index) {
      const auto& slot = placements[index];
      const auto* old = find(slot.id);
      auto from = slot.bounds;

      if (animate) {
        from = old != nullptr ? old->value(now_ns) : entrance(slot.bounds);
      }

      next[index] = {.id = slot.id, .from = from, .to = slot.bounds, .started = now_ns, .duration = from == slot.bounds ? 0 : duration};
    }

    std::copy_n(next.begin(), placements.size(), entries_.begin());
    count_ = placements.size();
  }

  Rect PaneMotions::place(std::size_t index, TabMotionFrame& frame) const noexcept {
    const auto& entry = entries_[index];

    frame.request(entry.started, entry.duration);
    return entry.value(frame.now_ns);
  }

  Rect PaneMotions::Motion::value(std::uint64_t now_ns) const noexcept {
    if (duration == 0 || (now_ns >= started && now_ns - started >= duration)) {
      return to;
    }

    const float phase = now_ns <= started ? 0 : static_cast<float>(now_ns - started) / static_cast<float>(duration);
    const float remaining = 1 - phase;
    const float eased = 1 - remaining * remaining * remaining;

    return {.x = from.x + (to.x - from.x) * eased, .y = from.y + (to.y - from.y) * eased, .width = from.width + (to.width - from.width) * eased, .height = from.height + (to.height - from.height) * eased};
  }

  auto PaneMotions::find(std::uint64_t id) const noexcept -> const Motion* {
    const auto entries = std::span{entries_}.first(count_);
    const auto found = std::ranges::find(entries, id, &Motion::id);

    return found == entries.end() ? nullptr : &*found;
  }

  Rect PaneMotions::entrance(Rect target) const noexcept {
    // The added leaf occupies part of its previous parent. Reveal it from
    // the far edge while the surviving leaf moves the shared divider.
    const Motion* parent = nullptr;
    float best_overlap = 0;

    for (const auto& entry : std::span{entries_}.first(count_)) {
      const auto& bounds = entry.to;
      const auto overlap = bounds.intersect(target);
      if (overlap.width * overlap.height > best_overlap) {
        best_overlap = overlap.width * overlap.height;
        parent = &entry;
      }
    }

    if (parent == nullptr) {
      return target;
    }

    const auto& bounds = parent->to;
    if (target.width / bounds.width < target.height / bounds.height) {
      target.x = target.right();
      target.width = 0;
    } else {
      target.y = target.bottom();
      target.height = 0;
    }

    return target;
  }

  auto TabStripGeometry::Metrics::scaled(float ratio) noexcept -> Metrics {
    return {
        .leading = TabStripGeometry::leading * ratio,
        .trailing = TabStripGeometry::trailing * ratio,
        .spacing = TabStripGeometry::spacing * ratio,
        .gap = TabStripGeometry::gap * ratio,
        .inactive_maximum = TabStripGeometry::inactive_maximum * ratio,
        .selected_maximum = TabStripGeometry::selected_maximum * ratio,
        .caption_minimum = TabStripGeometry::caption_minimum * ratio,
        .counter = TabStripGeometry::counter_width * ratio,
    };
  }

  float TabStripGeometry::Measure::statusSpace(const Metrics& metrics) const noexcept {
    return status > 0 ? metrics.spacing + status : 0;
  }

  float TabStripGeometry::Measure::whole(const Metrics& metrics) const noexcept {
    return metrics.leading + chip + metrics.spacing + caption + statusSpace(metrics) + metrics.trailing;
  }

  float TabStripGeometry::Measure::truncated(const Metrics& metrics) const noexcept {
    return std::min(whole(metrics), metrics.leading + chip + metrics.spacing + metrics.caption_minimum + statusSpace(metrics) + metrics.trailing);
  }

  float TabStripGeometry::Measure::compact(const Metrics& metrics) const noexcept {
    return (2 * metrics.leading) + chip + statusSpace(metrics);
  }

  std::size_t TabStripGeometry::Plan::hidden() const noexcept {
    return count - (end - first);
  }

  bool TabStripGeometry::Plan::shows(std::size_t index) const noexcept {
    return index >= first && index < end;
  }

  std::optional<std::size_t> TabStripGeometry::Plan::nearestHidden() const noexcept {
    if (hidden() == 0) {
      return std::nullopt;
    }

    const auto left = first > 0 ? focus - (first - 1) : std::numeric_limits<std::size_t>::max();
    const auto right = end < count ? end - focus : std::numeric_limits<std::size_t>::max();

    return left <= right ? first - 1 : end;
  }

  float TabStripGeometry::Plan::footprint(const Metrics& metrics) const noexcept {
    if (first == end) {
      return 0;
    }

    float used = 0;

    for (auto index = first; index < end; ++index) {
      used += widths[index];
    }

    const auto gaps = metrics.gap * static_cast<float>(end - first - 1);

    used += gaps;
    if (hidden() != 0) {
      used += metrics.gap + metrics.counter;
    }

    return used;
  }

  auto TabStripGeometry::arrange(std::span<const Measure> sizes, std::size_t focus, const Room& room) noexcept -> Plan {
    if (sizes.empty() || sizes.size() > maximum_tabs || focus >= sizes.size() || !std::isfinite(room.width) || room.width < 0) {
      return {};
    }

    const auto& metrics = room.metrics;
    Plan result{.first = 0, .end = sizes.size(), .focus = focus, .count = sizes.size()};
    const auto gaps = metrics.gap * static_cast<float>(sizes.size() - 1);
    // Equal tabs keep the row still while the selection slides across it.
    const auto equal = std::floor((room.width - gaps) / static_cast<float>(sizes.size()));
    if (std::ranges::all_of(sizes, [&](const Measure& size) {
          return size.whole(metrics) <= equal;
        })) {
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        result.widths[index] = equal;
        result.fits[index] = Fit::full;
      }

      return result;
    }

    naturalWidths(result, sizes, metrics);
    if (result.footprint(metrics) <= room.width) {
      return result;
    }

    float natural = 0;
    float shortest = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index == focus) {
        continue;
      }

      natural += std::min(sizes[index].whole(metrics), metrics.inactive_maximum);
      shortest += std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
    }

    const auto whole = sizes[focus].whole(metrics);
    const auto share = sizes.size() == 1 ? room.width : room.width * selected_share;
    auto width = std::max(sizes[focus].compact(metrics), std::min({whole, metrics.selected_maximum, share}));
    const auto minimum = std::min(sizes[focus].truncated(metrics), metrics.selected_maximum);
    const auto caption_room = room.width - gaps - shortest;
    if (caption_room >= minimum) {
      // Preserve every caption before giving extra room to the focused tab.
      width = std::clamp(width, minimum, caption_room);
    }

    result.widths[focus] = std::min(width, room.width);
    result.fits[focus] = width >= whole ? Fit::full : Fit::truncated;
    const auto budget = room.width - width - gaps;
    if (natural <= budget) {
      return result;
    }

    const auto captioned = captionedTabs(sizes, focus, metrics, budget, shortest <= budget);

    distribute(result, sizes, captioned, metrics, budget);
    if (shortest > budget) {
      while (result.footprint(metrics) > room.width && result.end - result.first > 1) {
        if (result.end - 1 - focus >= focus - result.first) {
          --result.end;
        } else {
          ++result.first;
        }
      }
    }

    return result;
  }

  void TabStripGeometry::naturalWidths(Plan& plan, std::span<const Measure> sizes, const Metrics& metrics) noexcept {
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      const auto maximum = index == plan.focus ? metrics.selected_maximum : metrics.inactive_maximum;

      plan.widths[index] = std::min(sizes[index].whole(metrics), maximum);
      plan.fits[index] = sizes[index].whole(metrics) <= maximum ? Fit::full : Fit::truncated;
    }
  }

  auto TabStripGeometry::captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics& metrics, float budget, bool all_fit) noexcept -> Captioned {
    Captioned captioned{};

    if (all_fit) {
      captioned.fill(true);
      captioned[focus] = false;

      return captioned;
    }

    float used = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != focus) {
        used += sizes[index].compact(metrics);
      }
    }

    for (std::size_t distance = 1; distance < sizes.size(); ++distance) {
      const std::array<std::optional<std::size_t>, 2> candidates{focus >= distance ? std::optional{focus - distance} : std::nullopt, focus + distance < sizes.size() ? std::optional{focus + distance} : std::nullopt};

      for (const auto candidate : candidates) {
        if (!candidate) {
          continue;
        }

        const auto index = *candidate;
        const auto extra = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum) - sizes[index].compact(metrics);
        if (used + extra <= budget) {
          captioned[index] = true;
          used += extra;
        }
      }
    }

    return captioned;
  }

  float TabStripGeometry::largestCap(std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept {
    float low = 0;
    auto high = metrics.inactive_maximum;

    for (std::size_t iteration = 0; iteration < cap_iterations; ++iteration) {
      const auto cap = (low + high) / 2;
      float used = 0;

      for (std::size_t index = 0; index < sizes.size(); ++index) {
        if (captioned[index]) {
          used += std::max(std::min(sizes[index].truncated(metrics), metrics.inactive_maximum), std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap}));
        }
      }

      if (used <= budget) {
        low = cap;
      } else {
        high = cap;
      }
    }

    return low;
  }

  void TabStripGeometry::distribute(Plan& plan, std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept {
    float fixed = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != plan.focus && !captioned[index]) {
        plan.widths[index] = sizes[index].compact(metrics);
        plan.fits[index] = Fit::compact;
        fixed += sizes[index].compact(metrics);
      }
    }

    const auto cap = largestCap(sizes, captioned, metrics, budget - fixed);

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (captioned[index]) {
        const auto minimum = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
        const auto width = std::floor(std::max(minimum, std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap})));

        plan.widths[index] = width;
        plan.fits[index] = width >= sizes[index].whole(metrics) ? Fit::full : Fit::truncated;
      }
    }
  }

  Rect TabMotion::value(std::uint64_t now_ns) const noexcept {
    float progress = 1;

    if (now_ns < started) {
      progress = 0;
    } else if (duration != 0 && now_ns - started < duration) {
      progress = static_cast<float>(now_ns - started) / static_cast<float>(duration);
    }

    const float remaining = 1 - progress;
    const float eased = 1 - (remaining * remaining * remaining);

    return {.x = from.x + ((to.x - from.x) * eased), .y = from.y + ((to.y - from.y) * eased), .width = from.width + ((to.width - from.width) * eased), .height = from.height + ((to.height - from.height) * eased)};
  }

  Rect TabMotion::place(Rect bounds, TabMotionFrame& frame, bool immediate) noexcept {
    if (immediate) {
      from = bounds;
      to = bounds;
      duration = 0;
      return bounds;
    }

    if (to != bounds) {
      from = value(frame.now_ns);
      to = bounds;
      started = frame.now_ns;
      duration = duration_ns;
    }

    frame.request(started, duration);
    return value(frame.now_ns);
  }

  void TabMotions::begin(std::optional<WorkspaceLocation> workspace) noexcept {
    if (workspace_.has_value() != workspace.has_value() || (workspace_ && (workspace_->kind != workspace->kind || workspace_->id != workspace->id))) {
      count_ = 0;
      workspace_ = workspace;
    }

    for (auto& motion : std::span{entries_}.first(count_)) {
      motion.seen = false;
    }
  }

  [[nodiscard, gnu::always_inline]] Rect TabMotions::place(TabMotionSlot slot, TabMotionFrame& frame) noexcept {
    if (slot.immediate && count_ == 1 && entries_[0].id == slot.id) {
      entries_[0].seen = true;
      entries_[0].from = slot.bounds;
      entries_[0].to = slot.bounds;
      entries_[0].duration = 0;
      return slot.bounds;
    }

    for (auto& motion : std::span{entries_}.first(count_)) {
      if (motion.id != slot.id) {
        continue;
      }

      motion.seen = true;
      return motion.place(slot.bounds, frame, slot.immediate);
    }

    if (count_ < entries_.size()) {
      entries_[count_++] = {.id = slot.id, .from = slot.bounds, .to = slot.bounds, .started = frame.now_ns};
    }

    return slot.bounds;
  }

  void TabMotions::finish() noexcept {
    if (count_ == 1 && entries_[0].seen) {
      return;
    }

    std::size_t kept = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto& motion = entries_[index];
      if (motion.seen) {
        if (kept != index) {
          entries_[kept] = motion;
        }

        ++kept;
      }
    }

    count_ = kept;
  }

  std::size_t TabMotions::size() const noexcept {
    return count_;
  }

}
