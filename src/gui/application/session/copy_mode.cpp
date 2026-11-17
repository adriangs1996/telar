module telar.gui.application.session;

import std;
import telar.gui.foundation.terminal;
import telar.gui.input.copy_pointer;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;

namespace telar::gui {

  const CopyMode& Session::copyMode() const noexcept {
    return copy_mode_;
  }

  bool Session::beginSelection(CopyPress press) noexcept {
    const auto* pane = focusedPane();
    if (pane == nullptr || pane->id != press.pane_id || !pane->attached) {
      return false;
    }

    return copy_mode_.beginPointer(press, copyGrid(pane->screen));
  }

  bool Session::copySelection(std::uint64_t pane_id) {
    const auto& state = copy_mode_.state();
    if (!state || state->pane_id != pane_id || !state->pointer) {
      return false;
    }

    const auto selection = state->selectionRequest();
    if (!selection) {
      return false;
    }

    send(*selection);

    return true;
  }

  CopyPointerDecision::Outcome Session::pointer(const CopyPointerInput& input) {
    const auto decision = routeCopyPointer(input, pointerAuthority(input));
    const auto finish = decision.cancel || (decision.motion && input.kind == CopyPointerKind::release);

    try {
      if (decision.leave) {
        leaveCopyMode();
      } else if (decision.cancel) {
        static_cast<void>(copy_mode_.clearPointer());
      } else if (auto* pane = copyPane(); pane != nullptr) {
        applyPointerMotion(decision, input.kind == CopyPointerKind::release, *pane);
      }
    } catch (...) {
      if (finish) {
        copy_mode_.finishPointer();
      }

      throw;
    }

    if (finish) {
      copy_mode_.finishPointer();
    }

    return decision.outcome;
  }

  bool Session::enterCopyMode() noexcept {
    const auto* pane = focusedPane();
    if (pane == nullptr || !pane->attached) {
      return false;
    }

    const auto entered = copy_mode_.enter(pane->id, copyGrid(pane->screen), pane->screen.cursor());
    if (entered) {
      copy_search_request_ = 0;
    }

    return entered;
  }

  CopyEffect Session::copyKey(const TerminalKey& key) {
    auto* pane = copyPane();
    if (pane == nullptr) {
      return {.handled = false};
    }

    const auto plan = copy_mode_.key(key, copyGrid(pane->screen));
    if (!plan) {
      return {};
    }

    applyCopyPlan(*plan, *pane);
    // A search begins from where the cursor is now.
    if (plan->effect.search) {
      copy_search_origin_.reset();
      copy_search_query_.clear();
    }

    return plan->effect;
  }

  void Session::leaveCopyMode() {
    if (auto* pane = copyPane()) {
      applyCopyPlan(copy_mode_.leave(copyGrid(pane->screen)), *pane);
    } else {
      copy_mode_.reset();
    }

    copy_search_request_ = 0;
    copy_search_rows_.reset();
    copy_search_origin_.reset();
    copy_search_query_.clear();
  }

  void Session::searchCopy(std::string_view needle) {
    auto* pane = copyPane();
    if (pane == nullptr || !copy_mode_.active()) {
      throw EncodingError{"No copy mode owns this search"};
    }

    // A search typed a letter at a time starts where the first letter found the cursor.
    if (!copy_search_origin_) {
      copy_search_origin_ = copy_mode_.state()->cursor;
    }

    copy_search_query_.assign(needle);
    if (needle.empty()) {
      // Nothing to look for: no matches, and the cursor back where the search began.
      copy_search_request_ = 0;
      copy_search_truncated_ = false;
      if (const auto plan = copy_mode_.search({}, copyGrid(pane->screen), copy_search_origin_)) {
        applyCopyPlan(*plan, *pane);
      }

      changed_pane_ = pane->id;
      return;
    }

    const auto request_id = nextRequest();

    if (copy_search_rows_ && copy_search_scoped_ && readsRows()) {
      send(SearchPaneRows{.request_id = request_id, .pane_id = pane->id, .needle = needle, .first_row = copy_search_rows_->first, .last_row = copy_search_rows_->last});
    } else {
      send(SearchPane{.request_id = request_id, .pane_id = pane->id, .needle = needle});
    }

    copy_search_request_ = request_id;
  }

