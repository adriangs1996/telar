#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application.hpp"
#include "../core/memory.hpp"
#include "../input/scroll_motion.hpp"
#include "../input/wheel_accumulator.hpp"
#include "../platform/scroll_event.hpp"
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal_item.hpp"
#include "terminal_scene.hpp"
#include "window_animation_clock.hpp"
#include <QQuickWindow>
#include <QWheelEvent>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>

#include "input/scroll_motion.hpp"
#include "input/wheel_accumulator.hpp"
#include "terminal/screen.hpp"

import telar.gui.application.workspace_replica;
import telar.gui.terminal.copy_mode;

namespace telar::gui::qt {

namespace {

// A view released this long after it came to rest gives back the rows it kept beyond its screen.
constexpr std::chrono::milliseconds row_release_delay{1500};
// Moves of the runtime's view no farther than this many rows ease in, as a wheel notch does;
// farther ones glide.
constexpr double eased_rows = 3;

QString stateName(CommandBlockState state) {
  switch (state) {
  case CommandBlockState::running:
    return QStringLiteral("running");
  case CommandBlockState::succeeded:
    return QStringLiteral("succeeded");
  case CommandBlockState::failed:
    return QStringLiteral("failed");
  case CommandBlockState::session:
    return QStringLiteral("session");
  case CommandBlockState::interrupted:
    break;
  }
  return QStringLiteral("interrupted");
}

// A command still going: one running, or an ssh whose session is open.
bool going(CommandBlockState state) {
  return state == CommandBlockState::running || state == CommandBlockState::session;
}

}

bool TerminalItem::mapsRows() const noexcept {
  const auto *current = pane();
  return current != nullptr && application_ != nullptr && application_->session().readsRows() && current->attached && current->scrollback_generation != 0 && !current->screen.modes().alternate_screen && current->screen.rows() != 0 && current->screen.columns() != 0;
}

bool TerminalItem::smoothScroll() const noexcept {
  return mapsRows() && application_->configuration().scroll.smooth;
}

double TerminalItem::rowHeight() const noexcept {
  return font_.cell.height();
}

std::uint64_t TerminalItem::scrollNow() const {
  if (window() != nullptr) {
    return WindowAnimationClock::forWindow(*window()).now();
  }
  return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

double TerminalItem::scrollLimit() const {
  const auto *current = pane();
  if (current == nullptr) {
    return 0;
  }
  const auto &screen = current->screen;
  const auto shown = current->folds.shownRows(screen.scroll().total_rows);
  const auto rows = static_cast<std::uint64_t>(screen.rows());
  return static_cast<double>(shown > rows ? shown - rows : 0) * rowHeight();
}

// The runtime's view for a view whose top is shown row `top`: from that row, or from the bottom
// once the rows drawn reach the live screen, so its changing rows come in the screen's frames.
std::uint32_t TerminalItem::runtimeOffset(std::uint64_t top) const {
  const auto *current = pane();
  const auto &screen = current->screen;
  const auto total = static_cast<std::uint64_t>(screen.scroll().total_rows);
  const auto rows = static_cast<std::uint64_t>(screen.rows());
  const auto bottom = total > rows ? total - rows : 0;
  const auto &folds = current->folds;
  const auto row = folds.row(top);
  if (!folds.empty()) {
    const auto shown = folds.shownRows(total);
    const auto last = folds.row(std::min<std::uint64_t>(top + rows, shown == 0 ? 0 : shown - 1));
    if (last >= bottom) {
      return static_cast<std::uint32_t>(bottom);
    }
  }
  return static_cast<std::uint32_t>(std::min(row, bottom));
}

void TerminalItem::bindScrollClock() {
  QObject::disconnect(scroll_frame_connection_);
  if (window() == nullptr) {
    return;
  }
  // Each frame's sample before its polish pass, as the window's other animations take theirs.
  scroll_frame_connection_ = connect(window(), &QQuickWindow::afterAnimating, this, [this] {
    if (animating() && isVisible()) {
      scroll_frame_requested_ = true;
      polish();
    }
  });
}

void TerminalItem::startScrollFrames() {
  scroll_release_.stop();
  scroll_frame_requested_ = true;
  polish();
  if (window() != nullptr) {
    window()->update();
  }
}

void TerminalItem::advanceScroll() {
  scroll_frame_requested_ = false;
  if (!mapsRows()) {
    motion_.stop();
    fold_motion_.reset();
    return;
  }
  advanceFoldMotion();
  const auto moving = motion_.advance(scrollTime());
  applyScroll(driven_);
  if (moving || fold_motion_) {
    if (window() != nullptr) {
      window()->update();
    }
  } else {
    scroll_release_.start(row_release_delay);
  }
}

// Takes what changed in the pane: rows the scrollback dropped above the view, folds opened or
// closed, and a runtime view moved by someone else (a command selected, copy mode, typing,
// output followed), which the view glides to.
void TerminalItem::synchronizeScroll() {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }
  const auto cell = rowHeight();
  if (!mapsRows() || cell <= 0) {
    motion_.stop();
    expected_offset_.reset();
    view_rows_.clear();
    application_->session().findPane(pane_id_)->shown_top.reset();
    top_row_ = current->screen.scroll().offset;
    if (std::exchange(shift_, 0) != 0) {
      emit scrollChanged();
    }
    return;
  }

  motion_.tune({.wheel_ms = static_cast<double>(application_->configuration().scroll.wheel_ms)});
  // At the end, the view follows the output; a fold that moves the end does not drag it along.
  const auto revision = fold_revision_;
  bool following = !motion_.moving() && motion_.position() >= motion_.limit() - (cell / 2);
  followDroppedRows(following);
  anchorFolds();
  following = following && revision == fold_revision_;
  motion_.setLimit(scrollLimit());
  followRuntimeView(following);

  // Copy mode reads whole rows: the view settles on the row at its top.
  const auto &copy = application_->copyState();
  if (copy && copy->pane_id == pane_id_ && !motion_.moving() && shift_ > 0) {
    motion_.glide(static_cast<double>(top_row_) * cell, scrollTime(), static_cast<double>(current->screen.rows()) * cell);
    driven_ = false;
  }

  applyScroll(driven_);
  if (motion_.moving()) {
    startScrollFrames();
  }
}

ScrollTime TerminalItem::scrollTime() const {
  return {.nanoseconds = static_cast<std::int64_t>(scrollNow())};
}

// Rows the scrollback dropped above the view: it moves up as far to keep showing its rows.
void TerminalItem::followDroppedRows(bool following) {
  const auto dropped = application_->session().takeDroppedRows(pane_id_);
  if (dropped == 0) {
    return;
  }
  if (expected_offset_) {
    expected_offset_ = static_cast<std::uint32_t>(*expected_offset_ > dropped ? *expected_offset_ - dropped : 0);
  }
  if (!following) {
    motion_.place(std::max(0.0, motion_.position() - (static_cast<double>(dropped) * rowHeight())));
  }
}

// A fold opened or closed: the row at the top stays there, or, folded away, its command's
// separator takes the top.
void TerminalItem::anchorFolds() {
  const auto *current = pane();
  if (current->fold_revision == fold_revision_) {
    return;
  }
  fold_revision_ = current->fold_revision;
  // One fold opened or closed, its first row the same before and after, moves what is below
  // its separator; several at once, or one that only grew, simply show their rows.
  const auto spans = current->folds.spans();
  std::optional<FoldMap<>::Span> changed;
  bool closed = false;
  std::size_t changes = 0;
  const auto has = [](std::span<const FoldMap<>::Span> list, std::uint32_t first) {
    return std::ranges::any_of(list, [first](const FoldMap<>::Span &span) { return span.first == first; });
  };
  for (const auto &span : shown_folds_) {
    if (!has(spans, span.first)) {
      changed = span;
      ++changes;
    }
  }
  for (const auto &span : spans) {
    if (!has(shown_folds_, span.first)) {
      changed = span;
      closed = true;
      ++changes;
    }
  }
  shown_folds_.assign(spans.begin(), spans.end());
  // The row at the top as the view last drew it under the old folds; the rows laid out since
  // may already count the new ones.
  if (!top_anchor_) {
    return;
  }
  const auto cell = rowHeight();
  const auto &folds = current->folds;
  const auto anchor = *top_anchor_;
  const auto part = motion_.position() - (static_cast<double>(top_row_) * cell);
  auto target = (static_cast<double>(folds.display(anchor)) * cell) + part;
  if (folds.hides(anchor)) {
    const auto &blocks = current->blocks;
    const auto found = std::ranges::find_if(blocks.rbegin(), blocks.rend(), [anchor](const CommandBlock &block) { return block.row <= anchor; });
    if (found != blocks.rend()) {
      target = static_cast<double>(folds.display(static_cast<std::uint64_t>(found->row) + found->rows - 1)) * cell;
    }
  }
  motion_.setLimit(scrollLimit());
  motion_.place(target);
  driven_ = true;
  if (changes == 1 && changed) {
    startFoldMotion(*changed, closed);
  } else {
    fold_motion_.reset();
    placeFoldMotion();
  }
}

const FoldMap<> &TerminalItem::viewFolds() const noexcept {
  return fold_motion_ ? transit_folds_ : pane()->folds;
}

// The output under a separator in view folds or unfolds as a body that shrinks or grows: its
// rows go under, or come out from, the edge that moves, and the rows below follow the edge. Only
// the part in view moves, so a long output takes no longer than a short one.
void TerminalItem::startFoldMotion(FoldMap<>::Span span, bool closed) {
  const auto *current = pane();
  const auto cell = rowHeight();
  if (span.first == 0 || span.count == 0 || cell <= 0) {
    return;
  }
  const auto top = static_cast<std::uint64_t>(std::floor(motion_.position() / cell));
  const auto separator = current->folds.display(span.first - 1);
  const auto rows = static_cast<std::uint64_t>(current->screen.rows());
  if (separator < top || separator >= top + rows) {
    return;
  }
  const auto room = top + rows - separator;
  const auto moving_rows = std::min<std::uint64_t>(span.count, room);
  constexpr double shortest_ms = 150;
  constexpr double longest_ms = 280;
  constexpr double ms_per_row = 4;
  fold_motion_ = FoldMotion{
      .first = span.first,
      .count = span.count,
      .closing = closed,
      .height = static_cast<double>(moving_rows) * cell,
      .duration_ms = std::clamp(shortest_ms + (static_cast<double>(moving_rows) * ms_per_row), shortest_ms, longest_ms),
      .start = scrollTime(),
  };
  advanceFoldMotion();
  startScrollFrames();
}

void TerminalItem::advanceFoldMotion() {
  if (!fold_motion_) {
    return;
  }
  const auto *current = pane();
  const auto cell = rowHeight();
  const auto progress = std::clamp(scrollTime().millisecondsSince(fold_motion_->start) / fold_motion_->duration_ms, 0.0, 1.0);
  if (progress >= 1 || cell <= 0) {
    fold_motion_.reset();
    placeFoldMotion();
    layoutRows();
    refreshBlocks();
    markMatches();
    update();
    return;
  }

  // Eased both ways: the body starts and stops moving gently.
  const auto eased = progress < 0.5 ? 4 * progress * progress * progress : 1 - (std::pow((-2 * progress) + 2, 3) / 2);
  const auto shown = fold_motion_->height * (fold_motion_->closing ? 1 - eased : eased);
  constexpr double whole = 1e-6;
  const auto rows = std::min<std::size_t>(fold_motion_->count, static_cast<std::size_t>(std::ceil((shown / cell) - whole)));

  // The pane's folds, this one hiding only what is past the edge.
  std::vector<FoldMap<>::Span> spans;
  for (const auto &span : current->folds.spans()) {
    if (span.first != fold_motion_->first) {
      spans.push_back(span);
    }
  }
  const auto count = fold_motion_->closing ? [&] {
    const auto found = std::ranges::find(current->folds.spans(), fold_motion_->first, &FoldMap<>::Span::first);
    return found == current->folds.spans().end() ? fold_motion_->count : found->count;
  }()
                                           : fold_motion_->count;
  if (count > rows) {
    spans.push_back({.first = fold_motion_->first + static_cast<std::uint32_t>(rows), .count = count - static_cast<std::uint32_t>(rows)});
  }
  transit_folds_.assign(spans);
  fold_shown_ = rows;

  fold_height_ = shown;
  layoutRows();
  requestViewRows(true);
  refreshBlocks();
  markMatches();
  update();
}

// Where the moving fold's rows are drawn, from the view's top: the rows below on the edge, the
// output row it crosses fading under it.
void TerminalItem::placeFoldMotion() {
  int from = -1;
  qreal offset = 0;
  const auto cell = rowHeight();
  if (fold_motion_ && cell > 0) {
    const auto rows = static_cast<std::int64_t>(fold_shown_);
    const auto separator = static_cast<std::int64_t>(transit_folds_.display(fold_motion_->first - 1)) - static_cast<std::int64_t>(top_row_);
    from = static_cast<int>(separator + 1 + rows);
    offset = static_cast<qreal>(fold_height_ - (static_cast<double>(rows) * cell));
    fold_fade_row_ = rows == 0 ? -1 : from - 1;
    fold_fade_ = rows == 0 ? 1.0F : static_cast<float>(std::clamp((fold_height_ - (static_cast<double>(rows - 1) * cell)) / cell, 0.0, 1.0));
  } else {
    fold_fade_row_ = -1;
  }
  if (from != fold_from_ || offset != fold_offset_) {
    fold_from_ = from;
    fold_offset_ = offset;
    emit scrollChanged();
  }
}

// The client asked the runtime for a view this view did not: it catches up. A frame showing an
// older view while the runtime turns to a newer one is not a move.
void TerminalItem::followRuntimeView(bool following) {
  const auto *current = pane();
  const auto &screen = current->screen;
  const auto &scroll = screen.scroll();
  if (expected_offset_ && viewport_requests_ == current->viewport_requests) {
    if (following && !motion_.moving()) {
      // Output grew under a view that follows it.
      motion_.place(motion_.limit());
    }
    return;
  }
  const auto cell = rowHeight();
  const auto rows = static_cast<std::uint64_t>(screen.rows());
  const auto total = static_cast<std::uint64_t>(scroll.total_rows);
  const auto bottom = total > rows ? total - rows : 0;
  const auto viewport = static_cast<double>(rows) * cell;
  const auto target = static_cast<double>(current->folds.display(scroll.offset)) * cell;
  const auto now = scrollTime();
  const bool end = scroll.offset >= bottom;
  if (!expected_offset_ || (end && following)) {
    motion_.place(end ? motion_.limit() : target);
  } else if (end) {
    motion_.glideToEnd(now, viewport);
  } else if (std::abs(target - motion_.position()) <= eased_rows * cell) {
    motion_.wheel(target - motion_.destination(), now);
  } else {
    motion_.glide(target, now, viewport);
  }
  driven_ = false;
  expected_offset_ = scroll.offset;
  viewport_requests_ = current->viewport_requests;
}

void TerminalItem::applyScroll(bool driven) {
  const auto *current = pane();
  const auto cell = rowHeight();
  if (current == nullptr || cell <= 0 || !mapsRows()) {
    return;
  }

  const auto position = motion_.position();
  constexpr double row_tolerance = 1e-6;
  auto top = static_cast<std::uint64_t>(std::floor((position / cell) + row_tolerance));
  const auto scale = window() == nullptr ? 1.0 : window()->effectiveDevicePixelRatio();
  // Whole physical pixels keep the glyphs sharp while they move.
  auto shift = std::round((position - (static_cast<double>(top) * cell)) * scale) / scale;
  constexpr double half_pixel = 0.5;
  if (shift >= cell - (half_pixel / scale)) {
    ++top;
    shift = 0;
  }
  shift = std::max(0.0, shift);
  const bool crossed = top != top_row_;
  const bool shifted = shift != shift_;
  top_row_ = top;
  placeFoldMotion();
  // The session moves the view from where it is drawn, not from the runtime's view.
  application_->session().findPane(pane_id_)->shown_top = top;
  if (shift != shift_) {
    shift_ = shift;
    emit scrollChanged();
  }

  // The user's motion leads the runtime's view, at most once a frame; copy mode owns it while it reads.
  const auto &copy = application_->copyState();
  const bool copying = copy && copy->pane_id == pane_id_;
  // At rest, the runtime's view is where the view draws from, whoever moved it: a command
  // selected whose rows folds bring nearer the live end leaves the live screen drawn, which the
  // runtime's view then covers.
  if ((driven || !motion_.moving()) && !copying) {
    const auto desired = runtimeOffset(top);
    if (!expected_offset_ || *expected_offset_ != desired) {
      expected_offset_ = desired;
      application_->session().scrollToRow(pane_id_, desired);
      expected_offset_ = current->screen.scroll().offset;
      viewport_requests_ = current->viewport_requests;
    }
  }

  layoutRows();
  top_anchor_ = !view_rows_.empty() && view_rows_.front().exists ? std::optional{view_rows_.front().row} : std::nullopt;
  requestViewRows(motion_.moving());
  // A new top row moves the separators; within a row only the shift, the pinned separator and
  // the rail's view change.
  if (crossed) {
    update();
    refreshBlocks();
    markMatches();
  } else if (shifted) {
    update();
    refreshScrollViews(false);
  }
}

// The rows drawn from the top shown row down, a row more than the screen for the one partly
// shown at the bottom: from the screen where it holds them, else from the rows kept apart.
void TerminalItem::layoutRows() {
  const auto *current = pane();
  if (current == nullptr || !mapsRows()) {
    view_rows_.clear();
    return;
  }
  const auto &screen = current->screen;
  const auto rows = static_cast<std::size_t>(screen.rows());
  const auto total = static_cast<std::uint64_t>(screen.scroll().total_rows);
  const auto &folds = viewFolds();
  const auto shown = folds.shownRows(total);
  const auto first = static_cast<std::uint64_t>(screen.cellsOffset());
  view_rows_.resize(rows + 1);
  for (std::size_t index = 0; index < view_rows_.size(); ++index) {
    auto &view = view_rows_[index];
    const auto display = top_row_ + index;
    view.exists = display < shown;
    view.row = view.exists ? folds.row(display) : 0;
    view.exists = view.exists && view.row < total;
    view.screen_row = view.exists && view.row >= first && view.row < first + rows ? static_cast<std::int32_t>(view.row - first) : -1;
  }
}

// Asks the runtime for the rows drawn that the screen does not hold, and while the view moves
// for `overscan` views of rows around them.
void TerminalItem::requestViewRows(bool moving) {
  const auto *current = pane();
  if (current == nullptr || !mapsRows()) {
    return;
  }
  const auto &screen = current->screen;
  const auto rows = static_cast<std::uint64_t>(screen.rows());
  const auto &folds = viewFolds();
  const auto shown = folds.shownRows(screen.scroll().total_rows);
  if (shown == 0) {
    return;
  }
  const auto margin = moving ? static_cast<std::uint64_t>(std::ceil(application_->configuration().scroll.overscan * static_cast<float>(rows))) : 0;
  const auto first = top_row_ > margin ? top_row_ - margin : 0;
  const auto last = std::min(shown - 1, top_row_ + rows + margin);
  auto &session = application_->session();
  const auto trimmed = current->scrollback_trimmed;
  // Contiguous runs of rows, which folds break apart.
  auto run_first = folds.row(first);
  auto run_last = run_first;
  for (auto display = first + 1; display <= last; ++display) {
    const auto row = folds.row(display);
    if (row != run_last + 1) {
      session.requestRows(pane_id_, trimmed + run_first, trimmed + run_last);
      run_first = row;
    }
    run_last = row;
  }
  session.requestRows(pane_id_, trimmed + run_first, trimmed + run_last);
}

std::optional<std::size_t> TerminalItem::screenRowAt(double drawn) const noexcept {
  const auto *current = pane();
  if (current == nullptr || current->screen.rows() == 0 || !std::isfinite(drawn)) {
    return std::nullopt;
  }
  const auto index = static_cast<std::int64_t>(std::floor(drawn));
  if (view_rows_.empty()) {
    return static_cast<std::size_t>(std::clamp<std::int64_t>(index, 0, current->screen.rows() - 1));
  }
  if (index < 0 || std::cmp_greater_equal(index, view_rows_.size()) || view_rows_[static_cast<std::size_t>(index)].screen_row < 0) {
    return std::nullopt;
  }
  return static_cast<std::size_t>(view_rows_[static_cast<std::size_t>(index)].screen_row);
}

bool TerminalItem::scrollWheel(const QWheelEvent &event) {
  const auto *current = pane();
  if (current == nullptr || !smoothScroll()) {
    return false;
  }
  // A program that reads the wheel gets it; copy mode moves its own view.
  const auto &mouse = current->screen.mouse();
  if (mouse.sgr && (mouse.tracking == MouseTracking::normal || mouse.tracking == MouseTracking::button || mouse.tracking == MouseTracking::any)) {
    return false;
  }
  if (application_->copyState()) {
    return false;
  }

  const auto cell = rowHeight();
  if (cell <= 0) {
    return false;
  }
  const auto now = scrollTime();
  const auto precise = !event.pixelDelta().isNull() && event.source() == Qt::MouseEventSynthesizedBySystem;
  if (precise) {
    switch (event.phase()) {
    case Qt::ScrollBegin:
      // A finger on the trackpad stops a fling.
      motion_.stop();
      break;
    case Qt::ScrollEnd:
      // macOS continues the gesture with its own momentum; elsewhere the view flings on.
      if constexpr (platform::native_scroll_events) {
        motion_.settle();
      } else {
        motion_.release(now);
      }
      break;
    default:
      motion_.follow(-event.pixelDelta().y(), now);
      break;
    }
  } else {
    constexpr double wheel_unit = 120;
    const auto notches = -static_cast<double>(event.angleDelta().y()) / wheel_unit;
    motion_.wheel(notches * WheelAccumulator::rows_per_line * cell, now);
  }
  driven_ = true;
  applyScroll(true);
  if (motion_.moving()) {
    startScrollFrames();
  }
  return true;
}

void TerminalItem::scrollToEnd() {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr) {
    return;
  }
  if (application_->selectedBlock(pane_id_)) {
    application_->selectBlock(pane_id_, std::nullopt);
    return;
  }
  application_->scrollPaneToRow(pane_id_, std::numeric_limits<std::uint32_t>::max());
  refresh();
}

