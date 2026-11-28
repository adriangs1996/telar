// The command history as ui drives it: search, page, select and inspect commands, and run,
// copy, visit or delete one.
export module telar.gui.application:history;

import std;

import :session;
import telar.gui.features.history;
import telar.wire.history;
import telar.base.ds;

export namespace telar::gui::application::history {

  using features::history::history_filter_target_count;
  using features::history::history_inspection_action_count;
  using features::history::HistoryActionCapture;
  using features::history::HistoryActionLabel;
  using features::history::HistoryActionPosition;
  using features::history::HistoryActions;
  using features::history::HistoryActionSurface;
  using features::history::HistoryActionTarget;
  using features::history::HistoryCard;
  using features::history::HistoryCardAction;
  using features::history::HistoryCardLine;
  using features::history::HistoryCardMetrics;
  using features::history::HistoryChip;
  using features::history::HistoryChips;
  using features::history::HistoryChoice;
  using features::history::HistoryCommandLine;
  using features::history::HistoryCommandMetrics;
  using features::history::HistoryContextEntry;
  using features::history::HistoryEmpty;
  using features::history::HistoryEmptyGeometry;
  using features::history::HistoryEmptyMeasurements;
  using features::history::HistoryEmptyOptions;
  using features::history::HistoryExpansion;
  using features::history::HistoryFactData;
  using features::history::HistoryFacts;
  using features::history::HistoryFactSink;
  using features::history::HistoryFilterAction;
  using features::history::HistoryFilterChipGeometry;
  using features::history::HistoryFilterChipMeasurements;
  using features::history::HistoryFilterGeometry;
  using features::history::HistoryFilterKey;
  using features::history::HistoryFilterKeys;
  using features::history::HistoryFilterLabels;
  using features::history::HistoryFilterMeasurements;
  using features::history::HistoryFilters;
  using features::history::HistoryFooter;
  using features::history::HistoryFooterAction;
  using features::history::HistoryFooterGeometry;
  using features::history::HistoryFooterHint;
  using features::history::HistoryFooterIdentity;
  using features::history::HistoryFooterMeasurements;
  using features::history::HistoryFooterOptions;
  using features::history::HistoryHover;
  using features::history::HistoryHoverIdentity;
  using features::history::HistoryHoverTarget;
  using features::history::HistoryInspectionAction;
  using features::history::HistoryInspectionDocument;
  using features::history::HistoryInspectionEntry;
  using features::history::HistoryInspectionFacts;
  using features::history::HistoryInspectionGeometry;
  using features::history::HistoryInspectionIdentity;
  using features::history::HistoryInspectionLine;
  using features::history::HistoryInspectionLines;
  using features::history::HistoryKeyStyle;
  using features::history::HistoryLabels;
  using features::history::HistoryLimits;
  using features::history::HistoryLoad;
  using features::history::HistoryLoading;
  using features::history::HistoryMarks;
  using features::history::HistoryMetaGeometry;
  using features::history::HistoryMetaMeasurements;
  using features::history::HistoryModalGeometry;
  using features::history::HistoryModalMetrics;
  using features::history::HistoryModes;
  using features::history::HistoryPage;
  using features::history::HistoryPath;
  using features::history::HistoryPhase;
  using features::history::HistoryPins;
  using features::history::HistoryPosition;
  using features::history::HistoryRow;
  using features::history::HistoryRowGeometry;
  using features::history::HistoryRowMeasurements;
  using features::history::HistoryRunFacts;
  using features::history::HistoryRunStats;
  using features::history::HistoryScroll;
  using features::history::HistoryScrollPosition;
  using features::history::HistoryScrollState;
  using features::history::HistoryScrollSurface;
  using features::history::HistorySearch;
  using features::history::HistorySelectionMotion;
  using features::history::HistoryText;
  using features::history::HistoryTyping;
  using features::history::HistoryView;
  using features::history::HistoryViewState;
  using features::history::PlainText;

  // Searches the history for `query`, each command once at its newest run that passes the
  // filters; without filters, as the configuration shows agents' commands.
  void search(Session& session, std::string_view query);

  // `sampled` is the time a `since:` chip counts back from.
  void search(Session& session, std::string_view query, HistoryFilters filters, CalendarSample sampled = {});

  // Whether the runtime tells the window of each change to the history, which reads the page
  // anew: while the panel is open. A runtime before cqp00015 is not asked.
  void watch(Session& session, bool watching);

  // The next older or newer page; false at the search's end or while a page loads.
  bool page(Session& session, HistoryPage direction);

  [[nodiscard]] bool loading(const Session& session) noexcept;

  [[nodiscard]] HistoryView view(const Session& session) noexcept;

  // Shows `message` in place of the page.
  void report(Session& session, std::string_view message);

  // Selects row `row` and reads what its command and output need.
  void select(Session& session, std::size_t row);

  // Opens or closes the inspection of the selected command.
  void inspect(Session& session, bool enabled);

  // Runs command `entry_id` again at the focused pane, or only writes it there when `alternate`
  // and the configuration say so.
  void paste(Session& session, std::uint64_t entry_id, bool alternate = false);

  // Copies command `entry_id` to the session's clipboard.
  void copy(Session& session, std::uint64_t entry_id);

  // Goes to the pane command `entry_id` ran in.
  void visit(Session& session, std::uint64_t entry_id);

  // Deletes command `entry_id` from the history.
  void remove(Session& session, std::uint64_t entry_id);

  // Takes command `entry_id`'s row away while its delete can still be taken back; a delete that
  // waited so before goes now.
  void hide(Session& session, std::uint64_t entry_id);

  // Takes the delete waiting back and reads the page anew, which shows its row again.
  void undo(Session& session);

  // Sends the delete waiting, which can no longer be taken back.
  void commit(Session& session);

  // Runs `command`, one the person pinned, at the focused pane, or only writes it there when
  // `alternate` and the configuration say so.
  void pasteCommand(Session& session, std::string_view command, bool alternate = false);

  // Marks command `entry_id` to be used with the others marked, or unmarks it.
  void mark(Session& session, std::uint64_t entry_id);

  void clearMarks(Session& session) noexcept;

  // Runs the commands marked, in the order they were marked, at the focused pane as one line
  // joined by &&, which stops at the first that fails; or only writes them there one per line
  // when `alternate` and the configuration say so.
  void pasteMarked(Session& session, bool alternate = false);

  // Changes the focused pane's shell to the directory command `entry_id` ran in.
  void enter(Session& session, std::uint64_t entry_id);

  // Opens a pane beside the focused one in the directory command `entry_id` ran in.
  void open(Session& session, std::uint64_t entry_id);

  // Reads the page shown anew from a new insertion boundary, the selection kept: what changed
  // since, as a command that was running and ended, shows.
  void refresh(Session& session);

}

// What the session's routing hands the history; ui never calls these.
namespace telar::gui::application::history {

  Change receive(Session& session, const HistoryResults& results);

  Change receive(Session& session, const HistoryOutput& output);

  Change receive(Session& session, const HistoryCommandStats& stats);

  Change receive(Session& session, const HistoryPruned& pruned);

  Change receive(Session& session, const HistoryChanged& changed);

  // A failed request: none when it is not one of the history's.
  ds::Option<Change> fail(Session& session, std::uint64_t request_id, std::string_view message);

}
