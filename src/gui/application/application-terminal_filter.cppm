// The filter of a command's output as ui drives it: open it on a block, type its query, read
// where it stands and the matches it marks, and close it.
export module telar.gui.application:terminal_filter;

import std;

import :fold_map;
import :session;
import :workspace_replica;
import telar.gui.features.terminal.filter;
import telar.gui.foundation.terminal;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::gui::application::terminal::filter {

  using features::terminal::filter::Mark;
  using features::terminal::filter::maximum_context;
  using features::terminal::filter::Query;
  using features::terminal::filter::Status;

  // Opens the filter on `block`, its output shown whole until a query comes; false without the
  // block, or with a runtime that sends no rows apart from the screen, which a filtered view
  // draws from.
  bool open(Session& session, BlockAt block);

  // Filters the open filter's block by `query`, its separator at the view's top; false when the
  // query does not compile, which the status says.
  bool query(Session& session, const Query& query);

  // Closes the filter, the view back where it was when it opened.
  void close(Session& session);

  [[nodiscard]] bool active(const Session& session) noexcept;

  [[nodiscard]] Status status(const Session& session) noexcept;

  // The index of the block the filter is on among pane `pane_id`'s, none when it is on none of
  // them.
  [[nodiscard]] ds::Option<std::size_t> block(const Session& session, std::uint64_t pane_id) noexcept;

  // The matches on a row of `cells` of pane `pane_id`, into `marks`; how many.
  [[nodiscard]] std::size_t highlight(Session& session, std::uint64_t pane_id, std::span<const CellValue> cells, std::span<Mark> marks);

}

// What the session's routing and the block use cases hand the filter; ui never calls these.
namespace telar::gui::application::terminal::filter {

  // The block of `pane` the filter is on, found by its stable key.
  [[nodiscard]] ds::Option<std::size_t> indexOf(const features::terminal::filter::State& state, const Pane<Memory>& pane) noexcept;

  // A request failed; false when it is not the filter's.
  bool fail(features::terminal::filter::State& state, std::uint64_t request_id) noexcept;

  // The rows the filter hides of `pane`, as folds of its rows.
  void hide(const features::terminal::filter::State& state, const Pane<Memory>& pane, ds::Vec<FoldMap<>::Span, Memory>& spans);

}
