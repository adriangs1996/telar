// The tabs and panes as ui drives them: selecting, creating, moving, renaming and closing tabs,
// splitting, focusing, resizing and closing panes, going to another workspace, and the types each
// window draws the tab strip and the panes' chrome and motions with.
export module telar.gui.application:workbench;

import std;

import :session;
import :workspace_replica;
import telar.gui.features.workbench;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::gui::application::workbench {

  using features::workbench::AttentionFades;
  using features::workbench::AttentionFrame;
  using features::workbench::PaneAttentionGeometry;
  using features::workbench::PaneAttentionKey;
  using features::workbench::PaneDecorationGeometry;
  using features::workbench::PaneHeaderGeometry;
  using features::workbench::PaneHeaderMeasurements;
  using features::workbench::PaneHeaderMetrics;
  using features::workbench::PaneMotions;
  using features::workbench::PaneMotionSlot;
  using features::workbench::PaneProgressPresentation;
  using features::workbench::PaneStatusChip;
  using features::workbench::ProgressAnimation;
  using features::workbench::ProgressMotion;
  using features::workbench::ProgressSample;
  using features::workbench::TabCardInput;
  using features::workbench::TabCardMotion;
  using features::workbench::TabCardMotions;
  using features::workbench::TabCardPlacement;
  using features::workbench::TabCardPose;
  using features::workbench::TabDrag;
  using features::workbench::TabDragMove;
  using features::workbench::TabDropSlot;
  using features::workbench::TabDropSlots;
  using features::workbench::TabDropSurface;
  using features::workbench::TabDropTarget;
  using features::workbench::TabMotion;
  using features::workbench::TabMotionFrame;
  using features::workbench::TabMotions;
  using features::workbench::TabMotionSlot;
  using features::workbench::TabStripGeometry;
  using features::workbench::WorkspaceMark;

  // ---- the area the panes share -------------------------------------------------------------

  // Where the panes go on the window and how many cells they have.
  [[nodiscard]] const WorkbenchGeometry& geometry(const Session& session) noexcept;

  void setGeometry(Session& session, WorkbenchGeometry geometry) noexcept;

  // The attachment shelf reserves `reservation` at the bottom of every tab; the panes on screen
  // take the sizes it leaves them.
  void reserveBottom(Session& session, ds::Option<PaneBottomReservation> reservation);

  // ---- tabs ---------------------------------------------------------------------------------

  void selectTab(Session& session, TabLocation location);

  // The tab at `index` in the order the active workspace shows its tabs.
  void selectTabAt(Session& session, std::size_t index);

  // The tab `offset` places from the active one, wrapping around.
  void selectTabBeside(Session& session, std::int32_t offset);

  TabCreationOutcome createTab(Session& session, std::string_view label = {});

  TabCreationOutcome createCommandTab(Session& session, const runtime::config::CommandTabView& command);

  // Renames the active tab.
  void renameTab(Session& session, std::string_view label);

  void closeTab(Session& session, TabLocation location);

  // Moves the active tab one place toward `direction`, or beside `relative_to`.
  void moveTab(Session& session, TabMoveDirection direction, ds::Option<std::uint64_t> relative_to = {});

  // The user dropped a tab they dragged; false when the move cannot be asked for now.
  [[nodiscard]] bool dropTab(Session& session, const TabDragMove& move);

  // Whether a tab is being created, renamed, moved or closed.
  [[nodiscard]] bool tabOperationPending(const Session& session) noexcept;

  // ---- panes --------------------------------------------------------------------------------

  void focusPane(Session& session, std::uint64_t pane_id);

  // Focuses the pane next to the focused one toward `direction`.
  void focusToward(Session& session, PaneDirection direction);

  // As focusToward, but a pane running nvim gets the keys that move between its windows.
  void navigate(Session& session, PaneDirection direction);

  // Moves the focused pane's border toward `direction`; false when it cannot move.
  bool resizeToward(Session& session, PaneDirection direction);

  // The divider of layout node `node` of the active tab and the point, in the pixels of the
  // session's geometry, a person drags it to. `commit` ends the drag.
  struct DividerDrag {
    std::size_t node = 0;
    double x = 0;
    double y = 0;
    bool commit = false;
  };

  // Moves the divider to the point of the drag. A drag that ends keeps the layout for the next
  // connection, as any other change of it does. False when the divider did not move.
  bool dragDivider(Session& session, const DividerDrag& drag);

  // Splits the focused pane along `axis`; false when it cannot be split now.
  bool split(Session& session, ClientLayoutAxis axis);

  // Splits the focused pane along `axis`, the new pane starting in `directory` instead of where
  // the focused one works.
  bool splitAt(Session& session, ClientLayoutAxis axis, std::string_view directory);

  // Splits the focused pane along `axis`, the new pane being an editor on `files`, or on an
  // empty buffer without any. False when the session cannot: its runtime runs no editors, or a
  // pane is still being opened or closed.
  // Where an editor's cursor starts in the first of its files, counted from one; zero leaves
  // it to Neovim.
  struct EditorStart {
    std::uint32_t line = 0;
    std::uint32_t column = 0;
  };

  bool splitEditor(Session& session, ClientLayoutAxis axis, std::span<const std::string_view> files = {}, EditorStart start = {});

  // A tab of its own for an editor on `files`.
  TabCreationOutcome createEditorTab(Session& session, std::span<const std::string_view> files = {});

  bool closePane(Session& session, std::uint64_t pane_id);

  void toggleFullscreen(Session& session);

  // Tells the runtime the layout of every loaded tab, which it gives back when the session restores.
  void retainLayout(Session& session);

  // ---- workspaces ---------------------------------------------------------------------------

  // Goes to `location` at the pane it was left on; false when it cannot be asked for now.
  bool selectWorkspace(Session& session, WorkspaceLocation location);

  // The workspace at `index` among the projects.
  void selectWorkspaceAt(Session& session, std::size_t index);

  // Without a directory the workspace starts where the focused pane is.
  void createWorkspace(Session& session, WorkspaceDraft draft);

  // Renames the active workspace.
  void renameWorkspace(Session& session, std::string_view name);

  bool openWorktree(Session& session, std::uint64_t identity);

  // Goes back to the workspace the active worktree was made from.
  bool leaveWorktree(Session& session);

  // Asks the runtime to forget each worktree that is gone; how many it asked for.
  std::size_t forgetGoneWorktrees(Session& session);

  // Splits pane `pane_id` beside a new pane running `arguments`; throws when it cannot.
  void launchSplit(Session& session, std::uint64_t pane_id, std::span<const std::string_view> arguments);
}

