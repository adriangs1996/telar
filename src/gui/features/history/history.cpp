module telar.gui.features.history;

import std;

import telar.base.memory.allocators;
import telar.wire.history;
import telar.base.ds;

namespace telar::gui::features::history {

  State::State(Memory& memory)
      : browser_(memory) {}

  tbc::val_a<QueryHistory> search(tbc::mut_a<State> state, QueryHistory request) {
    return Access::browser(state).begin(request);
  }

  ds::Option<QueryHistory> page(State& state, HistoryPage direction, std::uint64_t request_id) {
    return Access::browser(state).page(direction, request_id);
  }

  ds::Option<QueryHistory> refresh(State& state, std::uint64_t request_id) {
    return Access::browser(state).refresh(request_id);
  }

  bool select(State& state, std::size_t index) {
    return Access::browser(state).select(index);
  }

  void inspect(State& state, bool enabled) {
    Access::browser(state).setInspecting(enabled);
  }

  ds::Option<QueryHistory> readCommand(State& state, std::uint64_t request_id) {
    return Access::browser(state).readCommand(request_id);
  }

  ds::Option<ReadHistoryOutput> readOutput(State& state, std::uint64_t request_id) {
    return Access::browser(state).readOutput(request_id);
  }

  ds::Option<QueryHistoryCommandStats> readRuns(State& state, std::uint64_t request_id, CalendarSample sampled) {
    return Access::browser(state).readRuns(request_id, HistoryLabels::dayEnd(sampled));
  }

  ds::Option<QueryHistory> readContext(State& state, std::uint64_t request_id) {
    return Access::browser(state).readContext(request_id);
  }

  DeleteHistory erase(State& state, std::uint64_t id, std::uint64_t request_id) {
    return Access::browser(state).erase(id, request_id);
  }

  ds::Option<DeleteHistory> hide(State& state, std::uint64_t id, std::uint64_t request_id) {
    return Access::browser(state).hide(id, request_id);
  }

  ds::Option<DeleteHistory> commitHidden(State& state, std::uint64_t request_id) {
    return Access::browser(state).commitHidden(request_id);
  }

  bool unhide(State& state) noexcept {
    return Access::browser(state).unhide();
  }

  bool toggleMark(State& state, std::uint64_t id) {
    return Access::browser(state).toggleMark(id);
  }

  void clearMarks(State& state) noexcept {
    Access::browser(state).clearMarks();
  }

  bool receive(State& state, const HistoryResults& results) {
    return Access::browser(state).apply(results);
  }

  bool receive(State& state, const HistoryOutput& output) {
    return Access::browser(state).apply(output);
  }

  bool receive(State& state, const HistoryCommandStats& stats) {
    return Access::browser(state).apply(stats);
  }

  bool receive(State& state, const HistoryPruned& pruned) {
    return Access::browser(state).apply(pruned);
  }

  HistoryFailure fail(State& state, std::uint64_t request_id, std::string_view message) {
    return Access::browser(state).fail(request_id, message);
  }

  void report(State& state, std::string_view message) {
    Access::browser(state).setError(message);
  }

  bool watch(State& state, bool watching) noexcept {
    return Access::browser(state).watch(watching);
  }

  bool refreshDue(State& state) noexcept {
    return Access::browser(state).takeRefreshDue();
  }

  void suspend(State& state) noexcept {
    Access::browser(state).suspend();
  }

}
