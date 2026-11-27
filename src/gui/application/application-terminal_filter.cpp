module telar.gui.application;

import std;

import :access;
import telar.gui.foundation.terminal;
import telar.gui.features.terminal.filter;
import telar.base.ds;

namespace telar::gui::application::terminal::filter {

  namespace feature = features::terminal::filter;

  bool open(Session& session, BlockAt block) {
    return Access::openFilter(session, block);
  }

  bool query(Session& session, const Query& query) {
    return Access::queryFilter(session, query);
  }

  void close(Session& session) {
    Access::closeFilter(session);
  }

  bool active(const Session& session) noexcept {
    return feature::open(session.block_filter);
  }

  Status status(const Session& session) noexcept {
    return feature::status(session.block_filter);
  }

  ds::Option<std::size_t> block(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* pane = findPane(session.panes, pane_id);

    return pane == nullptr ? ds::none : indexOf(session.block_filter, *pane);
  }

  std::size_t highlight(Session& session, std::uint64_t pane_id, std::span<const CellValue> cells, std::span<Mark> marks) {
    if (!feature::open(session.block_filter) || feature::status(session.block_filter).pane_id != pane_id) {
      return 0;
    }

    return feature::highlight(session.block_filter, cells, marks);
  }

  bool fail(feature::State& state, std::uint64_t request_id) noexcept {
    return feature::fail(state, request_id);
  }

}