void TerminalItem::scrollToFraction(qreal fraction, bool glide) {
  const auto *current = pane();
  const auto cell = rowHeight();
  if (current == nullptr || !mapsRows() || cell <= 0 || !std::isfinite(fraction)) {
    return;
  }
  const auto rows = static_cast<double>(current->screen.rows());
  const auto shown = static_cast<double>(current->folds.shownRows(current->screen.scroll().total_rows));
  const auto target = ((std::clamp(fraction, 0.0, 1.0) * shown) - (rows / 2)) * cell;
  if (glide) {
    motion_.glide(target, scrollTime(), rows * cell);
  } else {
    motion_.place(target);
  }
  driven_ = true;
  applyScroll(true);
  if (motion_.moving()) {
    startScrollFrames();
  }
}

void TerminalItem::toggleFold(int index) {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr || index < 0 || std::cmp_greater_equal(index, current->blocks.size())) {
    return;
  }
  auto &session = application_->session();
  session.fold(pane_id_, static_cast<std::size_t>(index), !session.folded(pane_id_, static_cast<std::size_t>(index)));
  refresh();
}

// The pinned separator, the rail and the way back to the live end, from where the view is.
void TerminalItem::refreshScrollViews(bool segments_changed) {
  const auto *current = pane();
  QVariantMap sticky;
  QVariantList segments;
  qreal rail_top = 0;
  qreal rail_height = 1;
  Arrivals arrivals;
  if (current != nullptr && application_ != nullptr) {
    const auto &screen = current->screen;
    const auto total = static_cast<std::uint64_t>(screen.scroll().total_rows);
    const auto shown = std::max<std::uint64_t>(1, mapsRows() ? current->folds.shownRows(total) : total);
    const auto rows = static_cast<std::uint64_t>(screen.rows());
    const auto cell = rowHeight();
    const auto top = mapsRows() ? top_row_ : static_cast<std::uint64_t>(screen.scroll().offset);
    const bool telar = application_->configuration().prompt.mode == PromptMode::telar && current->shell.shell != IntegratedShell::none && !screen.modes().alternate_screen;
    const auto part = cell > 0 ? shift_ / cell : 0;
    rail_top = static_cast<qreal>((static_cast<double>(top) + part) / static_cast<double>(shown));
    rail_height = std::min<qreal>(1, static_cast<qreal>(rows) / static_cast<qreal>(shown));
    if (telar && segments_changed) {
      segments = railSegmentsFor(shown);
    }
    if (telar && mapsRows() && application_->configuration().scroll.sticky_headers) {
      sticky = pinnedBlock();
    }
    arrivals = arrivalsSince(top + rows >= shown, telar);
  }

  if (sticky != sticky_block_) {
    sticky_block_ = std::move(sticky);
    emit stickyChanged();
  }
  if (segments_changed && segments != rail_segments_) {
    rail_segments_ = std::move(segments);
    emit blocksChanged();
  }
  if (rail_top != rail_top_ || rail_height != rail_height_) {
    rail_top_ = rail_top;
    rail_height_ = rail_height;
    emit scrollChanged();
  }
  if (arrivals.rows != rows_arrived_ || arrivals.finished != finished_below_) {
    rows_arrived_ = arrivals.rows;
    finished_below_ = std::move(arrivals.finished);
    emit placeChanged();
  }
}

