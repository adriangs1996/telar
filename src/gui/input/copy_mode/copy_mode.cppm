export module telar.gui.input.copy_mode;

import std;
import telar.tbc;

import telar.gui.terminal.font_grid;
import telar.gui.input.key_encoder;
import telar.gui.input.copy_pointer;
import telar.gui.terminal.selection;
import telar.wire.clipboard;
import telar.wire.pane_io;
import telar.wire.vocabulary;

// Interface: terminal/copy_state.cppm
export {
  namespace telar::gui {

    struct CopyPointer {
      CopyPoint start;
      CopyPoint end;
      CopyGranularity granularity = CopyGranularity::character;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;

      bool operator==(const CopyPointer&) const = default;
    };

    struct CopyState {
      std::uint64_t pane_id = 0;
      CopyPoint cursor;
      std::optional<CopyPointer> pointer = std::nullopt;
      std::optional<CopyPoint> anchor = std::nullopt;
      bool linewise = false;
      std::uint32_t entry_offset = 0;
      std::uint32_t viewport_offset = 0;
      CopyDirection search_direction = CopyDirection::forward;
      std::uint16_t match_index = 0;

      bool operator==(const CopyState&) const = default;

      [[nodiscard]] std::optional<CopySelection> selectionRequest() const noexcept;

      void horizontal(const CopyGrid& grid, std::int32_t delta) noexcept;

      void vertical(std::int32_t delta, const CopyGrid& grid) noexcept;

      void reveal(const CopyGrid& grid) noexcept;

      void toggleSelection(bool whole_lines) noexcept;

      bool clearSelection() noexcept;

      void beginPointer(CopyGranularity granularity, const CopyGrid& grid) noexcept;

      void movePointer(CopyPoint point, const CopyGrid& grid) noexcept;

      void onFrame(std::uint32_t previous_offset, Scroll scroll) noexcept;

      // To match `index`, the cursor on its first cell as vim's search puts it, a selection under
      // way stretched there and none begun; the view centred on it unless it is well inside.
      void gotoMatch(std::uint16_t index, std::span<const PaneMatch> matches, const CopyGrid& grid) noexcept;

      // Shows the cursor clear of the view's edges, where a pinned separator and a docked line
      // cover rows: a row outside the middle of the view, a fifth of it from each edge and at least
      // two rows, comes to the view's middle.
      void revealWithMargin(const CopyGrid& grid) noexcept;

      // To the first match past the cursor that way, or, `inclusive`, from the cursor's own cell.
      void applyMatches(std::span<const PaneMatch> matches, const CopyGrid& grid, bool inclusive = false) noexcept;

      [[nodiscard]] CellSelection selection(const CopyGrid& grid) const noexcept;
    };

  }
}

// Interface: terminal/copy_navigation.cppm
export {
  namespace telar::gui {

    struct CopyEffect {
      bool handled = true;
      bool exit = false;
      bool copy = false;
      std::optional<CopyDirection> search = std::nullopt;
      bool open_link = false;
    };

    class CopyNavigation {
    public:
      static CopyEffect apply(CopyState& state, const TerminalKey& key, const CopyGrid& grid, std::span<const PaneMatch> matches) noexcept;

    private:
      enum class Command : std::uint8_t {
        none,
        left,
        right,
        up,
        down,
        first_column,
        first_nonblank,
        last_nonblank,
        word_forward,
        word_end,
        word_backward,
        paragraph_forward,
        paragraph_backward,
        top,
        bottom,
        page_up,
        page_down,
        half_page_up,
        half_page_down,
        cancel,
        copy,
        leave,
        select,
        select_lines,
        search_forward,
        search_backward,
        match_next,
        match_previous,
        open_link,
      };

      static Command command(const TerminalKey& key) noexcept;

      static Command characterCommand(const TerminalKey& key) noexcept;

      static bool move(CopyState& state, Command action, const CopyGrid& grid) noexcept;

      static void nonBlank(CopyState& state, const CopyGrid& grid, bool last) noexcept;

      static CopyPoint firstAfterClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid) noexcept;

      static CopyPoint lastInClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid, CopyDirection direction) noexcept;

      static void wordForward(CopyState& state, const CopyGrid& grid, bool end) noexcept;

      static void wordBackward(CopyState& state, const CopyGrid& grid) noexcept;

      static void paragraph(CopyState& state, const CopyGrid& grid, CopyDirection direction) noexcept;

      static void cycleMatch(CopyState& state, std::span<const PaneMatch> matches, const CopyGrid& grid, bool forward) noexcept;
    };

  }
}

