module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.text_reader;

import std;
import telar.ghostty.vt;
import telar.tbc;

import telar.runtime.diagnostics.runtime_counters;

import telar.runtime.diagnostics.operation;
import telar.runtime.terminal.graphics_storage;

import telar.runtime.terminal.osc_scanner;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.pane_io;
import telar.config.runtime;
import telar.runtime.terminal.control;
import telar.runtime.terminal.control.engine;
import telar.runtime.terminal.control.clipboard;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;
import telar.base.ds;

namespace telar::runtime {

  // The colors of the 256-color palette.
  inline constexpr std::size_t palette_colors = 256;

}

// Interface: terminal/text_metadata.cppm
export {
  namespace telar::runtime {

    // Links and runs of the text read, which a view lends with the row flags it is given: region `a`
    // holds both, as `&'a self` and an argument of the same lifetime would.
    class TextMetadataCapture {
    public:
      explicit TextMetadataCapture(tbc::mut_a<ConcurrentMemory> memory);

      [[nodiscard]] tbc::val_a<TextMetadata> view(tbc::val_a<std::span<const Byte>> row_flags) const noexcept;

      // Not inlined: Terminal::refresh runs on every frame and captures only when rows with links
      // changed; the link table in its frame would put every frame's calls on deeper stack pages.
      [[gnu::noinline]] void capture(GhosttyRenderState state, GhosttyRenderStateRowIterator iterator, std::span<const Byte> row_flags, std::uint16_t columns);

    private:
      struct Identity {
        std::string_view uri;
        std::string_view explicit_id;
        std::uint64_t implicit_id = 0;

        bool operator==(const Identity&) const = default;
      };

      static constexpr std::size_t maximum_links = 256;
      static constexpr std::size_t maximum_runs = 2048;
      static constexpr std::size_t maximum_uri_bytes = 65536;
      static constexpr std::size_t maximum_uri_length = 4096;

      // The links one capture has seen. Their texts view the terminal's hyperlinks, which stay put for
      // that capture only, so the table lives in it.
      struct LinkTable {
        tbc::val_a<ds::Array<Identity, maximum_links>> identities{};
        ds::Array<std::uint16_t, maximum_links * 2> slots{};
      };

      // The text is the terminal's, which the string only points at, as a raw pointer lends no borrow.
      static tbc::val_a<std::string_view> stringView(tbc::val_a<GhosttyString> value) noexcept;

      static std::size_t hash(const Identity& identity) noexcept;

      ds::Option<std::uint16_t> intern(tbc::mut_a<LinkTable> table, tbc::val_a<Identity> identity);

      void captureRow(LinkTable& table, GhosttyRenderStateRowIterator iterator, std::uint32_t row_start);

      tbc::val_a<ds::Vec<MetadataLink, ConcurrentMemory>> links_;
      tbc::val_a<ds::Vec<MetadataRun, ConcurrentMemory>> runs_;
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> uris_;
      MetadataStatus status_ = MetadataStatus::complete;
    };

  }
}

// Interface: terminal/screen.cppm
export {
  namespace telar::runtime {

    struct ScreenCell {
      static constexpr std::size_t text_bytes = 16;
      // Its size on the wire and in memory, which it compares as.
      static constexpr std::size_t packed_bytes = 32;

      ds::Array<Byte, text_bytes> text{' '};
      Byte length = 1;
      CellWidth width = CellWidth::single;
      CellStyle style{};

      bool operator==(const ScreenCell& other) const noexcept;

      [[nodiscard]] Cell view() const noexcept;
    };

    static_assert(sizeof(ScreenCell) == ScreenCell::packed_bytes);
    static_assert(std::has_unique_object_representations_v<ScreenCell>);

    class Screen {
    public:
      explicit Screen(ConcurrentMemory& memory);

      void reserve(std::uint16_t columns, std::uint16_t lines);

      void resize(std::uint16_t columns, std::uint16_t lines);

      ds::Vec<ScreenCell, ConcurrentMemory> cells;
      ds::Vec<std::uint64_t, ConcurrentMemory> row_revisions;
      ds::Vec<Byte, ConcurrentMemory> row_flags;
      TextMetadataCapture metadata;
      std::uint64_t metadata_revision = 1;
      std::uint16_t cols = 0;
      std::uint16_t rows = 0;
      std::uint64_t revision = 0;
      Cursor cursor{};
      Mouse mouse{};
      InputModes input_modes{};
      PointerShape pointer_shape{};
      Scroll scroll{};
    };

  }
}

