module telar.gui.features.history;

import std;

import telar.base.memory.allocators;
import telar.wire.history;

namespace telar::gui::features::history {

  State::State(Memory& memory)
      : browser_(memory) {}

  QueryHistory search(State& state, QueryHistory request) {
    const auto parsed = HistorySearch::parse(request.query, request.failed_only);

    request.query = parsed.query;
    request.failed_only = parsed.failed_only;

    return Access::browser(state).begin(request);
  }

  std::optional<QueryHistory> page(State& state, HistoryPage direction, std::uint64_t request_id) {
    return Access::browser(state).page(direction, request_id);
  }

  QueryHistory refresh(State& state, std::uint64_t request_id) {
    return Access::browser(state).refresh(request_id);
  }

  bool select(State& state, std::size_t index) {
    return Access::browser(state).select(index);
  }

  void inspect(State& state, bool enabled) {
    Access::browser(state).setInspecting(enabled);
  }

  std::optional<QueryHistory> readCommand(State& state, std::uint64_t request_id) {
    return Access::browser(state).readCommand(request_id);
  }

  std::optional<ReadHistoryOutput> readOutput(State& state, std::uint64_t request_id) {
    return Access::browser(state).readOutput(request_id);
  }

  DeleteHistory erase(State& state, std::uint64_t id, std::uint64_t request_id) {
    return Access::browser(state).erase(id, request_id);
  }

  bool receive(State& state, const HistoryResults& results) {
    return Access::browser(state).apply(results);
  }

  bool receive(State& state, const HistoryOutput& output) {
    return Access::browser(state).apply(output);
  }

  bool receive(State& state, const HistoryPruned& pruned) {
    return Access::browser(state).apply(pruned);
  }

  bool fail(State& state, std::uint64_t request_id, std::string_view message) {
    return Access::browser(state).fail(request_id, message);
  }

  void report(State& state, std::string_view message) {
    Access::browser(state).setError(message);
  }

  void suspend(State& state) noexcept {
    Access::browser(state).suspend();
  }

}
