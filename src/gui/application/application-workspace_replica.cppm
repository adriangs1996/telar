export module telar.gui.application:workspace_replica;

import std;
import telar.tbc;

import telar.gui.features.terminal.graphics;
import telar.render.document;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import :fold_map;
import telar.base.memory.allocators;
import telar.gui.foundation.model;
import telar.base.ds;

// Interface: application/records.cppm
export {
  namespace telar::gui::application {

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
      explicit Pane(Memory& memory, std::uint64_t identity, features::terminal::graphics::GraphicsBudget& budget);

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
      features::terminal::graphics::GraphicsStore<Memory> graphics;
      ds::String<Memory> title;
      ds::String<Memory> cwd;
      ds::String<Memory> foreground;
      TerminalSize size = default_terminal_size;
      bool attached = false;
      bool attaching = false;
      bool exited = false;
      bool snapshot_requested = false;
      std::uint64_t acknowledged_frame = 0;
      PaneProgressState progress_state = PaneProgressState::remove;
      ds::Option<Byte> progress_percent;
      // The integrated shell's phase and the terminal's line discipline, for the command editor.
      PaneShell shell{};
      // The document the pane's program shows natively (`telar render`) while `document_shown`;
      // `document_version` changes whenever either does. `document_parts` gathers the parts of
      // revision `document_revision` until it is whole.
      render::Document<Memory> document;
      bool document_shown = false;
      std::uint64_t document_version = 0;
      std::uint64_t document_revision = 0;
      ds::Vec<Byte, Memory> document_parts;

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
        ds::Vec<Byte, Memory> parts;
        bool whole = false;
        bool shown = false;
      };

      // Oldest first, as the runtime keeps them; `inline_version` changes whenever one comes, goes,
      // moves or is measured.
      ds::Vec<InlineDocument, Memory> inline_documents;
      std::uint64_t inline_version = 0;
      // The repository the integrated shell works in; `branch` owns the text the message viewed.
      PaneGit git{};
      ds::String<Memory> git_branch;
      // The host a remote shell runs on and where it works there, which `shell.host` and
      // `shell.directory` view.
      ds::String<Memory> shell_host;
      ds::String<Memory> shell_directory;
      // The commands the integrated shell ran, oldest first; `blocks_text` owns their lines.
      ds::Vec<CommandBlock, Memory> blocks;
      ds::String<Memory> blocks_text;
      // The commands folded, by the stable number of their first row, and the rows their output
      // hides from the view.
      ds::Vec<std::uint64_t, Memory> folded;
      FoldMap<Memory> folds;
      // Changes whenever the rows the folds hide do.
      std::uint64_t fold_revision = 0;
      // The shown row at the top of the pane's view, folds counted, while the view draws its own
      // rows; the runtime's view need not start there.
      ds::Option<std::uint64_t> shown_top;
      // The row the live prompt starts on, as the view last showed it.
      ds::Option<std::uint32_t> live_prompt_row;
      // The folded blocks by index while renumbered rows wait for the blocks numbered anew.
      ds::Vec<std::size_t, Memory> refold;
    };

    // The application a tab shows: the pane's foreground, else the one the tab remembers for its
    // foreground pane. The name views either the tab or the pane, region `a`.
    template <Allocator Memory>
    [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> tabApplicationName(tbc::view<const Tab<Memory>&, tbc::lt::a> tab, tbc::view<std::type_identity_t<const Pane<Memory>*>, tbc::lt::a> pane) noexcept;

    extern template struct Pane<Memory>;
    extern template std::string_view tabApplicationName<Memory>(const Tab<Memory>& tab, const Pane<Memory>* pane) noexcept;

  }
}