// Interface: terminal/cell_projection.cppm
export {
  namespace telar::runtime {

    class CellProjection {
    public:
      // Reads the terminal's colors; true when the default colors changed, which ghostty does
      // not count as damage to the rows already drawn with them.
      bool updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state);
      void copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const;

    private:
      [[nodiscard]] CellColor paletteColor(Byte index) const noexcept;
      [[nodiscard]] CellColor resolveColor(const GhosttyStyleColor& color, CellColor fallback) const noexcept;
      [[nodiscard]] CellStyle translateStyle(const GhosttyStyle& style) const noexcept;
      static void writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell& destination);
      // Fills `cell` from the content `raw` holds, column `column` of `cells`.
      void projectContent(GhosttyCell raw, GhosttyRenderStateRowCells cells, std::size_t column, ScreenCell& cell) const;

      GhosttyRenderStateColors colors_ = ghosttySized<GhosttyRenderStateColors>();
      ds::Array<Byte, palette_colors> palette_overrides_{};
      CellStyle default_style_{};
    };

  }
}

// Interface: terminal/effects.cppm
export {
  namespace telar::runtime {

    class TerminalEffects {
    public:
      // What the effects keep lives in `memory`, region `a`.
      explicit TerminalEffects(tbc::mut_a<ConcurrentMemory> memory);

      // A document that stands for rows of the scrollback, kept while the scrollback keeps them.
      struct InlineDocument {
        std::uint64_t id = 0;
        tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> bytes;
        // Rows of the terminal the effects belong to, valid while it lives.
        tbc::val_a<TrackedRow> first;
        tbc::val_a<TrackedRow> end;
        bool end_inclusive = false;
        // Where its rows were last seen, from the top of the scrollback; none before.
        std::uint32_t row = 0;
        std::uint32_t rows = 0;
        // What each of its rows held when the terminal first drew it, 0 before: a document stands
        // for that text, and goes once a row of it changes. A reflow learns them again.
        tbc::val_a<ds::Vec<std::uint64_t, ConcurrentMemory>> contents;
      };

      // Keeps the document of a zone a program closed. Past the pane's limits the oldest documents
      // go, and their rows show their text again.
      void keepInline(tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> bytes, tbc::val_a<TrackedRow> first, tbc::val_a<TrackedRow> end, bool end_inclusive);

      // Follows the documents' rows through output and reflow, and lets go of those whose rows the
      // scrollback dropped. Only the primary screen holds them.
      void placeInline(GhosttyTerminal terminal) noexcept;

      // Drops the document when its program has left the alternate screen.
      void closeDocument() noexcept;

      void refresh(GhosttyTerminal terminal);

      [[nodiscard]] std::string_view title() const noexcept;

      [[nodiscard]] std::string_view cwd() const noexcept;

      void setProgress(PaneProgressState state, ds::Option<Byte> percent) noexcept;

      // Public beside the title and cwd buffers: the terminal that owns these effects records each
      // as its programs act, and the runtime reads each as it delivers it. Only the buffers, which
      // hold validated text, stay private.
      // NOLINTBEGIN(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> clipboard;
      // The encoded document the pane's program shows over the pane, empty when none.
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> document;
      std::uint64_t document_revision = 0;
      // The documents that stand for rows of the scrollback, oldest first; the revision changes
      // whenever one comes, goes or moves.
      tbc::val_a<ds::Vec<InlineDocument, ConcurrentMemory>> inline_documents;
      std::uint64_t inline_revision = 0;
      std::uint64_t next_document_id = 1;
      std::size_t inline_bytes = 0;
      std::uint64_t title_revision = 1;
      std::uint64_t cwd_revision = 0;
      std::uint64_t clipboard_revision = 0;
      std::uint64_t progress_revision = 1;
      PaneProgressState progress_state = PaneProgressState::remove;
      ds::Option<Byte> progress_percent;
      bool title_pending = false;
      bool cwd_pending = false;
      // NOLINTEND(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)

    private:
      void updateTitle(std::string_view raw);

      void updateCwd(std::string_view raw);

      static constexpr std::size_t maximum_title_bytes = 256;
      static constexpr std::size_t maximum_cwd_bytes = 4096;

      ds::Array<char, maximum_title_bytes> title_{};
      ds::Array<char, maximum_cwd_bytes> cwd_{};
      std::size_t title_length_ = 0;
      std::size_t cwd_length_ = 0;
    };

  }
}