  void Session::finishCopySearch() noexcept {
    copy_search_origin_.reset();
  }

  auto Session::copySearch() const noexcept -> CopySearchState {
    const auto& state = copy_mode_.state();

    return {.query = copy_search_query_, .searching = copy_search_request_ != 0, .count = copy_mode_.matches().size(), .index = state ? std::size_t{state->match_index} : std::size_t{0}, .truncated = copy_search_truncated_};
  }

  void Session::stepCopyMatch(bool forward) {
    TerminalKey key{.code = KeyChord::Key::character, .codepoint = static_cast<std::uint32_t>(forward ? 'n' : 'N')};

    static_cast<void>(copyKey(key));
  }

  std::optional<std::size_t> Session::copySearchBlock() const noexcept {
    return copy_search_rows_ && copy_search_scoped_ ? std::optional{copy_search_rows_->block} : std::nullopt;
  }

  bool Session::copySearchScopes() const noexcept {
    return copy_search_rows_.has_value() && readsRows();
  }

  void Session::toggleCopySearchScope() noexcept {
    if (copySearchScopes()) {
      copy_search_scoped_ = !copy_search_scoped_;
    }
  }

  bool Session::takeSearchRequest() noexcept {
    return std::exchange(search_requested_, false);
  }

  Pane<Memory>* Session::copyPane() noexcept {
    if (!copy_mode_.state()) {
      return nullptr;
    }

    auto* pane = findPane(copy_mode_.state()->pane_id);
    if (pane == nullptr || !pane->attached) {
      copy_mode_.reset();
      copy_search_request_ = 0;

      return nullptr;
    }

    return pane;
  }

  CopyPointerAuthority Session::pointerAuthority(const CopyPointerInput& input) const noexcept {
    if (const auto owner = copy_mode_.pointerOwner()) {
      const auto* pane = findPane(owner->pane_id);
      const auto available = pane != nullptr && pane->attached && pane->screen.columns() != 0 && pane->screen.rows() != 0;

      return {.kind = CopyPointerAuthority::Kind::selection, .dragging = owner->dragging, .position = available && input.pane_id == owner->pane_id ? std::optional{input.position} : std::nullopt};
    }

    const auto& state = copy_mode_.state();
    if (!state) {
      return {};
    }

    const auto* pane = findPane(state->pane_id);
    if (pane == nullptr || !pane->attached) {
      return {.kind = CopyPointerAuthority::Kind::missing};
    }

    return {.kind = CopyPointerAuthority::Kind::keyboard, .inside = input.pane_id == state->pane_id && input.inside};
  }

  void Session::applyCopyPlan(const CopyPlan& plan, Pane<Memory>& pane) {
    if (!copy_mode_.current(plan) || plan.effect.open_link) {
      return;
    }

    if (plan.selection) {
      send(*plan.selection);
    }

    if (!copy_mode_.commit(plan)) {
      return;
    }

    if (plan.viewport) {
      if (pane.screen.scroll().offset != plan.viewport->offset) {
        ++view_version_.viewport;
      }

      pane.screen.setViewport(plan.viewport->offset);
      ++pane.viewport_requests;
      send(*plan.viewport);
    }
  }

  void Session::applyPointerMotion(const CopyPointerDecision& decision, bool released, Pane<Memory>& pane) {
    const auto grid = copyGrid(pane.screen);
    std::optional<CopyPlan> plan;

    if (decision.motion) {
      plan = copy_mode_.pointer(*decision.motion, grid, released);
    } else if (decision.vertical) {
      plan = copy_mode_.vertical(*decision.vertical, grid);
    }

    if (plan) {
      applyCopyPlan(*plan, pane);
    }
  }

  Change Session::apply(const PaneMatches& message) {
    const auto& state = copy_mode_.state();
    if (message.request_id != copy_search_request_ || !state || state->pointer || message.pane_id != state->pane_id) {
      return Change::none;
    }

    auto* pane = copyPane();
    if (pane == nullptr) {
      return Change::none;
    }

    const auto plan = copy_mode_.search(message.matches, copyGrid(pane->screen), copy_search_origin_);
    if (plan) {
      applyCopyPlan(*plan, *pane);
    }

    copy_search_truncated_ = message.truncated;

    copy_search_request_ = 0;
    changed_pane_ = pane->id;

    return Change::copy_mode;
  }

}