// A segment per command, its share of the `shown` rows.
QVariantList TerminalItem::railSegmentsFor(std::uint64_t shown) const {
  const auto *current = pane();
  const auto &folds = current->folds;
  const auto &blocks = current->blocks;
  const auto selected = application_->selectedBlock(pane_id_);
  const auto &session = application_->session();
  QVariantList segments;
  for (std::size_t index = 0; index < blocks.size(); ++index) {
    const auto first = folds.display(blocks[index].row);
    const auto end = index + 1 < blocks.size() ? folds.display(blocks[index + 1].row) : shown;
    segments.push_back(QVariantMap{
        {QStringLiteral("index"), static_cast<int>(index)},
        {QStringLiteral("state"), stateName(blocks[index].state)},
        {QStringLiteral("top"), static_cast<qreal>(first) / static_cast<qreal>(shown)},
        {QStringLiteral("height"), static_cast<qreal>(end > first ? end - first : 0) / static_cast<qreal>(shown)},
        {QStringLiteral("selected"), selected == index},
        {QStringLiteral("folded"), session.folded(pane_id_, index)},
    });
  }
  return segments;
}

// The command whose output the top row shows while its separator is above the view.
QVariantMap TerminalItem::pinnedBlock() const {
  const auto *current = pane();
  if (view_rows_.empty() || !view_rows_.front().exists) {
    return {};
  }
  const auto row = view_rows_.front().row;
  const auto &blocks = current->blocks;
  // The last command whose separator is above the top row, or on it and partly scrolled past.
  std::optional<std::size_t> found;
  for (std::size_t index = blocks.size(); index-- > 0;) {
    const auto separator = static_cast<std::uint64_t>(blocks[index].row) + blocks[index].rows - 1;
    if (separator < row || (separator == row && shift_ > 0)) {
      found = index;
      break;
    }
  }
  if (!found) {
    return {};
  }
  const auto index = *found;
  const auto &block = blocks[index];
  const auto [output_first, output_end] = GuiSession::blockRows(*current, index);
  if (index + 1 == blocks.size() && row >= output_end) {
    return {};
  }
  // The next command's separator pushes this one up as it reaches the top.
  const auto cell = rowHeight();
  qreal push = 0;
  if (index + 1 < blocks.size()) {
    const auto &next = blocks[index + 1];
    const auto separator = viewFolds().display(static_cast<std::uint64_t>(next.row) + next.rows - 1);
    const auto below = ((static_cast<double>(separator) - static_cast<double>(top_row_)) * cell) - shift_;
    push = static_cast<qreal>(std::min(0.0, below - cell));
  }
  const auto selected = application_->selectedBlock(pane_id_);
  return QVariantMap{
      {QStringLiteral("index"), static_cast<int>(index)},
      {QStringLiteral("command"), QString::fromUtf8(block.command.data(), static_cast<qsizetype>(block.command.size()))},
      {QStringLiteral("lines"), static_cast<int>(block.lines)},
      {QStringLiteral("state"), stateName(block.state)},
      {QStringLiteral("status"), block.status},
      {QStringLiteral("duration"), static_cast<qulonglong>(block.duration_ms)},
      {QStringLiteral("selected"), selected == index},
      {QStringLiteral("folded"), application_->session().folded(pane_id_, index)},
      {QStringLiteral("foldable"), output_end > output_first},
      {QStringLiteral("rows"), static_cast<int>(output_end - output_first)},
      {QStringLiteral("push"), push},
      {QStringLiteral("remote"), block.nest == CommandBlockNest::inside},
      {QStringLiteral("host"), index >= liveSession(*current) ? QString::fromUtf8(current->shell.host.data(), static_cast<qsizetype>(current->shell.host.size())) : QString{}},
  };
}