// Interface: terminal/frame_sync.cppm
export {
  namespace telar::runtime {

    // The longest a cell encodes to: its header, a changed style and its text.
    inline constexpr std::size_t maximum_cell_bytes = 31;

    // Writes `cells` as a frame's cell bytes: a header per cell, its style when it differs from
    // the cell before, then its text. `output` must hold `maximum_cell_bytes` per cell.
    void encodeScreenCells(std::span<const ScreenCell> cells, std::span<Byte>& output);

    // Encodes a pane's frames. Its spans view its own cell bytes, so it stays where it is built; its
    // buffers come from an allocator, and its counters from the runtime, in region `a`.
    class FrameSync {
    public:
      explicit FrameSync(tbc::mut_a<ConcurrentMemory> memory, std::uint64_t pane_id);

      FrameSync(const FrameSync&) = delete;
      FrameSync& operator=(const FrameSync&) = delete;
      FrameSync(FrameSync&&) = delete;
      FrameSync& operator=(FrameSync&&) = delete;
      ~FrameSync() = default;

      bool acknowledge(std::uint64_t frame_id) noexcept;

      void requestSnapshot() noexcept;

      bool needsSnapshot(const Screen& screen) const noexcept;

      bool waitingForAck() const noexcept;

      bool waitingForAck(const Screen& screen) const noexcept;

      std::uint64_t observedRevision() const noexcept;

      std::span<const Byte> prepare(const Screen& screen);

#if TELAR_DIAGNOSTICS
      // What the sync counted since the last call, which the caller adds to the runtime's metrics; taken
      // through shared access, as Rust's Cell::take is, so a prepared frame stays borrowed meanwhile.
      diagnostics::FrameCounters takeCounters() const noexcept;
#endif

    private:
      FrameBody frameHeader(const Screen& screen) const noexcept;

      static bool sameHeader(const FrameBody& left, const FrameBody& right) noexcept;

      void appendDamage(const Screen& screen, std::size_t& written);

      void appendSpan(std::span<const ScreenCell> cells, std::size_t start, std::size_t& written);

      static constexpr std::size_t maximum_spans = 4096;
      static constexpr std::size_t maximum_metadata_bytes = 153098 + (maximum_spans * 12) + 62;
#if TELAR_DIAGNOSTICS
      struct TBC_SHARED Counters {
        diagnostics::FrameCounters take() const noexcept;

        mutable diagnostics::FrameCounters value;
      };

      void recordFrame(std::size_t bytes, bool snapshot) noexcept;

      Counters counters_;
#endif
      std::uint64_t pane_id_;
      tbc::val_a<ds::Vec<ScreenCell, ConcurrentMemory>> baseline_;
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> cell_bytes_;
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> payload_;
      // Views of cell_bytes_.
      tbc::val_self<ds::Vec<FrameSpan, ConcurrentMemory>> spans_;
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> metadata_bytes_;
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> previous_metadata_;
      std::uint64_t metadata_revision_ = 0;
      FrameBody previous_header_{};
      std::uint64_t next_frame_id_ = 1;
      std::uint64_t acknowledged_id_ = 0;
      std::uint64_t outstanding_id_ = 0;
      std::uint64_t observed_revision_ = 0;
      bool snapshot_pending_ = true;
    };

  }
}

