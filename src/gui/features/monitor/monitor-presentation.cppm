// What the window shows of the monitor's answers, in cells of the terminal's font: the columns of
// the process table, the text of each cell, the tree's guides and the rows of an owner listing.
export module telar.gui.features.monitor:presentation;

import std;

import telar.base.memory.containers;
import telar.wire.monitor;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::gui::features::monitor {

  // The processes of one owner in an owner listing, as the window keeps them.
  struct GroupRow {
    ProcessOwner owner = ProcessOwner::none;
    std::uint64_t pane_id = 0;
    std::uint32_t processes = 0;
    std::uint32_t cpu_permille = 0;
    std::uint64_t resident_bytes = 0;
  };

  // `limit` rows of the listing, from the row `offset`.
  struct Window {
    std::uint32_t offset = 0;
    std::uint16_t limit = 0;
  };

  enum class Column : std::uint8_t {
    pid,
    program,
    command,
    threads,
    user,
    memory,
    cpu,
    owner,
  };

  inline constexpr std::size_t column_count = 8;

  // A column of the process table: its first cell and its width in cells.
  struct ColumnSpan {
    Column column = Column::pid;
    std::uint16_t start = 0;
    std::uint16_t cells = 0;
    bool right = false;
  };

  using Columns = ds::Array<ColumnSpan, column_count>;

  // The table's columns across `cells` cells, in the order of Column and a cell apart. Every column
  // has the width of what it holds; the command takes what the others leave. A tree's program
  // column is wider, for the guides before each name.
  [[nodiscard]] Columns columns(std::uint16_t cells, MonitorLayout layout) noexcept;

  // Where a process stands in a tree: its depth, the guides of its path, its children and the
  // processes its folded branch hides.
  struct TreePlace {
    std::uint8_t depth = 0;
    std::uint32_t guides = 0;
    std::uint16_t children = 0;
    std::uint32_t folded = 0;
  };

  inline constexpr std::size_t cell_text_bytes = 1024;
  inline constexpr std::size_t short_text_bytes = 32;
  using CellText = runtime::FixedText<cell_text_bytes>;
  using ShortText = runtime::FixedText<short_text_bytes>;

  // `text` in `cells` cells, a cell per character: cut and ended with `mark` when it is longer,
  // padded on the left when `right`.
  [[nodiscard]] CellText fit(std::string_view text, std::uint16_t cells, bool right, std::string_view mark = "…");

  // An amount of bytes in at most six cells: 672K, 1.5M, 218M, 13.0G.
  [[nodiscard]] ShortText bytes(std::uint64_t value);

  // A share in thousandths, as a percent with one decimal: 13.6. The process table's, whose title
  // says it is a percent.
  [[nodiscard]] ShortText percent(std::uint32_t permille);

  // A share in thousandths, as a whole percent: 100%. Every other share the monitor shows.
  [[nodiscard]] ShortText wholePercent(std::uint32_t permille);

  enum class Tone : std::uint8_t {
    normal,
    warm,
    hot,
  };

  // How a process's share of one core reads: warm from a quarter of it, hot from 80 %.
  [[nodiscard]] Tone cpuTone(std::uint32_t permille) noexcept;

  // How a meter of what is taken reads: warm past 60 %, hot past 85 %.
  [[nodiscard]] Tone meterTone(double fraction) noexcept;

  // How a meter of what is left reads, such as the memory available: warm below 40 %, hot below 15 %.
  [[nodiscard]] Tone headroomTone(double fraction) noexcept;

  // A mount as the disks panel names it: its last directory, or / for the root, in at most 12 cells.
  [[nodiscard]] CellText mountLabel(std::string_view path);

  // The tree's guides before a process's name, then its branch's mark: ▸ folded, ▾ open.
  [[nodiscard]] CellText treePrefix(const TreePlace& place);

  // The command with the home directory written as ~ where a word, a value after = or :, or a
  // one-letter flag such as -I starts with it.
  [[nodiscard]] CellText abbreviateHome(std::string_view command, std::string_view home);

  // What the owner column says of a process: its owner, and the agent's or the tab's name.
  [[nodiscard]] CellText ownerText(ProcessOwner owner, std::string_view name);

  // A row of the window: a group's title in an owner listing, else a process by its place in the
  // listing. `index` is the group's or the process's.
  struct Slot {
    bool group = false;
    std::size_t index = 0;
  };

  // The rows of the listing: its processes, and in an owner listing a title for each group.
  [[nodiscard]] std::size_t rowCount(std::uint32_t matched, std::span<const GroupRow> groups, MonitorLayout layout) noexcept;

  [[nodiscard]] Slot slotAt(std::size_t row, std::span<const GroupRow> groups, MonitorLayout layout) noexcept;

  // The row of the listing's process `process`.
  [[nodiscard]] std::size_t rowOf(std::size_t process, std::span<const GroupRow> groups, MonitorLayout layout) noexcept;

  // The processes to ask for so the window holds the `visible` rows from `first`, with a screen of
  // them before and after.
  [[nodiscard]] Window windowAround(std::size_t first, std::uint16_t visible, std::span<const GroupRow> groups, MonitorLayout layout) noexcept;

}