// Interface: terminal/copy_mode.cppm
export {
  namespace telar::gui {

    struct CopyPlan {
      std::uint64_t revision = 0;
      std::optional<CopyState> next = std::nullopt;
      CopyEffect effect{};
      std::optional<CopySelection> selection = std::nullopt;
      std::optional<SetPaneViewport> viewport = std::nullopt;
      std::optional<std::span<const PaneMatch>> replacement_matches = std::nullopt;
    };

    class CopyMode {
    public:
      static constexpr std::size_t maximum_matches = 256;

      [[nodiscard]] const std::optional<CopyState>& state() const noexcept;

      [[nodiscard]] bool active() const noexcept;

      [[nodiscard]] std::uint64_t revision() const noexcept;

      [[nodiscard]] std::optional<CopyPointerOwner> pointerOwner() const noexcept;

      bool beginPointer(CopyPress press, const CopyGrid& grid) noexcept;

      [[nodiscard]] std::optional<CopyPlan> pointer(CopyPoint local, const CopyGrid& grid, bool released) const noexcept;

      bool clearPointer() noexcept;

      void finishPointer() noexcept;

      [[nodiscard]] std::span<const PaneMatch> matches() const noexcept;

      bool enter(std::uint64_t pane_id, const CopyGrid& grid, const Cursor& cursor) noexcept;

      // Enters at `cursor`, from the top of the scrollback, already selecting from `anchor` when
      // one is given: a command block's text, picked from telar's editor.
      bool enterAt(std::uint64_t pane_id, const CopyGrid& grid, CopyPoint cursor, std::optional<CopyPoint> anchor, bool linewise) noexcept;

      [[nodiscard]] std::optional<CopyPlan> key(const TerminalKey& key, const CopyGrid& grid) const noexcept;

      [[nodiscard]] std::optional<CopyPlan> vertical(std::int32_t rows, const CopyGrid& grid) const noexcept;

      [[nodiscard]] CopyPlan leave(const CopyGrid& grid) const noexcept;

      [[nodiscard]] bool current(const CopyPlan& plan) const noexcept;

      bool commit(const CopyPlan& plan) noexcept;

      // The plan's replacement matches view the results, region `a`, until it is applied. From
      // `origin`, a search typed a letter at a time starts where it began, and comes back there
      // when nothing matches.
      [[nodiscard]] tbc::view<std::optional<CopyPlan>, tbc::lt::a> search(tbc::view<std::span<const PaneMatch>, tbc::lt::a> results, const CopyGrid& grid, std::optional<CopyPoint> origin = std::nullopt) const;

      void onFrame(std::uint32_t previous_offset, const CopyGrid& grid) noexcept;

      void reset() noexcept;

    private:
      [[nodiscard]] std::optional<SetPaneViewport> viewport(std::uint32_t offset, const CopyGrid& grid) const noexcept;

      [[nodiscard]] CopyPlan plan(CopyState next, const CopyGrid& grid, CopyEffect effect = {}) const noexcept;

      std::optional<CopyState> state_;
      std::array<PaneMatch, maximum_matches> matches_{};
      std::size_t match_count_ = 0;
      std::uint64_t revision_ = 0;
      ClickTracker clicks_;
      std::uint64_t click_pane_ = 0;
      std::optional<std::uint64_t> gesture_;
    };

  }
}
