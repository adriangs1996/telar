module telar.gui.features.workbench;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::workbench {

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
      entries_.atMut(*index) = {.key = key, .started_ns = now_ns};
    }

    seen_.atMut(*index) = true;
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
        entries_.atMut(kept++) = entries_[index];
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

  ds::Option<std::size_t> AttentionFades::find(PaneAttentionKey key) const noexcept {
    const auto entries = std::span{entries_}.first(count_);

    for (std::size_t index = 0; index < entries.size(); ++index) {
      if (entries[index].key == key) {
        return index;
      }
    }

    return ds::none;
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
    for (auto& motion : entries_.viewMut().first(count_)) {
      motion.seen = false;
    }
  }

  std::size_t TabCardMotions::place(std::span<const TabCardInput> panes, std::span<TabCardPlacement> placed, TabMotionFrame& frame) noexcept {
    ds::Array<TabCardMotion*, capacity> ordered{};
    std::size_t known = 0;

    for (const auto& pane : panes) {
      auto* motion = find(pane.pane);
      const auto fresh = motion == nullptr;
      if (fresh && count_ < entries_.size()) {
        motion = &entries_.atMut(count_++);
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

      ordered.atMut(known++) = motion;
    }

    const auto input = [&](const TabCardMotion* motion) {
      return *std::ranges::find(panes, motion->pane, &TabCardInput::pane);
    };

    std::stable_sort(ordered.dataMut(), ordered.dataMut() + known, [&](const TabCardMotion* left, const TabCardMotion* right) {
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
          entries_.atMut(kept) = entries_[index];
        }

        ++kept;
      }
    }

    count_ = kept;
  }

  TabCardMotion* TabCardMotions::find(std::uint64_t pane) noexcept {
    for (auto& motion : entries_.viewMut().first(count_)) {
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
    ds::Array<Motion, PaneLayout::maximum_panes> next;

    for (std::size_t index = 0; index < placements.size(); ++index) {
      const auto& slot = placements[index];
      const auto* old = find(slot.id);
      auto from = slot.bounds;

      if (animate) {
        from = old != nullptr ? old->value(now_ns) : entrance(slot.bounds);
      }

      next.atMut(index) = {.id = slot.id, .from = from, .to = slot.bounds, .started = now_ns, .duration = from == slot.bounds ? 0 : duration};
    }

    std::copy_n(next.begin(), placements.size(), entries_.dataMut());
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

  void TabMotions::begin(ds::Option<WorkspaceLocation> workspace) noexcept {
    if (workspace_.hasValue() != workspace.hasValue() || (workspace_ && (workspace_->kind != workspace->kind || workspace_->id != workspace->id))) {
      count_ = 0;
      workspace_ = workspace;
    }

    for (auto& motion : entries_.viewMut().first(count_)) {
      motion.seen = false;
    }
  }

  [[nodiscard, gnu::always_inline]] Rect TabMotions::place(TabMotionSlot slot, TabMotionFrame& frame) noexcept {
    if (slot.immediate && count_ == 1 && entries_[0].id == slot.id) {
      entries_.atMut(0).seen = true;
      entries_.atMut(0).from = slot.bounds;
      entries_.atMut(0).to = slot.bounds;
      entries_.atMut(0).duration = 0;
      return slot.bounds;
    }

    for (auto& motion : entries_.viewMut().first(count_)) {
      if (motion.id != slot.id) {
        continue;
      }

      motion.seen = true;
      return motion.place(slot.bounds, frame, slot.immediate);
    }

    if (count_ < entries_.size()) {
      entries_.atMut(count_++) = {.id = slot.id, .from = slot.bounds, .to = slot.bounds, .started = frame.now_ns};
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
          entries_.atMut(kept) = motion;
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