// What the session's routing and the other use cases hand the workbench; ui never calls these.
namespace telar::gui::application::workbench {

  // Shows pane `pane_id`, at `generation` when one is given: here when it is in the active
  // workspace, else by opening the workspace it lives in.
  void visit(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> generation = {});

  // Opens a tab, or the first pane, running `arguments` from the default launch's directory.
  void launchTab(Session& session, std::span<const std::string_view> arguments);

  // The tab at `location` focuses `pane_id`, which the graphics of a paused pane hear.
  void setFocus(Session& session, TabLocation location, std::uint64_t pane_id);

  // The panes of the active tab take the sizes their places leave them.
  void resizeVisible(Session& session);

  // A split of pane `pane_id` in the tab at `location` failed: the pane takes back its size.
  void recoverSplit(Session& session, TabLocation location, std::uint64_t pane_id);

  // The pane next to the focused one toward `direction`; 0 when there is none.
  [[nodiscard]] std::uint64_t neighbor(Session& session, PaneDirection direction);

  // The active tab's layout as a token the CLI prints; it views the session's response to the
  // command, valid until the next one.
  [[nodiscard]] std::string_view exportLayout(Session& session);

  // The active tab takes the layout of `token`, which must hold the same panes.
  void importLayout(Session& session, std::string_view token);

}