// Interface: terminal/terminal.cppm
export {
  namespace telar::runtime {

    enum class TerminalPurpose : std::uint8_t {
      interactive,
      separate_media,
      observation,
    };

    // The media a separate_media terminal feeds. It lives in graphics, above the terminal, so its
    // owner passes it to every call that may feed it. The terminal calls it once per chunk it
    // parses, through one indirect call, as Memory does for allocations.
    class TerminalMedia {
    public:
      virtual void requireOrderedInput() noexcept = 0;
      // The prefix of the input made of whole atomic frames, which the terminal parses as one unit.
      [[nodiscard]] virtual std::size_t atomicPrefix(std::span<const Byte> bytes) const noexcept = 0;
      virtual void output(std::span<const Byte> bytes) noexcept = 0;
      [[nodiscard]] virtual bool failed() const noexcept = 0;
      [[nodiscard]] virtual bool idle() const noexcept = 0;

    protected:
      TerminalMedia() = default;
      TerminalMedia(const TerminalMedia&) = default;
      TerminalMedia& operator=(const TerminalMedia&) = default;
      TerminalMedia(TerminalMedia&&) = default;
      TerminalMedia& operator=(TerminalMedia&&) = default;
      ~TerminalMedia() = default;
    };

    class Terminal {
    public:
      // The terminal keeps the allocator, the query resources and the media it feeds: region `a`.
      explicit Terminal(tbc::mut_a<ConcurrentMemory> memory, TerminalSize size, TerminalPurpose purpose = TerminalPurpose::interactive, tbc::val_a<std::shared_ptr<PtyResponseQueue>> responses = {}, tbc::val_a<GraphicsQueryResources> resources = {});

      // The bytes view the destination, region `b`, apart from what the terminal keeps.
      tbc::val_b<std::span<const Byte>> encodeKey(GhosttyKey key, GhosttyMods modifiers, tbc::val_b<std::span<Byte>> destination);

      // The documents' tracked rows belong to the terminal, which goes before the effects do.
      ~Terminal();

      Terminal(const Terminal&) = delete;
      Terminal& operator=(const Terminal&) = delete;
      Terminal(Terminal&&) = delete;
      Terminal& operator=(Terminal&&) = delete;

      // A terminal with media attached is fed, resumed and resized through the overloads that
      // take it, so the media sees every byte the terminal parses.
      void feed(std::span<const Byte> bytes);

      void feed(std::span<const Byte> bytes, TerminalMedia& media);

      void resumeControl();

      void resumeControl(TerminalMedia& media);

      // The terminal only remembers which media it feeds; its owner keeps it alive. Only the
      // runtime touches this ingress port; workers own sealed batches.
      void attachMedia(TerminalMedia& media) noexcept;

      bool hasPendingControl() const noexcept;

      void configureClientFacts(control::ClientFacts facts);

      control::Policy& controlPolicy() noexcept;

      control::Clipboard& clipboardControl() noexcept;

      bool pasteEvents() const noexcept;

      void resize(TerminalSize size);

      void resize(TerminalSize size, TerminalMedia& media);

      bool hasSize(TerminalSize size) const noexcept;

      // The colors its programs read and its client draws by default; the editor colors stay out.
      void configureColors(const TerminalTheme& colors);

      bool mode(GhosttyMode mode) const;

      // The bytes that draw the screen it shows on a terminal of its size just reset: its title,
      // the alternate screen when it shows that, its rows with their styles, its modes and its
      // cursor. Written into `room`; empty when they do not fit.
      [[nodiscard]] tbc::val_a<std::span<const Byte>> drawScreen(tbc::val_a<std::span<Byte>> room) const;

      bool outputSettled() const;

      void refresh();

      void scrollTo(std::uint32_t row);

      void scrollToBottom();

      // How the scrollback numbers its rows, as `PaneScrollback` reports it: the rows dropped from
      // its top since the terminal began, and a generation that changes when rows were renumbered
      // some other way.
      [[nodiscard]] std::uint64_t scrollbackGeneration() const noexcept;

      [[nodiscard]] std::uint64_t scrollbackTrimmed() const noexcept;

      // Reads where the row the terminal tracks went, after output: rows above it were dropped
      // when it moved up; losing it, or seeing it move down, means the scrollback was renumbered
      // (erased, say). The tracked row is a recent one, so the oldest rows can go without it.
      // Only the primary screen keeps a scrollback. The rows dropped since the last call.
      std::uint32_t followScrollback();

      std::span<const Byte> responses() const noexcept;

      void consumeResponses(std::size_t count);

      void consumeResponses(std::size_t count, TerminalMedia& media);

      void discardResponses() noexcept;

      void abortControl() noexcept;

      bool dirty() const noexcept;

      std::uint64_t contentRevision() const noexcept;

      // The rows it holds, its scrollback included.
      std::size_t totalRows() const;

      // ghostty's terminal, which lives apart from this object, by address only: raw, as a Rust FFI
      // `*mut` is.
      TBC_RAW GhosttyTerminal handle() const noexcept;

      const GhosttyAllocator* allocator() const noexcept;

#if TELAR_DIAGNOSTICS
      diagnostics::TerminalStorageSnapshot storageMetrics() const;
#endif

      [[nodiscard]] TBC_HOT_PATH inline const Screen& screen() const noexcept {
        return screen_;
      }

      [[nodiscard]] TBC_HOT_PATH inline const TerminalEffects& effects() const noexcept {
        return effects_;
      }

      TBC_HOT_PATH inline TerminalEffects& effectsMut() noexcept {
        return effects_;
      }

      [[nodiscard]] TBC_HOT_PATH inline const GraphicsStorage<ConcurrentMemory>& graphics() const noexcept {
        return graphics_;
      }

    private:
      // The media to feed, or none once abortControl let it go.
      // The media given, when it is the one attached.
      tbc::val_b<TerminalMedia*> attached(tbc::mut_b<TerminalMedia> media) const noexcept;

      void feedWith(std::span<const Byte> bytes, TerminalMedia* media);

      void resumeWith(TerminalMedia* media);

      void resizeWith(TerminalSize size, TerminalMedia* media);

      std::size_t feedControl(std::span<const Byte> bytes, TerminalMedia* media);

      void finishControlInput();

      static void titleChanged(GhosttyTerminal, void* context) noexcept;

      static void cwdChanged(GhosttyTerminal, void* context) noexcept;

      static GhosttyClipboardWriteResult clipboardWrite(GhosttyTerminal, void* context, const GhosttyClipboardWrite* write) noexcept;

      static void progressReported(GhosttyTerminal, void* context, const GhosttyTerminalProgressReport* report) noexcept;

      static bool reportSize(GhosttyTerminal, void* context, GhosttySizeReportSize* output) noexcept;

      static void receiveResponse(GhosttyTerminal, void* context, const Byte* bytes, std::size_t count) noexcept;

      static Byte readRowFlags(GhosttyRenderStateRowIterator iterator);

      void updateCursor();

      void updateModes();

      bool primaryScreen() const;

      // Lets go of a document once a row of the text it stands for changes, overwritten or erased,
      // so it never covers text it no longer stands for. Only rows on the screen can change, so only
      // those drawn anew this refresh are read again.
      void checkInline();

      // Tracks the active screen's first row, the newest row the scrollback will take.
      void trackScrollbackOrigin();

      // The tracked row, from the top of the scrollback; nothing once it was dropped.
      ds::Option<std::uint32_t> scrollbackOriginRow() const;

      void updateScroll();

      // The terminal's memory as ghostty sees it, counting the allocations it refused. Ghostty
      // records any operation it could not complete as a processing error and carries on, as
      // when a page holds no more hyperlinks; only a refused allocation means the pane's memory
      // ran out.
      struct GhosttyMemory {
        TBC_HOT_PATH inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
          auto* const pointer = memory.allocate(size, alignment);
          if (pointer == nullptr) {
            refusals.fetch_add(1, std::memory_order_relaxed);
          }

          return pointer;
        }

        TBC_HOT_PATH inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
          memory.deallocate(pointer, size, alignment);
        }

        tbc::mut_a<ConcurrentMemory> memory;
        std::atomic<std::size_t> refusals = 0;
      };

      tbc::val_a<Screen> screen_;
      tbc::val_a<TerminalEffects> effects_;
      tbc::val_a<GraphicsStorage<ConcurrentMemory>> graphics_;
      tbc::val_a<GhosttyMemory> ghostty_memory_;
      tbc::val_a<GhosttyAllocatorBridge<GhosttyMemory>> allocator_;
      TerminalHandle terminal_;
      RenderStateHandle render_state_;
      RowIteratorHandle row_iterator_;
      RowCellsHandle row_cells_;
      tbc::val_a<std::shared_ptr<PtyResponseQueue>> responses_;
      tbc::val_a<ResponseOutbox<ConcurrentMemory>> response_outbox_;
      // Which media the terminal feeds, never dereferenced: its owner passes it to every call.
      const TerminalMedia* media_ = nullptr;
      static constexpr std::size_t control_input_limit = std::size_t{128} * 1024;
      // The engine keeps the queue responses_ owns, a shared type, so the terminal stays where it was built.
      tbc::val_self<control::Engine> control_;
      tbc::val_a<ByteQueue<ConcurrentMemory>> pending_control_input_;
      TerminalPurpose purpose_;
      CellProjection projection_;
      TerminalSize size_{};
      ds::Array<GhosttyColorRgb, palette_colors> default_palette_{};
      bool dirty_ = true;
      bool force_ = true;
      std::uint64_t content_revision_ = 1;
      TrackedRow scrollback_origin_;
      // How far above the bottom the tracked row may get before a newer one replaces it.
      static constexpr std::size_t origin_distance = 256;
      std::uint32_t scrollback_origin_row_ = 0;
      std::uint64_t scrollback_trimmed_ = 0;
      std::uint64_t scrollback_generation_ = 1;
    };

  }
}

