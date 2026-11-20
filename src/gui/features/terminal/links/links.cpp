module telar.gui.features.terminal.links;

import std;

import telar.wire.editor;
import telar.base.ds;

namespace telar::gui::features::terminal::links {

  void EditorOpening::begin(const EditorRequest& request) {
    if (pending_) {
      throw std::runtime_error{"EditorOpenBusy"};
    }

    pending_ = request;
  }

  ds::Option<EditorRequest> EditorOpening::complete(std::uint64_t request_id) {
    if (!owns(request_id)) {
      return {};
    }

    return std::exchange(pending_, ds::none);
  }

  bool EditorOpening::owns(std::uint64_t request_id) const noexcept {
    return pending_ && pending_->request_id == request_id;
  }

  void EditorOpening::reset() noexcept {
    pending_.reset();
  }

  tbc::val_a<OpenEditor> open(State& state, tbc::ref_a<EditorRequest> request) {
    auto& opening = Access::opening(state);

    opening.begin(request);

    return request.message();
  }

  ds::Option<EditorRequest> complete(State& state, std::uint64_t request_id) {
    return Access::opening(state).complete(request_id);
  }

  bool pending(const State& state, std::uint64_t request_id) noexcept {
    return Access::opening(state).owns(request_id);
  }

  void suspend(State& state) noexcept {
    Access::opening(state).reset();
  }

}
