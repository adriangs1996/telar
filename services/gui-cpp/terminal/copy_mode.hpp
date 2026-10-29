#pragma once

#include "copy_grid.hpp"
#include "copy_navigation.hpp"
#include "copy_state.hpp"
#include "input/click_tracker.hpp"
#include "input/copy_pointer.hpp"
#include "input/terminal_key.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>

namespace telar::gui {

struct CopyPlan {
  std::uint64_t revision = 0;
  std::optional<CopyState> next = std::nullopt;
  CopyEffect effect{};
  std::optional<CopySelection> selection = std::nullopt;
  std::optional<SetPaneViewport> viewport = std::nullopt;
  std::optional<std::span<const PaneMatch>> replacement_matches = std::nullopt;
};

class CopyMode {
public:
  static constexpr std::size_t maximum_matches = 256;

  [[nodiscard]] const std::optional<CopyState> &state() const noexcept {
    return state_;
  }

  [[nodiscard]] bool active() const noexcept {
    return state_ && !state_->pointer;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::optional<CopyPointerOwner> pointerOwner() const noexcept {
    if (gesture_) {
      return CopyPointerOwner{.pane_id = *gesture_, .dragging = true};
    }

    if (state_ && state_->pointer) {
      return CopyPointerOwner{.pane_id = state_->pane_id};
    }

    return {};
  }

  bool beginPointer(CopyPress press, const CopyGrid &grid) noexcept {
    if (active() || press.position.x >= grid.columns || press.position.y >= grid.rows) {
      return false;
    }

    if (click_pane_ != press.pane_id) {
      clicks_ = {};
    }

    click_pane_ = press.pane_id;
    const auto granularity = clicks_.press(press.position, press.now_ns);
    state_ = CopyState{.pane_id = press.pane_id, .cursor = {.x = press.position.x, .y = grid.scroll.offset + press.position.y}, .entry_offset = grid.scroll.offset, .viewport_offset = grid.scroll.offset};
    state_->beginPointer(granularity, grid);
    gesture_ = press.pane_id;
    match_count_ = 0;
    ++revision_;

    return true;
  }

  [[nodiscard]] std::optional<CopyPlan> pointer(CopyPoint local, const CopyGrid &grid, bool released) const noexcept {
    if (!state_ || !state_->pointer || gesture_ != state_->pane_id) {
      return {};
    }

    auto next = *state_;
    next.movePointer({.x = local.x, .y = grid.scroll.offset + std::min<std::uint32_t>(local.y, grid.rows == 0 ? 0 : grid.rows - 1)}, grid);
    if (released && !next.anchor) {
      return leave(grid);
    }

    auto result = plan(next, grid);
    if (released) {
      result.selection = next.selectionRequest();
    }

    return next == *state_ && !released ? std::nullopt : std::optional{result};
  }

  bool clearPointer() noexcept {
    if (!state_ || !state_->pointer) {
      return false;
    }

    reset();

    return true;
  }

  void finishPointer() noexcept {
    gesture_.reset();
  }

  [[nodiscard]] std::span<const PaneMatch> matches() const noexcept {
    return std::span{matches_}.first(match_count_);
  }

  bool enter(std::uint64_t pane_id, const CopyGrid &grid, const Cursor &cursor) noexcept {
    if (active() || grid.columns == 0 || grid.rows == 0) {
      return false;
    }

    state_ = CopyState{
        .pane_id = pane_id,
        .cursor = cursor.visible ? CopyPoint{.x = cursor.x, .y = grid.scroll.offset + cursor.y} : CopyPoint{.x = 0, .y = grid.scroll.offset + grid.rows - 1},
        .entry_offset = grid.scroll.offset,
        .viewport_offset = grid.scroll.offset,
    };
    match_count_ = 0;
    ++revision_;

    return true;
  }

  [[nodiscard]] std::optional<CopyPlan> key(const TerminalKey &key, const CopyGrid &grid) const noexcept {
    if (!state_ || state_->pointer) {
      return {};
    }

    const auto previous = *state_;
    auto next = previous;
    const auto effect = CopyNavigation::apply(next, key, grid, matches());
    if (!effect.handled) {
      return {};
    }

    if (effect.exit) {
      auto plan = leave(grid);
      plan.effect = effect;
      if (effect.copy) {
        plan.selection = next.selectionRequest();
      }

      return plan;
    }

    if (next == previous && !effect.search && !effect.open_link) {
      return {};
    }

    return plan(next, grid, effect);
  }

  [[nodiscard]] std::optional<CopyPlan> vertical(std::int32_t rows, const CopyGrid &grid) const noexcept {
    if (!state_) {
      return {};
    }

    auto next = *state_;
    next.vertical(rows, grid);

    return next == *state_ ? std::nullopt : std::optional{plan(next, grid)};
  }

  [[nodiscard]] CopyPlan leave(const CopyGrid &grid) const noexcept {
    CopyPlan result{.revision = revision_, .effect = {.exit = true}};
    if (state_ && !state_->pointer) {
      result.viewport = viewport(std::min(state_->entry_offset, grid.maximumOffset()), grid);
    }

    return result;
  }

  [[nodiscard]] bool current(const CopyPlan &plan) const noexcept {
    return state_.has_value() && plan.revision == revision_;
  }

  bool commit(const CopyPlan &plan) noexcept {
    if (!current(plan) || (plan.replacement_matches && plan.replacement_matches->size() > matches_.size())) {
      return false;
    }

    state_ = plan.next;
    if (plan.replacement_matches) {
      std::ranges::copy(*plan.replacement_matches, matches_.begin());
      match_count_ = plan.replacement_matches->size();
    }

    ++revision_;

    return true;
  }

  [[nodiscard]] std::optional<CopyPlan> search(std::span<const PaneMatch> results, const CopyGrid &grid) const {
    if (!state_ || state_->pointer) {
      return {};
    }

    if (results.size() > matches_.size()) {
      throw std::length_error{"Copy search exceeds match capacity"};
    }

    for (const auto &match : results) {
      static_cast<void>(BoundedInteger<u16, 1>::validate(match.len));
    }

    auto next = *state_;
    next.applyMatches(results, grid);
    auto result = plan(next, grid);
    result.replacement_matches = results;

    return result;
  }

  void onFrame(std::uint32_t previous_offset, const CopyGrid &grid) noexcept {
    if (!state_) {
      return;
    }

    if (state_->pointer && (state_->pointer->columns != grid.columns || state_->pointer->rows != grid.rows)) {
      reset();

      return;
    }

    auto next = *state_;
    next.onFrame(previous_offset, grid.scroll);
    if (next != *state_) {
      state_ = next;
      ++revision_;
    }
  }

  void reset() noexcept {
    state_.reset();
    match_count_ = 0;
    ++revision_;
  }

private:
  [[nodiscard]] std::optional<SetPaneViewport> viewport(std::uint32_t offset, const CopyGrid &grid) const noexcept {
    if (!state_ || offset == grid.scroll.offset) {
      return {};
    }

    return SetPaneViewport{.pane_id = state_->pane_id, .offset = offset};
  }

  [[nodiscard]] CopyPlan plan(CopyState next, const CopyGrid &grid, CopyEffect effect = {}) const noexcept {
    return {.revision = revision_, .next = next, .effect = effect, .viewport = viewport(next.viewport_offset, grid)};
  }

  std::optional<CopyState> state_;
  std::array<PaneMatch, maximum_matches> matches_{};
  std::size_t match_count_ = 0;
  std::uint64_t revision_ = 0;
  ClickTracker clicks_;
  std::uint64_t click_pane_ = 0;
  std::optional<std::uint64_t> gesture_;
};

}