// What arrived since the view left the live end: rows of output, and how the commands that
// finished ended. Nothing at the end, which forgets where the view left.
TerminalItem::Arrivals TerminalItem::arrivalsSince(bool at_end, bool telar) {
  const auto *current = pane();
  if (at_end) {
    away_rows_.reset();
    away_running_.clear();
    return {};
  }
  const auto &blocks = current->blocks;
  const auto stable_total = current->scrollback_trimmed + current->screen.scroll().total_rows;
  if (!away_rows_) {
    away_rows_ = stable_total;
    away_running_.clear();
    for (std::size_t index = 0; index < blocks.size(); ++index) {
      if (going(blocks[index].state)) {
        away_running_.push_back(GuiSession::blockKey(*current, index));
      }
    }
  }
  Arrivals arrivals;
  arrivals.rows = static_cast<int>(std::min<std::uint64_t>(stable_total > *away_rows_ ? stable_total - *away_rows_ : 0, std::numeric_limits<int>::max()));
  for (std::size_t index = 0; telar && index < blocks.size(); ++index) {
    const auto key = GuiSession::blockKey(*current, index);
    const bool was_running = std::ranges::find(away_running_, key) != away_running_.end();
    if (!going(blocks[index].state) && (was_running || key >= *away_rows_)) {
      arrivals.finished.push_back(stateName(blocks[index].state));
    }
  }
  return arrivals;
}

