module;
#include "tbc/annotations.hpp"

// The command history panel: searching the commands run in every pane, paging through them,
// inspecting one with its output, and the panel's presentation.
export module telar.gui.features.history;

export import :entry;
export import :filters;
export import :cards;
export import :inspection;
export import :motion;
export import :pointer;
// Exported as every interface partition must be; it exports nothing.
export import :browser;

import std;

import telar.base.memory.allocators;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::history {

  struct Access;

}

export namespace telar::gui::features::history {

  // The page of the history the panel shows, the selected command and its output, and the
  // requests in flight. Opaque: only the use cases below reach it.
  class State {
    friend struct Access;

  public:
    explicit State(Memory& memory);

  private:
    HistoryBrowser<Memory> browser_;
  };

  // What the panel reads of the history: a view of the state, valid until a use case changes it.
  // Inline, as the pointer reads it on every move over the panel.
  // A view of a history browser, region `a`: what it reads lies in the browser, not in the view.
  class TBC_HOT_PATH HistoryView {
  public:
    inline explicit HistoryView(tbc::view<const HistoryBrowser<Memory>&, tbc::lt::a> browser) noexcept
        : browser_(&browser) {}

    [[nodiscard]] inline tbc::view<const ds::Vec<HistoryRow<Memory>, Memory>&, tbc::lt::a> rows() const noexcept {
      return browser_->rows();
    }

    [[nodiscard]] inline tbc::view<const HistoryViewState&, tbc::lt::a> state() const noexcept {
      return browser_->state();
    }

    [[nodiscard]] inline tbc::view<const HistoryRow<Memory>&, tbc::lt::a> entry(std::uint64_t id) const {
      return browser_->entry(id);
    }

    [[nodiscard]] inline std::size_t entryIndex(std::uint64_t id) const {
      return browser_->entryIndex(id);
    }

    [[nodiscard]] inline tbc::view<std::string_view, tbc::lt::a> command(std::uint64_t id) const {
      return browser_->command(id);
    }

    [[nodiscard]] inline bool canPage(HistoryPage direction) const noexcept {
      return browser_->canPage(direction);
    }

    [[nodiscard]] inline bool canSubmit() const noexcept {
      return browser_->canSubmit();
    }

    [[nodiscard]] inline tbc::view<std::string_view, tbc::lt::a> selectedCommand() const {
      return browser_->selectedCommand();
    }

    [[nodiscard]] inline tbc::view<std::string_view, tbc::lt::a> output() const noexcept {
      return browser_->output();
    }

    [[nodiscard]] inline tbc::view<std::string_view, tbc::lt::a> error() const noexcept {
      return browser_->error();
    }

    [[nodiscard]] inline std::uint64_t viewVersion() const noexcept {
      return browser_->viewVersion();
    }

    [[nodiscard]] inline std::uint64_t revision() const noexcept {
      return browser_->revision();
    }

    [[nodiscard]] inline std::uint64_t rowsVersion() const noexcept {
      return browser_->rowsVersion();
    }

    [[nodiscard]] inline ds::Option<HistoryChoice> choice() const noexcept {
      return browser_->choice();
    }

    [[nodiscard]] inline bool acceptsRow(HistoryChoice candidate) const noexcept {
      return browser_->acceptsRow(candidate);
    }

    [[nodiscard]] inline bool accepts(HistoryChoice candidate) const noexcept {
      return browser_->accepts(candidate);
    }

    [[nodiscard]] inline HistoryScope scope() const noexcept {
      return browser_->scope();
    }

    [[nodiscard]] inline HistoryMatch match() const noexcept {
      return browser_->match();
    }

    [[nodiscard]] inline bool deleting() const noexcept {
      return browser_->deleting();
    }

    [[nodiscard]] inline bool owns(std::uint64_t request_id) const noexcept {
      return browser_->owns(request_id);
    }

  private:
    tbc::view<const HistoryBrowser<Memory>*, tbc::lt::a> browser_;
  };

  [[nodiscard]] TBC_HOT_PATH inline HistoryView view(const State& state) noexcept;

  // A new search: `request` says what to look for, its query text read by HistorySearch (a
  // leading '!' asks for failures only). Returns the request to send; throws EncodingError when
  // too many requests are in flight, the panel showing why.
  [[nodiscard]] tbc::view<QueryHistory, tbc::lt::a> search(tbc::view<State&, tbc::lt::a> state, QueryHistory request);

  // The next older or newer page of the search; none at its end or while a page loads.
  [[nodiscard]] ds::Option<QueryHistory> page(State& state, HistoryPage direction, std::uint64_t request_id);

  // The search again from its newest command, as the history changed under it.
  [[nodiscard]] QueryHistory refresh(State& state, std::uint64_t request_id);

  // Selects row `index`; false when it already was.
  bool select(State& state, std::size_t index);

  // Opens or closes the inspection of the selected command.
  void inspect(State& state, bool enabled);

  // The read of the selected command's whole text, when the page holds only its preview.
  [[nodiscard]] ds::Option<QueryHistory> readCommand(State& state, std::uint64_t request_id);

  // The read of the selected command's output, while it is inspected.
  [[nodiscard]] ds::Option<ReadHistoryOutput> readOutput(State& state, std::uint64_t request_id);

  // Deletes command `id` from the history.
  [[nodiscard]] DeleteHistory erase(State& state, std::uint64_t id, std::uint64_t request_id);

  // A page, the selected command or its output arrived: false when it is not the one awaited.
  bool receive(State& state, const HistoryResults& results);

  bool receive(State& state, const HistoryOutput& output);

  // Commands left the history: true when the page must be searched again.
  bool receive(State& state, const HistoryPruned& pruned);

  // Request `request_id` failed: false when it is not the history's current one.
  bool fail(State& state, std::uint64_t request_id, std::string_view message);

  // Shows `message` in place of the page.
  void report(State& state, std::string_view message);

  // The connection ended: no request will be answered.
  void suspend(State& state) noexcept;

}

namespace telar::gui::features::history {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr HistoryBrowser<Memory>& browser(State& state) noexcept {
      return state.browser_;
    }

    [[nodiscard]] static constexpr const HistoryBrowser<Memory>& browser(const State& state) noexcept {
      return state.browser_;
    }
  };

  inline HistoryView view(const State& state) noexcept {
    return HistoryView{Access::browser(state)};
  }

}
