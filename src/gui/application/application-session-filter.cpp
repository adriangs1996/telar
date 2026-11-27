module telar.gui.application;

import std;

import telar.gui.foundation.terminal;
import telar.gui.features.terminal.filter;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::gui::application {

  namespace feature = features::terminal::filter;

  namespace {

    // Block `index`'s output by stable row: settled above the rows the live screen may still
    // change while it runs, and all of it once it ended.
    feature::Extent extentOf(const Pane<Memory>& pane, std::size_t index) noexcept {
      const auto [first, end] = Session::blockRows(pane, index);
      const auto& screen = pane.screen;
      const auto total = static_cast<std::uint64_t>(screen.scroll().total_rows);
      const auto live_top = total > screen.rows() ? total - screen.rows() : 0;
      const auto settled = pane.blocks[index].state == CommandBlockState::running ? std::clamp<std::uint64_t>(live_top, first, end) : end;
      const auto trimmed = pane.scrollback_trimmed;

      return feature::Extent{.first = trimmed + first, .end = trimmed + end, .settled = trimmed + settled, .screen = trimmed + screen.cellsOffset()};
    }

    feature::ScreenRows screenOf(const Pane<Memory>& pane) noexcept {
      const auto& screen = pane.screen;
      std::uint64_t revision = 0;

      // A row's revision grows whenever it changes, so their sum does whenever any does.
      for (std::size_t row = 0; row < screen.rows(); ++row) {
        revision += screen.rowRevision(row);
      }

      return feature::ScreenRows{.first = pane.scrollback_trimmed + screen.cellsOffset(), .columns = screen.columns(), .cells = screen.cells(), .flags = screen.rowFlags(), .revision = revision};
    }

  }

  bool Session::openFilter(BlockAt block) {
    const auto [pane_id, index] = block;
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || !readsRows()) {
      return false;
    }

    const auto key = blockKey(*pane, index);
    const auto top = jumpRow(*pane);

    // A folded output shows nothing to filter.
    if (folded(block)) {
      fold(block, false);
    }

    feature::open(block_filter, {.pane_id = pane_id, .block = key, .top = top});
    changed_pane_ = pane_id;
    block_changed_ = true;
    return true;
  }

  bool Session::queryFilter(const feature::Query& query) {
    const bool compiled = feature::query(block_filter, query);
    const auto pane_id = feature::status(block_filter).pane_id;

    followFilter(pane_id);

    // The block's separator at the view's top, the lines that match under it.
    auto* pane = findPaneMut(pane_id);
    if (const auto index = pane == nullptr ? ds::none : terminal::filter::indexOf(block_filter, *pane)) {
      refreshFolds(*pane);
      scrollToShownRow(*pane, pane->folds.display(separatorRow(*pane, *index)));
    }

    return compiled;
  }

  void Session::closeFilter() {
    const auto pane_id = feature::status(block_filter).pane_id;
    const auto top = feature::close(block_filter);
    auto* pane = findPaneMut(pane_id);
    if (!top || pane == nullptr) {
      return;
    }

    // Back to the row the view's top was on, the rows the filter hid shown again.
    const auto row = *top > pane->scrollback_trimmed ? *top - pane->scrollback_trimmed : 0;

    refreshFolds(*pane);
    scrollToShownRow(*pane, pane->folds.display(row));
    changed_pane_ = pane_id;
    block_changed_ = true;
  }

  void Session::followFilter(std::uint64_t pane_id) {
    if (!feature::open(block_filter) || feature::status(block_filter).pane_id != pane_id) {
      return;
    }

    auto* pane = findPaneMut(pane_id);
    const auto index = pane == nullptr ? ds::none : terminal::filter::indexOf(block_filter, *pane);
    // The block left the scrollback, or its rows were numbered anew: nothing is left to filter.
    if (!index) {
      static_cast<void>(feature::close(block_filter));
      if (pane != nullptr) {
        refreshFolds(*pane);
      }

      block_changed_ = true;
      return;
    }

    const auto revision = feature::revision(block_filter);
    const auto extent = extentOf(*pane, *index);

    feature::follow(block_filter, extent);
    static_cast<void>(feature::screen(block_filter, screenOf(*pane), extent));
    advanceFilter(revision, *pane, *index);
  }

  bool Session::receiveFilterRows(const PaneRows& reply) {
    auto* pane = findPaneMut(reply.pane_id);
    const auto index = pane == nullptr ? ds::none : terminal::filter::indexOf(block_filter, *pane);
    if (!index) {
      return feature::fail(block_filter, reply.request_id);
    }

    const auto revision = feature::revision(block_filter);
    const auto extent = extentOf(*pane, *index);
    if (!feature::receive(block_filter, reply, extent)) {
      return false;
    }

    // The rows after these, from the screen or asked for.
    static_cast<void>(feature::screen(block_filter, screenOf(*pane), extent));
    advanceFilter(revision, *pane, *index);
    return true;
  }

  void Session::advanceFilter(std::uint64_t revision, Pane<Memory>& pane, std::size_t index) {
    const auto extent = extentOf(pane, index);

    if (const auto wanted = readsRows() ? feature::wanted(block_filter, extent) : ds::none) {
      const auto request_id = link.nextRequest();

      link.send(ReadPaneRows{.request_id = request_id, .pane_id = pane.id, .from = wanted->from, .count = wanted->count});
      feature::asked(block_filter, request_id, *wanted);
    }

    if (feature::revision(block_filter) != revision) {
      refreshFolds(pane);
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  bool Session::copyFiltered(BlockAt block) {
    const auto* pane = findPane(block.pane_id);
    if (pane == nullptr || block.index >= pane->blocks.size() || !feature::filters(block_filter, block.pane_id, blockKey(*pane, block.index))) {
      return false;
    }

    feature::copy(block_filter, clipboard_);
    clipboard_written_ = true;
    return true;
  }

}

namespace telar::gui::application::terminal::filter {

  namespace feature = features::terminal::filter;

  ds::Option<std::size_t> indexOf(const feature::State& state, const Pane<Memory>& pane) noexcept {
    if (!feature::open(state)) {
      return ds::none;
    }

    const auto status = feature::status(state);
    if (status.pane_id != pane.id) {
      return ds::none;
    }

    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      if (Session::blockKey(pane, index) == status.block) {
        return index;
      }
    }

    return ds::none;
  }

  void hide(const feature::State& state, const Pane<Memory>& pane, ds::Vec<FoldMap<>::Span, Memory>& spans) {
    const auto index = indexOf(state, pane);
    if (!index) {
      return;
    }

    const auto trimmed = pane.scrollback_trimmed;

    feature::hidden(state, extentOf(pane, *index), [&](std::uint64_t first, std::uint64_t end) {
      spans.push({.first = static_cast<std::uint32_t>(first - trimmed), .count = static_cast<std::uint32_t>(end - first)});
    });
  }

}
