export module telar.gui.application.workspace_replica;

import std;
import telar.tbc;

import telar.gui.graphics.texture_cache;
import telar.render.document;
import telar.gui.core.primitives;
import telar.gui.terminal.row_cache;
import telar.gui.terminal.screen;
import telar.wire.pane_io;
import telar.wire.vocabulary;
export import :fold_map;
import telar.base.memory.allocators;
import telar.gui.model.records;

// Interface: application/records.cppm
export {
  namespace telar::gui {

    enum class PaneInputSource : std::uint8_t {
      keyboard,
      key_release,
      mouse,
      terminal_report,
    };

    enum class ScrollDirection : std::uint8_t {
      up,
      down,
    };

    enum class TabCreationOutcome : std::uint8_t {
      unavailable,
      requested,
      busy,
    };

    struct WorkspaceDraft {
      std::string_view name;
      std::string_view path;
      bool create_directory = false;
    };

    struct PaneScrollDelta {
      std::uint64_t pane_id = 0;
      std::int64_t rows = 0;
    };

    template <Allocator Memory>
    struct Pane {
      explicit Pane(Memory& memory, std::uint64_t identity, GraphicsBudget& budget);

      std::uint64_t id;
      std::uint64_t generation = 0;
      std::uint64_t attachment_generation = 0;
      TabLocation location;
      Screen<Memory> screen;
      // Rows of the scrollback beyond the screen, for scrolled and folded views, numbered as the
      // runtime's last `PaneScrollback` said: `scrollback_trimmed` rows dropped from the top under
      // `scrollback_generation`, 0 before it said. `scrollback_dropped` counts the rows dropped
      // since the view last took them.
      RowCache<Memory> rows;
      std::uint64_t scrollback_generation = 0;
      std::uint64_t scrollback_trimmed = 0;
      std::uint64_t scrollback_dropped = 0;
      // Counts the views the client asked the runtime for, so a view can tell a move it asked for
      // from a frame that still shows an older view.
      std::uint64_t viewport_requests = 0;
      GraphicsStore<Memory> graphics;
      String<Memory> title;
      String<Memory> cwd;
      String<Memory> foreground;
      TerminalSize size = default_terminal_size;
      bool attached = false;
      bool attaching = false;
      bool exited = false;
      bool snapshot_requested = false;
      std::uint64_t acknowledged_frame = 0;
      PaneProgressState progress_state = PaneProgressState::remove;
      std::optional<Byte> progress_percent;
      // The integrated shell's phase and the terminal's line discipline, for the command editor.
      PaneShell shell{};
      // The document the pane's program shows natively (`telar render`) while `document_shown`;
      // `document_version` changes whenever either does. `document_parts` gathers the parts of
      // revision `document_revision` until it is whole.
      render::Document<Memory> document;
      bool document_shown = false;
      std::uint64_t document_version = 0;
      std::uint64_t document_revision = 0;
      Vector<Byte, Memory> document_parts;

      // A document that stands for `rows` rows of the scrollback from stable row `first_row`, as
      // `generation` numbers them, drawn in their place once whole and valid. The view measures it
      // in `view_rows` rows, none until it did.
      struct InlineDocument {
        InlineDocument(Memory& memory, std::uint64_t identity);

        std::uint64_t id;
        std::uint64_t generation = 0;
        std::uint64_t first_row = 0;
        std::uint32_t rows = 0;
        std::uint32_t view_rows = 0;
        render::Document<Memory> document;
        Vector<Byte, Memory> parts;
        bool whole = false;
        bool shown = false;
      };

      // Oldest first, as the runtime keeps them; `inline_version` changes whenever one comes, goes,
      // moves or is measured.
      std::vector<InlineDocument> inline_documents;
      std::uint64_t inline_version = 0;
      // The repository the integrated shell works in; `branch` owns the text the message viewed.
      PaneGit git{};
      std::string git_branch;
      // The host a remote shell runs on and where it works there, which `shell.host` and
      // `shell.directory` view.
      std::string shell_host;
      std::string shell_directory;
      // The commands the integrated shell ran, oldest first; `blocks_text` owns their lines.
      std::vector<CommandBlock> blocks;
      std::string blocks_text;
      // The commands folded, by the stable number of their first row, and the rows their output
      // hides from the view.
      std::vector<std::uint64_t> folded;
      FoldMap<> folds;
      // Changes whenever the rows the folds hide do.
      std::uint64_t fold_revision = 0;
      // The shown row at the top of the pane's view, folds counted, while the view draws its own
      // rows; the runtime's view need not start there.
      std::optional<std::uint64_t> shown_top;
      // The row the live prompt starts on, as the view last showed it.
      std::optional<std::uint32_t> live_prompt_row;
      // The folded blocks by index while renumbered rows wait for the blocks numbered anew.
      std::vector<std::size_t> refold;
    };

    // The application a tab shows: the pane's foreground, else the one the tab remembers for its
    // foreground pane. The name views either the tab or the pane, region `a`.
    template <Allocator Memory>
    [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> tabApplicationName(tbc::view<const Tab<Memory>&, tbc::lt::a> tab, tbc::view<std::type_identity_t<const Pane<Memory>*>, tbc::lt::a> pane) noexcept;

    extern template struct Pane<Memory>;
    extern template std::string_view tabApplicationName<Memory>(const Tab<Memory>& tab, const Pane<Memory>* pane) noexcept;

  }
}
