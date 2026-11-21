module;
#include "tbc/annotations.hpp"

export module telar.runtime.nvim.screen;

import std;
import telar.tbc;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.nvim;

// Interface: nvim/screen.cppm
export {
  namespace telar::runtime {

    // What one Neovim may make the runtime hold. A redraw that asks for more is refused, and the
    // editor that sent it closes: the runtime never grows with what a child process prints.
    struct NvimLimits {
      static constexpr std::uint32_t grids = 256;
      static constexpr std::uint32_t columns = 2048;
      static constexpr std::uint32_t rows = 1024;
      // The cells of all the grids together.
      static constexpr std::size_t cells = std::size_t{4} * 1024 * 1024;
      static constexpr std::uint32_t highlights = 65'535;
      static constexpr std::size_t clusters = 4096;
      static constexpr std::size_t links = 1024;
      static constexpr std::size_t link_bytes = 2048;
      static constexpr std::size_t modes = 64;
      // The text of one native surface: a command line, a message or a completion's items.
      static constexpr std::size_t surface_bytes = std::size_t{256} * 1024;
      static constexpr std::size_t completion_items = 4096;
      static constexpr std::size_t messages = 64;
      static constexpr std::size_t tabs = 256;
      static constexpr std::size_t path_bytes = 4096;
    };

    // One cell of a grid, eight bytes. A cell's text of up to four bytes, which holds every single
    // code point, is packed into `glyph` first byte lowest; a longer cluster is an index into the
    // screen's clusters.
    struct NvimCell {
      // `glyph` is an index into the screen's clusters.
      static constexpr unsigned cluster = 1U << 0U;
      // The left half of a double-width character, and the empty cell at its right.
      static constexpr unsigned wide = 1U << 1U;
      static constexpr unsigned continuation = 1U << 2U;
      // The bytes of the longest text a cell shows.
      static constexpr std::size_t text_capacity = 16;

      std::uint32_t glyph = ' ';
      std::uint16_t highlight = 0;
      std::uint8_t flags = 0;

      constexpr bool operator==(const NvimCell&) const noexcept = default;
    };

    struct NvimHighlight {
      // A color the highlight leaves to the default colors.
      static constexpr std::uint32_t unset = std::numeric_limits<std::uint32_t>::max();

      static constexpr std::uint16_t bold = 1U << 0U;
      static constexpr std::uint16_t italic = 1U << 1U;
      static constexpr std::uint16_t reverse = 1U << 2U;
      static constexpr std::uint16_t strikethrough = 1U << 3U;
      static constexpr std::uint16_t underline = 1U << 4U;
      static constexpr std::uint16_t undercurl = 1U << 5U;
      static constexpr std::uint16_t underdouble = 1U << 6U;
      static constexpr std::uint16_t underdotted = 1U << 7U;
      static constexpr std::uint16_t underdashed = 1U << 8U;
      static constexpr std::uint16_t dim = 1U << 9U;
      static constexpr std::uint16_t blink = 1U << 10U;
      static constexpr std::uint16_t conceal = 1U << 11U;
      static constexpr std::uint16_t overline = 1U << 12U;
      // The most a highlight blends with what is below it.
      static constexpr std::uint8_t opaque_blend = 100;

      std::uint32_t foreground = unset;
      std::uint32_t background = unset;
      std::uint32_t special = unset;
      std::uint16_t attributes = 0;
      // One more than the index of its link; zero without one.
      std::uint16_t link = 0;
      std::uint8_t blend = 0;

      constexpr bool operator==(const NvimHighlight&) const noexcept = default;
    };

    // A grid's size in cells.
    struct NvimExtent {
      std::uint32_t columns = 0;
      std::uint32_t rows = 0;
    };

    // A cell of a grid.
    struct NvimPoint {
      std::uint32_t row = 0;
      std::uint32_t column = 0;
    };

    // How many cells in a row take one text, and the highlight they are drawn with.
    struct NvimRun {
      std::uint16_t highlight = 0;
      std::uint32_t repeat = 1;
    };

    // A piece of a surface's text: where it starts in the text and how long it is.
    struct NvimSlice {
      std::uint32_t offset = 0;
      std::uint32_t size = 0;

      // The piece of `text` it names.
      [[nodiscard]] tbc::val_a<std::string_view> of(tbc::val_a<std::string_view> text) const;
    };

    enum class NvimAnchor : std::uint8_t {
      north_west,
      north_east,
      south_west,
      south_east,
    };

    struct NvimViewport {
      std::uint32_t top_line = 0;
      std::uint32_t bottom_line = 0;
      std::uint32_t cursor_line = 0;
      std::uint32_t cursor_column = 0;
      std::uint32_t line_count = 0;

      constexpr bool operator==(const NvimViewport&) const noexcept = default;
    };

    struct NvimMargins {
      std::uint16_t top = 0;
      std::uint16_t bottom = 0;
      std::uint16_t left = 0;
      std::uint16_t right = 0;

      constexpr bool operator==(const NvimMargins&) const noexcept = default;
    };

    // A grid Neovim destroyed, and the flush it went in.
    struct NvimRemoved {
      std::uint32_t grid = 0;
      std::uint64_t at = 0;
    };

    // Every `*_at` is the flush that last changed what it names: a client that has flush N is
    // sent what changed after N.
    struct NvimScreenGrid {
      explicit NvimScreenGrid(ConcurrentMemory& memory, std::uint32_t identity);

      [[nodiscard]] std::span<const NvimCell> row(std::uint32_t index) const noexcept;

      std::uint32_t id;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      ds::Vec<NvimCell, ConcurrentMemory> cells;
      ds::Vec<std::uint64_t, ConcurrentMemory> row_changed_at;
      // The scrolls of flush `scrolled_at`, in order; `scrolled_before` is the flush of the scroll
      // before those.
      ds::Vec<NvimScroll, ConcurrentMemory> scrolls;
      std::uint64_t scrolled_at = 0;
      std::uint64_t scrolled_before = 0;
      // When every row has to be sent again: the grid was made, resized or cleared.
      std::uint64_t reset_at = 0;
      // When a cell of it last changed.
      std::uint64_t cells_at = 0;

      NvimPlacement placement = NvimPlacement::hidden;
      NvimAnchor anchor = NvimAnchor::north_west;
      bool mouse_enabled = true;
      std::uint64_t window = 0;
      // A window's place on the default grid; a float's place Neovim computed, on the screen.
      std::int32_t start_row = 0;
      std::int32_t start_column = 0;
      std::uint16_t width = 0;
      std::uint16_t height = 0;
      // What a float is anchored to, as nvim_open_win() describes.
      std::uint32_t anchor_grid = 0;
      double anchor_row = 0;
      double anchor_column = 0;
      std::uint32_t z_index = 0;
      std::uint32_t composition_index = 0;
      std::uint64_t placed_at = 0;

      NvimViewport viewport;
      // The lines its top line has moved since the grid was made, summed: a client subtracts
      // what it last heard and animates the difference.
      std::int64_t scrolled_lines = 0;
      NvimMargins margins;
      std::uint64_t viewport_at = 0;
      // A float's frame as its window's own configuration gives it: the sides Neovim draws a
      // border on, as top 1, right 2, bottom 4 and left 8, its title and its footer.
      std::uint8_t border = 0;
      ds::String<ConcurrentMemory> title;
      ds::String<ConcurrentMemory> footer;
      // The `placed_at` its frame was last asked for.
      std::uint64_t framed_for = 0;
    };

    class NvimScreen;

    // The text a screen shows, its windows and floats laid over the default grid: at most `rows`
    // rows from the top, each without the blanks it ends with, appended to `text` up to `limit`
    // bytes. False when it did not all fit.
    bool composeText(const NvimScreen& screen, std::uint16_t rows, ds::String<ConcurrentMemory>& text, std::size_t limit);

    enum class NvimCursorShape : std::uint8_t {
      block,
      horizontal,
      vertical,
    };

    struct NvimMode {
      static constexpr std::uint8_t whole_cell = 100;

      NvimCursorShape shape = NvimCursorShape::block;
      std::uint8_t cell_percentage = whole_cell;
      std::uint16_t blink_wait = 0;
      std::uint16_t blink_on = 0;
      std::uint16_t blink_off = 0;
      std::uint16_t attribute = 0;

      constexpr bool operator==(const NvimMode&) const noexcept = default;
    };

    struct NvimCursor {
      std::uint32_t grid = 1;
      std::uint16_t row = 0;
      std::uint16_t column = 0;
      // Neovim asked to stop drawing it (busy_start).
      bool hidden = false;
      std::uint64_t changed_at = 0;
    };

    // A run of a surface's text drawn with one highlight.
    struct NvimChunk {
      std::uint32_t offset = 0;
      std::uint32_t size = 0;
      std::uint16_t highlight = 0;
    };

    struct NvimStyledText {
      explicit NvimStyledText(ConcurrentMemory& memory);

      void clear() noexcept;
      // Appends a run, cut at what a surface may hold.
      void append(std::string_view added, std::uint16_t highlight);
      [[nodiscard]] std::string_view view() const noexcept;

      ds::Vec<char, ConcurrentMemory> text;
      ds::Vec<NvimChunk, ConcurrentMemory> chunks;
    };

    // The command line Neovim edits at one level, the innermost being the one shown.
    struct NvimCommandLine {
      explicit NvimCommandLine(ConcurrentMemory& memory);

      NvimStyledText content;
      ds::String<ConcurrentMemory> prompt;
      // ':' '/' '?' and the like; zero for a prompt of input().
      char first = 0;
      // The character shown at the cursor while a key is pending, zero without one.
      char special = 0;
      bool special_shifts = false;
      std::uint32_t position = 0;
      std::uint32_t indent = 0;
      std::uint32_t level = 0;
      bool visible = false;
      // The lines of a block shown above it, each ended by a newline.
      NvimStyledText block;
      std::uint64_t changed_at = 0;
    };

    struct NvimCompletion {
      struct Item {
        NvimSlice word;
        NvimSlice kind;
        NvimSlice menu;
        NvimSlice info;
      };

      explicit NvimCompletion(ConcurrentMemory& memory);

      ds::Vec<char, ConcurrentMemory> text;
      ds::Vec<Item, ConcurrentMemory> items;
      std::int32_t selected = -1;
      std::int32_t row = 0;
      std::int32_t column = 0;
      // The grid the anchor is on; -1 anchors it to the command line.
      std::int32_t grid = 0;
      bool visible = false;
      // The items changed at `items_at`; the selection alone at `changed_at`.
      std::uint64_t items_at = 0;
      std::uint64_t changed_at = 0;
    };

    struct NvimMessage {
      explicit NvimMessage(ConcurrentMemory& memory);

      NvimStyledText content;
      // Neovim's id for it: a message with the id of a visible one replaces it.
      std::uint64_t id = 0;
      NvimMessageKind kind = NvimMessageKind::plain;
      bool history = false;
    };

    struct NvimMessages {
      explicit NvimMessages(ConcurrentMemory& memory);

      // The visible messages, oldest first.
      ds::Vec<NvimMessage, ConcurrentMemory> visible;
      // 'showmode', 'showcmd' and 'ruler', each empty when hidden.
      NvimStyledText mode;
      NvimStyledText command;
      NvimStyledText ruler;
      // The entries of :messages, each ended by a newline, when Neovim last showed them.
      NvimStyledText history;
      std::uint64_t history_at = 0;
      std::uint64_t changed_at = 0;
    };

    struct NvimTabs {
      struct Entry {
        std::uint64_t handle = 0;
        NvimSlice name;
      };

      explicit NvimTabs(ConcurrentMemory& memory);

      ds::Vec<char, ConcurrentMemory> text;
      ds::Vec<Entry, ConcurrentMemory> tabs;
      ds::Vec<Entry, ConcurrentMemory> buffers;
      std::uint64_t current_tab = 0;
      std::uint64_t current_buffer = 0;
      std::uint64_t changed_at = 0;
    };

    // What Neovim has drawn, as its redraw events left it. A client is shown it only between a
    // flush and the next event: `settled()`.
    class NvimScreen {
    public:
      explicit NvimScreen(ConcurrentMemory& memory);

      // --- What the redraw events change. Each returns false for what the limits refuse.

      bool resize(std::uint32_t grid, NvimExtent size);
      void clear(std::uint32_t grid);
      void destroy(std::uint32_t grid);

      // Starts writing cells at a row and column of a grid; false for a place outside it.
      bool line(std::uint32_t grid, NvimPoint start) noexcept;
      // Puts `text` in the cells of a run from the place `line` gave, moving it; false past the
      // row's end.
      bool put(std::string_view text, NvimRun run);

      bool scroll(std::uint32_t grid, NvimScroll scroll);
      void moveCursor(std::uint32_t grid, NvimPoint place) noexcept;
      void hideCursor(bool hidden) noexcept;
      void defaultColors(std::uint32_t foreground, std::uint32_t background, std::uint32_t special) noexcept;
      bool highlight(std::uint32_t id, NvimHighlight value);
      // The index of a link's URL, one more than where it is kept; zero once the links are full.
      [[nodiscard]] std::uint16_t link(std::string_view url);

      // Null when the grid was never sized and there is no room for another.
      [[nodiscard]] NvimScreenGrid* place(std::uint32_t grid, NvimPlacement placement);
      void hide(std::uint32_t grid) noexcept;
      void viewport(std::uint32_t grid, const NvimViewport& viewport, std::int64_t scroll_delta) noexcept;
      void margins(std::uint32_t grid, NvimMargins margins) noexcept;
      // The frame of the float that shows `window`. False when no float shows it, or it has
      // that frame already.
      bool decorate(std::uint64_t window, std::uint8_t border, std::string_view title, std::string_view footer);
      // A float placed since its frame was last asked for: its window, which then counts as
      // asked, or zero when there is none.
      [[nodiscard]] std::uint64_t nextUnframed() noexcept;

      bool mode(std::size_t index, NvimMode mode);
      void truncateModes(std::size_t count) noexcept;
      void currentMode(std::size_t index, std::string_view name);
      void title(std::string_view title);
      void directory(std::string_view path);
      void mouse(bool enabled) noexcept;

      [[nodiscard]] NvimCommandLine& commandLineMut() noexcept;
      [[nodiscard]] NvimCompletion& completionMut() noexcept;
      [[nodiscard]] NvimMessages& messagesMut() noexcept;
      [[nodiscard]] NvimTabs& tabsMut() noexcept;

      // Ends a redraw: what changed since the last flush becomes what clients are shown.
      void flush() noexcept;

      // --- What delivery reads.

      // The flush a change made now belongs to.
      [[nodiscard]] std::uint64_t stamp() const noexcept;
      // The last flush; zero before the first.
      [[nodiscard]] std::uint64_t flushed() const noexcept;
      // No event since the last flush: the screen is what Neovim means to show.
      [[nodiscard]] bool settled() const noexcept;

      [[nodiscard]] std::span<const ds::Box<NvimScreenGrid, ConcurrentMemory>> grids() const noexcept;
      [[nodiscard]] const NvimScreenGrid* grid(std::uint32_t id) const noexcept;
      // The grids Neovim destroyed, oldest first, each with the flush it went in: a client is
      // told the ones that went after the frame it has. Only the last of them are kept; a
      // client that has a frame before `removedForgottenAt` is sent the screen whole instead.
      [[nodiscard]] std::span<const NvimRemoved> removed() const noexcept;
      [[nodiscard]] std::uint64_t removedForgottenAt() const noexcept;

      [[nodiscard]] const NvimHighlight& highlightOf(std::uint16_t id) const noexcept;
      [[nodiscard]] std::string_view linkOf(const NvimHighlight& highlight) const noexcept;
      [[nodiscard]] std::uint64_t highlightsAt() const noexcept;
      [[nodiscard]] NvimHighlight defaults() const noexcept;
      // Copies a cell's text to `destination` and says how many bytes it is; none for the right
      // half of a wide character.
      std::size_t copyText(const NvimCell& cell, std::span<char, NvimCell::text_capacity> destination) const noexcept;

      [[nodiscard]] const NvimCursor& cursor() const noexcept;
      [[nodiscard]] std::span<const NvimMode> modes() const noexcept;
      [[nodiscard]] std::size_t currentMode() const noexcept;
      [[nodiscard]] std::string_view modeName() const noexcept;
      [[nodiscard]] std::uint64_t modeAt() const noexcept;
      [[nodiscard]] std::string_view title() const noexcept;
      [[nodiscard]] std::uint64_t titleAt() const noexcept;
      [[nodiscard]] std::string_view directory() const noexcept;
      [[nodiscard]] std::uint64_t directoryAt() const noexcept;
      [[nodiscard]] bool mouseEnabled() const noexcept;

      [[nodiscard]] const NvimCommandLine& commandLine() const noexcept;
      [[nodiscard]] const NvimCompletion& completion() const noexcept;
      [[nodiscard]] const NvimMessages& messages() const noexcept;
      [[nodiscard]] const NvimTabs& tabs() const noexcept;

      // Clusters a redraw could not keep: its cells show a replacement until Neovim redraws.
      [[nodiscard]] bool takeClusterOverflow() noexcept;

    private:
      struct Cluster {
        ds::Array<char, NvimCell::text_capacity> bytes{};
        std::uint8_t size = 0;
      };

      [[nodiscard]] ds::Option<std::size_t> indexOf(std::uint32_t id) const noexcept;
      [[nodiscard]] NvimScreenGrid* find(std::uint32_t id) noexcept;
      NvimScreenGrid& add(std::uint32_t id);
      [[nodiscard]] std::uint32_t intern(std::string_view text);
      void dropClusters() noexcept;
      // Replaces the clusters of one row, which is then sent again.
      static bool dropClusters(std::span<NvimCell> row) noexcept;
      // Marks every row of a grid to be sent again, as changed at `stamp`.
      static void reset(NvimScreenGrid& grid, std::uint64_t stamp) noexcept;
      void touch() noexcept;

      ConcurrentMemory& memory_;
      ds::Vec<ds::Box<NvimScreenGrid, ConcurrentMemory>, ConcurrentMemory> grids_;
      // Where the last lookup found its grid: a redraw names the same one many times in a row.
      mutable std::size_t recent_ = 0;
      std::size_t cell_count_ = 0;
      // Where `put` writes next: the grid `line` found, by its place in grids_, and the cell.
      std::size_t put_grid_ = 0;
      NvimPoint put_;

      ds::Vec<NvimHighlight, ConcurrentMemory> highlights_;
      ds::Vec<ds::String<ConcurrentMemory>, ConcurrentMemory> links_;
      ds::Vec<Cluster, ConcurrentMemory> clusters_;
      // Open addressing over clusters_: one more than a cluster's index, zero for an empty slot.
      ds::Vec<std::uint16_t, ConcurrentMemory> cluster_slots_;
      NvimHighlight defaults_;
      std::uint64_t highlights_at_ = 0;
      bool cluster_overflow_ = false;

      NvimCursor cursor_;
      ds::Vec<NvimMode, ConcurrentMemory> modes_;
      std::size_t current_mode_ = 0;
      ds::String<ConcurrentMemory> mode_name_;
      std::uint64_t mode_at_ = 0;
      ds::String<ConcurrentMemory> title_;
      std::uint64_t title_at_ = 0;
      ds::String<ConcurrentMemory> directory_;
      std::uint64_t directory_at_ = 0;
      bool mouse_ = false;

      NvimCommandLine command_line_;
      NvimCompletion completion_;
      NvimMessages messages_;
      NvimTabs tabs_;

      ds::Vec<NvimRemoved, ConcurrentMemory> removed_;
      std::uint64_t removed_forgotten_at_ = 0;
      std::uint64_t flushed_ = 0;
      bool settled_ = true;
    };

  }
}
