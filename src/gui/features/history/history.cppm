module;

// The command history panel: searching the commands run in every pane, paging through them,
// inspecting one with its output, and the panel's presentation.
export module telar.gui.features.history;

export import :entry;
export import :filters;
export import :cards;
export import :inspection;
export import :motion;
export import :pointer;
export import :typing;
export import :pins;
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
  class [[tbc::hot_path]] HistoryView {
  public:
    inline explicit HistoryView(tbc::ref_a<HistoryBrowser<Memory>> browser) noexcept
        : browser_(&browser) {}

    [[nodiscard]] inline tbc::ref_a<ds::Vec<HistoryRow<Memory>, Memory>> rows() const noexcept {
      return browser_->rows();
    }

    [[nodiscard]] inline tbc::ref_a<HistoryViewState> state() const noexcept {
      return browser_->state();
    }

    [[nodiscard]] inline tbc::ref_a<HistoryRow<Memory>> entry(std::uint64_t id) const {
      return browser_->entry(id);
    }

    [[nodiscard]] inline std::size_t entryIndex(std::uint64_t id) const {
      return browser_->entryIndex(id);
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> command(std::uint64_t id) const {
      return browser_->command(id);
    }

    [[nodiscard]] inline bool canPage(HistoryPage direction) const noexcept {
      return browser_->canPage(direction);
    }

    [[nodiscard]] inline bool canSubmit() const noexcept {
      return browser_->canSubmit();
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> selectedCommand() const {
      return browser_->selectedCommand();
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> output() const noexcept {
      return browser_->output();
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> error() const noexcept {
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

    // Whether the runtime tells of each change to the history.
    [[nodiscard]] inline bool watching() const noexcept {
      return browser_->watching();
    }

    [[nodiscard]] inline bool preloads() const noexcept {
      return browser_->preloads();
    }

    [[nodiscard]] inline bool searchesOutput() const noexcept {
      return browser_->searchesOutput();
    }

    // What the newest runs of the inspected command tell, and the commands run around it.
    [[nodiscard]] inline tbc::ref_a<HistoryRunStats> runStats() const noexcept {
      return browser_->runStats();
    }

    [[nodiscard]] inline std::size_t contextCount() const noexcept {
      return browser_->contextCount();
    }

    [[nodiscard]] inline tbc::val_a<HistoryContextEntry> contextAt(std::size_t index) const {
      return browser_->contextAt(index);
    }

    [[nodiscard]] inline bool deleting() const noexcept {
      return browser_->deleting();
    }

    [[nodiscard]] inline bool owns(std::uint64_t request_id) const noexcept {
      return browser_->owns(request_id);
    }

    // The command whose delete waits for its undo to pass, 0 when none, and what its row showed.
    [[nodiscard]] inline std::uint64_t hidden() const noexcept {
      return browser_->hidden();
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> hiddenCommand() const noexcept {
      return browser_->hiddenCommand();
    }

    // The commands marked to be used together, in the order they were marked.
    [[nodiscard]] inline std::size_t markCount() const noexcept {
      return browser_->markCount();
    }

    [[nodiscard]] inline std::uint64_t markedId(std::size_t index) const noexcept {
      return browser_->markedId(index);
    }

    [[nodiscard]] inline tbc::val_a<std::string_view> markedCommand(std::size_t index) const {
      return browser_->markedCommand(index);
    }

    [[nodiscard]] inline bool marked(std::uint64_t id) const noexcept {
      return browser_->marked(id);
    }

  private:
    tbc::val_a<const HistoryBrowser<Memory>*> browser_;
  };

  [[nodiscard]] [[tbc::hot_path]] inline HistoryView view(const State& state) noexcept;

  // A new search: `request` says what to look for, its query text as typed, for the matcher to
  // read. Returns the request to send; throws EncodingError when too many requests are in
  // flight, the panel showing why.
  [[nodiscard]] tbc::val_a<QueryHistory> search(tbc::mut_a<State> state, QueryHistory request);

  // The next older or newer page of the search; none at its end or while a page loads.
  [[nodiscard]] ds::Option<QueryHistory> page(State& state, HistoryPage direction, std::uint64_t request_id);

  // The page shown read anew, as the history changed under it, the selected command kept; none
  // while a search or a page is on its way, which reads the history as it is now. The rows stay
  // usable while it loads.
  [[nodiscard]] ds::Option<QueryHistory> refresh(State& state, std::uint64_t request_id);

  // Selects row `index`; false when it already was.
  bool select(State& state, std::size_t index);

  // Opens or closes the inspection of the selected command.
  void inspect(State& state, bool enabled);

  // The read of the selected command's whole text, when the page holds only its preview.
  [[nodiscard]] ds::Option<QueryHistory> readCommand(State& state, std::uint64_t request_id);

  // The read of the selected command's output, while it is inspected.
  [[nodiscard]] ds::Option<ReadHistoryOutput> readOutput(State& state, std::uint64_t request_id);

  // The read of how every run of the inspected command went, with its runs in each of the last
  // days, the last of them today as `sampled` tells; none when it is read.
  [[nodiscard]] ds::Option<QueryHistoryCommandStats> readRuns(State& state, std::uint64_t request_id, CalendarSample sampled);

  // The read of the commands run around the inspected one in its pane; none when it is read or
  // its text is not loaded.
  [[nodiscard]] ds::Option<QueryHistory> readContext(State& state, std::uint64_t request_id);

  // Deletes command `id` from the history.
  [[nodiscard]] DeleteHistory erase(State& state, std::uint64_t id, std::uint64_t request_id);

  // Takes command `id`'s row away while its delete can still be taken back, and gives the delete
  // of the command that waited so before, which goes now; none when none waited.
  [[nodiscard]] ds::Option<DeleteHistory> hide(State& state, std::uint64_t id, std::uint64_t request_id);

  // The delete of the command taken away, which can no longer be taken back; none when none waits.
  [[nodiscard]] ds::Option<DeleteHistory> commitHidden(State& state, std::uint64_t request_id);

  // Takes the delete waiting back: true when one did, and its row is to be read again.
  bool unhide(State& state) noexcept;

  // Marks command `id` to be used with the others marked, or unmarks it; true when it is marked
  // now. Throws EncodingError when its text is not loaded or the marks are full.
  bool toggleMark(State& state, std::uint64_t id);

  void clearMarks(State& state) noexcept;

  // A page, the selected command or its output arrived: false when it is not the one awaited.
  bool receive(State& state, const HistoryResults& results);

  bool receive(State& state, const HistoryOutput& output);

  bool receive(State& state, const HistoryCommandStats& stats);

  // Commands left the history: true when the page must be searched again.
  bool receive(State& state, const HistoryPruned& pruned);

  // Request `request_id` failed: which of the history's it was, none when it is not one of its
  // current ones.
  HistoryFailure fail(State& state, std::uint64_t request_id, std::string_view message);

  // Shows `message` in place of the page.
  void report(State& state, std::string_view message);

  // Whether the panel follows the runtime's changes to the history while it shows it: true when
  // that changed.
  bool watch(State& state, bool watching) noexcept;

  // Whether the page is to be read anew now: changes came while a refresh was on its way, and it
  // arrived. Told once.
  [[nodiscard]] bool refreshDue(State& state) noexcept;

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