// Interface: terminal/scrollback_rows.cppm
export {
  namespace telar::runtime {

    // Reads rows of a terminal's scrollback for `ReadPaneRows`, by their stable number, into
    // buffers it keeps between requests. A reply views them, and the terminal's screen, until the
    // next read or refresh.
    class ScrollbackRows {
    public:
      explicit ScrollbackRows(tbc::mut_a<ConcurrentMemory> memory);

      // The rows from `request.from` the scrollback still has, at most a screen of them. The
      // terminal is scrolled to them to read them, and left at its bottom again.
      tbc::val_a<PaneRows> read(tbc::mut_a<Terminal> terminal, const ReadPaneRows& request);

    private:
      tbc::val_a<ds::Vec<Byte, ConcurrentMemory>> cells_;
      tbc::val_a<ds::Vec<MetadataRun, ConcurrentMemory>> runs_;
    };

  }
}

// Interface: terminal/selection_formatter.cppm
export {
  namespace telar::runtime {

    enum class TrailingSpaces : bool {
      kept,
      trimmed,
    };

    // Plain text of `selection`. Pane reads keep the spaces a program wrote, as
    // Ghostty's `Screen.dumpString`; copies trim them, as `Screen.selectionString`.
    void formatTerminalSelection(const Terminal& terminal, const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer);

  }
}

// Interface: terminal/text_reader.cppm
export {
  namespace telar::runtime {

    class TextReader {
    public:
      explicit TextReader(ConcurrentMemory& memory, Terminal& terminal, std::size_t capacity);

      void read(PaneTextSource source, std::uint16_t wanted_rows);

      void copy(const CopySelection& request);

      [[nodiscard]] std::span<const Byte> bytes() const noexcept;

      [[nodiscard]] std::string_view text() const noexcept;

      [[nodiscard]] bool truncated() const noexcept;

    private:
      [[nodiscard]] std::uint32_t totalRows() const;

      [[nodiscard]] GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const;

      [[nodiscard]] bool rowIsBlank(GhosttyPointTag tag, std::uint32_t row) const;

      void format(const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces);

      static bool receive(void* context, const Byte* bytes, std::size_t count) noexcept;

      Terminal& terminal_;
      // The text is written before it is read, so the storage is not zeroed first.
      ByteStorage<ConcurrentMemory> storage_;
      std::size_t position_ = 0;
      std::size_t length_ = 0;
      bool wrapped_ = false;
    };

  }
}
