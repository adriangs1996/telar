module telar.gui.application;

import std;

import :access;
import telar.gui.features.terminal.copy_mode;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application::terminal::copy_mode {

  namespace {

    namespace feature = features::terminal::copy_mode;

    // Sends what `plan` asks for and moves the pane's view, once copy mode commits it.
    void apply(Session& session, const feature::CopyPlan& plan, Pane<Memory>& pane) {
      auto& state = session.copy_mode;

      if (!feature::current(state, plan) || plan.effect.open_link) {
        return;
      }

      if (plan.selection) {
        session.link.send(*plan.selection);
      }

      if (!feature::commit(state, plan)) {
        return;
      }

      if (plan.viewport) {
        if (pane.screen.scroll().offset != plan.viewport->offset) {
          ++Access::viewVersion(session).viewport;
        }

        pane.screen.setViewport(plan.viewport->offset);
        ++pane.viewport_requests;
        session.link.send(*plan.viewport);
      }
    }

    feature::CopyPointerAuthority authority(const Session& session, const CopyPointerInput& input) noexcept {
      const auto copy = feature::view(session.copy_mode);

      if (const auto owner = copy.pointerOwner()) {
        const auto* pane = session.findPane(owner->pane_id);
        const auto available = pane != nullptr && pane->attached && pane->screen.columns() != 0 && pane->screen.rows() != 0;

        return {.kind = feature::CopyPointerAuthority::Kind::selection, .dragging = owner->dragging, .position = available && input.pane_id == owner->pane_id ? ds::Option{input.position} : ds::none};
      }

      const auto& state = copy.state();
      if (!state) {
        return {};
      }

      const auto* pane = session.findPane(state->pane_id);
      if (pane == nullptr || !pane->attached) {
        return {.kind = feature::CopyPointerAuthority::Kind::missing};
      }

      return {.kind = feature::CopyPointerAuthority::Kind::keyboard, .inside = input.pane_id == state->pane_id && input.inside};
    }

    void move(Session& session, const CopyPointerDecision& decision, bool released, Pane<Memory>& pane) {
      const auto& state = session.copy_mode;
      const auto grid = copyGrid(pane.screen);
      ds::Option<feature::CopyPlan> plan;

      if (decision.motion) {
        plan = feature::drag(state, *decision.motion, grid, released);
      } else if (decision.vertical) {
        plan = feature::scroll(state, *decision.vertical, grid);
      }

      if (plan) {
        apply(session, *plan, pane);
      }
    }

  }

  CopyModeView view(const Session& session) noexcept {
    return feature::view(session.copy_mode);
  }

  bool enter(Session& session) noexcept {
    const auto* pane = session.focusedPane();
    if (pane == nullptr || !pane->attached) {
      return false;
    }

    return feature::enter(session.copy_mode, pane->id, copyGrid(pane->screen), pane->screen.cursor());
  }

  CopyEffect key(Session& session, const TerminalKey& key) {
    auto* copy_pane = pane(session);
    if (copy_pane == nullptr) {
      return {.handled = false};
    }

    const auto plan = feature::key(session.copy_mode, key, copyGrid(copy_pane->screen));
    if (!plan) {
      return {};
    }

    apply(session, *plan, *copy_pane);

    return plan->effect;
  }

  void leave(Session& session) {
    auto& state = session.copy_mode;

    if (auto* copy_pane = pane(session)) {
      apply(session, feature::leave(state, copyGrid(copy_pane->screen)), *copy_pane);
    } else {
      feature::close(state);
    }

    feature::forget(state);
  }

  bool press(Session& session, CopyPress press) noexcept {
    const auto* pane = session.focusedPane();
    if (pane == nullptr || pane->id != press.pane_id || !pane->attached) {
      return false;
    }

    return feature::press(session.copy_mode, press, copyGrid(pane->screen));
  }

  bool copy(Session& session, std::uint64_t pane_id) {
    const auto& state = feature::view(session.copy_mode).state();
    if (!state || state->pane_id != pane_id || !state->pointer) {
      return false;
    }

    const auto selection = state->selectionRequest();
    if (!selection) {
      return false;
    }

    session.link.send(*selection);

    return true;
  }

  CopyPointerDecision::Outcome pointer(Session& session, const CopyPointerInput& input) {
    auto& state = session.copy_mode;
    const auto decision = feature::routeCopyPointer(input, authority(session, input));
    const auto finish = decision.cancel || (decision.motion && input.kind == CopyPointerKind::release);

    try {
      if (decision.leave) {
        leave(session);
      } else if (decision.cancel) {
        static_cast<void>(feature::clearPointer(state));
      } else if (auto* copy_pane = pane(session); copy_pane != nullptr) {
        move(session, decision, input.kind == CopyPointerKind::release, *copy_pane);
      }
    } catch (...) {
      if (finish) {
        feature::release(state);
      }

      throw;
    }

    if (finish) {
      feature::release(state);
    }

    return decision.outcome;
  }

  void search(Session& session, std::string_view needle) {
    auto& state = session.copy_mode;
    auto* copy_pane = pane(session);
    if (copy_pane == nullptr || !feature::view(state).active()) {
      throw EncodingError{"No copy mode owns this search"};
    }

    if (const auto plan = feature::type(state, needle, copyGrid(copy_pane->screen)); needle.empty()) {
      if (plan) {
        apply(session, *plan, *copy_pane);
      }

      Access::changedPane(session) = copy_pane->id;
      return;
    }

    const auto request_id = session.link.nextRequest();
    const auto request = feature::request(state, copy_pane->id, request_id, session.readsRows());

    try {
      std::visit([&](const auto& message) {
        session.link.send(message);
      },
          request);
    } catch (...) {
      feature::fail(state, request_id);
      throw;
    }
  }

  void finishSearch(Session& session) noexcept {
    feature::finishSearch(session.copy_mode);
  }

  CopySearchState searchState(const Session& session) noexcept {
    return feature::search(session.copy_mode);
  }

  void stepMatch(Session& session, bool forward) {
    TerminalKey key{.code = KeyChord::Key::character, .codepoint = static_cast<std::uint32_t>(forward ? 'n' : 'N')};

    static_cast<void>(copy_mode::key(session, key));
  }

  ds::Option<std::size_t> searchBlock(const Session& session) noexcept {
    return feature::searchBlock(session.copy_mode);
  }

  bool searchScopes(const Session& session) noexcept {
    return feature::searchScopes(session.copy_mode, session.readsRows());
  }

  void toggleSearchScope(Session& session) noexcept {
    feature::toggleSearchScope(session.copy_mode, session.readsRows());
  }

  bool takeSearchRequest(Session& session) noexcept {
    return feature::takeSearchRequest(session.copy_mode);
  }

  Pane<Memory>* pane(Session& session) noexcept {
    auto& state = session.copy_mode;
    const auto& copy = feature::view(state).state();
    if (!copy) {
      return nullptr;
    }

    auto* found = session.findPaneMut(copy->pane_id);
    if (found == nullptr || !found->attached) {
      feature::close(state);

      return nullptr;
    }

    return found;
  }

  Change receive(Session& session, const PaneMatches& message) {
    auto& state = session.copy_mode;
    if (!feature::awaits(state, message)) {
      return Change::none;
    }

    auto* copy_pane = pane(session);
    if (copy_pane == nullptr) {
      return Change::none;
    }

    if (const auto plan = feature::receive(state, message, copyGrid(copy_pane->screen))) {
      apply(session, *plan, *copy_pane);
    }

    Access::changedPane(session) = copy_pane->id;

    return Change::copy_mode;
  }

}