// The scrollback search's matches: on the rows drawn, the one the cursor is on marked, and
// as shares of the rows shown for the rail.
void TerminalItem::markMatches() {
  match_marks_.clear();
  QVariantList rail;
  const auto *current = pane();
  const auto &copy = application_ == nullptr ? std::optional<CopyState>{} : application_->copyState();
  if (current != nullptr && copy && copy->pane_id == pane_id_) {
    const auto matches = application_->session().copyMode().matches();
    const auto &screen = current->screen;
    const auto total = static_cast<std::uint64_t>(screen.scroll().total_rows);
    const bool mapped = !view_rows_.empty();
    const auto shown = std::max<std::uint64_t>(1, mapped ? current->folds.shownRows(total) : total);
    const auto first = static_cast<std::uint64_t>(screen.cellsOffset());
    for (std::size_t index = 0; index < matches.size(); ++index) {
      const auto &match = matches[index];
      rail.push_back(static_cast<qreal>(mapped ? current->folds.display(match.y) : match.y) / static_cast<qreal>(shown));
      if (const auto row = drawnRowOf(match.y, first)) {
        match_marks_.push_back({.row = *row, .column = match.x, .length = match.len, .current = index == copy->match_index});
      }
    }
  }
  if (rail != rail_matches_) {
    rail_matches_ = std::move(rail);
    emit matchesChanged();
  }
}

// Where row `row`, counted from the top of the scrollback, is drawn: among the view's rows, or
// from the screen's first row `first` while the view draws the screen's own.
std::optional<std::size_t> TerminalItem::drawnRowOf(std::uint64_t row, std::uint64_t first) const {
  if (!view_rows_.empty()) {
    const auto found = std::ranges::find_if(view_rows_, [row](const ViewRow &view) { return view.exists && view.row == row; });
    return found == view_rows_.end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - view_rows_.begin())};
  }
  const auto *current = pane();
  if (current == nullptr || row < first || row >= first + current->screen.rows()) {
    return std::nullopt;
  }
  return static_cast<std::size_t>(row - first);
}

}
