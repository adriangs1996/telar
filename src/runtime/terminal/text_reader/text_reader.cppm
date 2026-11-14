module;
#include <ghostty/vt.h>

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.text_reader;

import std;
import telar.tbc;

export import telar.runtime.diagnostics.runtime_counters;

export import telar.runtime.diagnostics.operation;
export import telar.runtime.terminal.graphics_storage;

export import telar.runtime.terminal.osc_scanner;
export import telar.base.memory.allocators;
export import telar.base.memory.containers;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.pane_io;
import telar.config.runtime;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;
import telar.runtime.terminal.control.engine;

// Interface: terminal/text_metadata.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    // Links and runs of the text read, which a view lends with the row flags it is given: region `a`
    // holds both, as `&'a self` and an argument of the same lifetime would.
    class TextMetadataCapture {
    public:
      explicit TextMetadataCapture(tbc::view<Memory&, tbc::lt::a> memory);

      tbc::view<TextMetadata, tbc::lt::a> view(tbc::view<std::span<const Byte>, tbc::lt::a> row_flags) const noexcept;

      void capture(GhosttyRenderState state, GhosttyRenderStateRowIterator iterator, std::span<const Byte> row_flags, std::uint16_t columns);

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
        tbc::view<std::array<Identity, maximum_links>, tbc::lt::a> identities{};
        std::array<std::uint16_t, maximum_links * 2> slots{};
      };

      // The text is the terminal's, which the string only points at, as a raw pointer lends no borrow.
      static tbc::view<std::string_view, tbc::lt::a> stringView(tbc::view<GhosttyString, tbc::lt::a> value) noexcept;

      static std::size_t hash(const Identity& identity) noexcept;

      std::optional<std::uint16_t> intern(tbc::view<LinkTable&, tbc::lt::a> table, tbc::view<Identity, tbc::lt::a> identity);

      void captureRow(LinkTable& table, GhosttyRenderStateRowIterator iterator, std::uint32_t row_start);

      tbc::view<Vector<MetadataLink, Memory>, tbc::lt::a> links_;
      tbc::view<Vector<MetadataRun, Memory>, tbc::lt::a> runs_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> uris_;
      MetadataStatus status_ = MetadataStatus::complete;
    };

    extern template class TextMetadataCapture<telar::ConcurrentMemory>;

  }
}

// Interface: terminal/screen.cppm
export {
  namespace telar::runtime {

    struct ScreenCell {
      std::array<Byte, 16> text{' '};
      Byte length = 1;
      CellWidth width = CellWidth::single;
      CellStyle style{};

      bool operator==(const ScreenCell& other) const noexcept;

      Cell view() const noexcept;
    };

    static_assert(sizeof(ScreenCell) == 32);
    static_assert(std::has_unique_object_representations_v<ScreenCell>);

    template <Allocator Memory>
    class Screen {
    public:
      explicit Screen(Memory& memory);

      void reserve(std::uint16_t columns, std::uint16_t lines);

      void resize(std::uint16_t columns, std::uint16_t lines);

      Vector<ScreenCell, Memory> cells;
      Vector<std::uint64_t, Memory> row_revisions;
      Vector<Byte, Memory> row_flags;
      TextMetadataCapture<Memory> metadata;
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

    extern template class Screen<telar::ConcurrentMemory>;

  }
}

// Interface: terminal/cell_projection.cppm
export {
  namespace telar::runtime {

    class CellProjection {
    public:
      void updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state);
      void copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const;

    private:
      CellColor paletteColor(Byte index) const noexcept;
      CellColor resolveColor(const GhosttyStyleColor& color, CellColor fallback) const noexcept;
      CellStyle translateStyle(const GhosttyStyle& style) const noexcept;
      static void writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell& destination);

      GhosttyRenderStateColors colors_ = ghosttySized<GhosttyRenderStateColors>();
      std::array<Byte, 256> palette_overrides_{};
      CellStyle default_style_{};
    };

  }
}

// Interface: terminal/effects.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class TerminalEffects {
    public:
      explicit TerminalEffects(Memory& memory);

      // A document that stands for rows of the scrollback, kept while the scrollback keeps them.
      struct InlineDocument {
        std::uint64_t id = 0;
        Vector<Byte, Memory> bytes;
        TrackedRow first;
        TrackedRow end;
        bool end_inclusive = false;
        // Where its rows were last seen, from the top of the scrollback; none before.
        std::uint32_t row = 0;
        std::uint32_t rows = 0;
        // What each of its rows held when the terminal first drew it, 0 before: a document stands
        // for that text, and goes once a row of it changes. A reflow learns them again.
        Vector<std::uint64_t, Memory> contents;
      };

      // Keeps the document of a zone a program closed. Past the pane's limits the oldest documents
      // go, and their rows show their text again.
      void keepInline(Vector<Byte, Memory> bytes, TrackedRow first, TrackedRow end, bool end_inclusive);

      // Follows the documents' rows through output and reflow, and lets go of those whose rows the
      // scrollback dropped. Only the primary screen holds them.
      void placeInline(GhosttyTerminal terminal) noexcept;

      // Drops the document when its program has left the alternate screen.
      void closeDocument() noexcept;

      void refresh(GhosttyTerminal terminal);

      std::string_view title() const noexcept;

      std::string_view cwd() const noexcept;

      void setProgress(PaneProgressState state, std::optional<Byte> percent) noexcept;

      Vector<Byte, Memory> clipboard;
      // The encoded document the pane's program shows over the pane, empty when none.
      Vector<Byte, Memory> document;
      std::uint64_t document_revision = 0;
      // The documents that stand for rows of the scrollback, oldest first; the revision changes
      // whenever one comes, goes or moves.
      Vector<InlineDocument, Memory> inline_documents;
      std::uint64_t inline_revision = 0;
      std::uint64_t next_document_id = 1;
      std::size_t inline_bytes = 0;
      std::uint64_t title_revision = 1;
      std::uint64_t cwd_revision = 0;
      std::uint64_t clipboard_revision = 0;
      std::uint64_t progress_revision = 1;
      PaneProgressState progress_state = PaneProgressState::remove;
      std::optional<Byte> progress_percent;
      bool title_pending = false;
      bool cwd_pending = false;

    private:
      void updateTitle(std::string_view raw);

      void updateCwd(std::string_view raw);

      std::array<char, 256> title_{};
      std::array<char, 4096> cwd_{};
      std::size_t title_length_ = 0;
      std::size_t cwd_length_ = 0;
    };

    extern template class TerminalEffects<telar::ConcurrentMemory>;

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
    template <Allocator Memory>
    class FrameSync {
    public:
      explicit FrameSync(tbc::view<Memory&, tbc::lt::a> memory, std::uint64_t pane_id);

      FrameSync(const FrameSync&) = delete;
      FrameSync& operator=(const FrameSync&) = delete;

      bool acknowledge(std::uint64_t frame_id) noexcept;

      void requestSnapshot() noexcept;

      bool needsSnapshot(const Screen<Memory>& screen) const noexcept;

      bool waitingForAck() const noexcept;

      bool waitingForAck(const Screen<Memory>& screen) const noexcept;

      std::uint64_t observedRevision() const noexcept;

      std::span<const Byte> prepare(const Screen<Memory>& screen);

#if TELAR_DIAGNOSTICS
      // What the sync counted since the last call, which the caller adds to the runtime's metrics.
      diagnostics::FrameCounters takeCounters() noexcept;
#endif

    private:
      FrameBody frameHeader(const Screen<Memory>& screen) const noexcept;

      static bool sameHeader(const FrameBody& left, const FrameBody& right) noexcept;

      void appendDamage(const Screen<Memory>& screen, std::size_t& written);

      void appendSpan(std::span<const ScreenCell> cells, std::size_t start, std::size_t& written);

      static constexpr std::size_t maximum_spans = 4096;
      static constexpr std::size_t maximum_metadata_bytes = 153098 + maximum_spans * 12 + 62;
#if TELAR_DIAGNOSTICS
      void recordFrame(std::size_t bytes, bool snapshot) noexcept;

      diagnostics::FrameCounters counters_;
#endif
      std::uint64_t pane_id_;
      tbc::view<Vector<ScreenCell, Memory>, tbc::lt::a> baseline_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> cell_bytes_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> payload_;
      // Views of cell_bytes_.
      tbc::view<Vector<FrameSpan, Memory>, tbc::lt::self> spans_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> metadata_bytes_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> previous_metadata_;
      std::uint64_t metadata_revision_ = 0;
      FrameBody previous_header_{};
      std::uint64_t next_frame_id_ = 1;
      std::uint64_t acknowledged_id_ = 0;
      std::uint64_t outstanding_id_ = 0;
      std::uint64_t observed_revision_ = 0;
      bool snapshot_pending_ = true;
    };

    extern template class FrameSync<telar::ConcurrentMemory>;

  }
}

// Interface: terminal/terminal.cppm
export {
  namespace telar::runtime {

    enum class TerminalPurpose {
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
      virtual std::size_t atomicPrefix(std::span<const Byte> bytes) const noexcept = 0;
      virtual void output(std::span<const Byte> bytes) noexcept = 0;
      virtual bool failed() const noexcept = 0;
      virtual bool idle() const noexcept = 0;

    protected:
      TerminalMedia() = default;
      TerminalMedia(const TerminalMedia&) = default;
      TerminalMedia& operator=(const TerminalMedia&) = default;
      ~TerminalMedia() = default;
    };

    template <Allocator Memory>
    class Terminal {
    public:
      // The terminal keeps the allocator, the query resources and the media it feeds: region `a`.
      explicit Terminal(tbc::view<Memory&, tbc::lt::a> memory, TerminalSize size, TerminalPurpose purpose = TerminalPurpose::interactive, tbc::view<std::shared_ptr<PtyResponseQueue>, tbc::lt::a> responses = {}, tbc::view<GraphicsQueryResources, tbc::lt::a> resources = {});

      // The bytes view the destination, region `b`, apart from what the terminal keeps.
      tbc::view<std::span<const Byte>, tbc::lt::b> encodeKey(GhosttyKey key, GhosttyMods modifiers, tbc::view<std::span<Byte>, tbc::lt::b> destination);

      // The documents' tracked rows belong to the terminal, which goes before the effects do.
      ~Terminal();

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

      control::Clipboard<Memory>& clipboardControl() noexcept;

      bool pasteEvents() const noexcept;

      void resize(TerminalSize size);

      void resize(TerminalSize size, TerminalMedia& media);

      bool hasSize(TerminalSize size) const noexcept;

      void configureColors(const ConfigureTerminalColors& colors);

      void configureCursorColor(std::optional<std::array<Byte, 3>> color);

      bool mode(GhosttyMode mode) const;

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

      GhosttyTerminal handle() const noexcept;

      const GhosttyAllocator* allocator() const noexcept;

#if TELAR_DIAGNOSTICS
      diagnostics::TerminalStorageSnapshot storageMetrics() const;
#endif

      tbc::view<Screen<Memory>, tbc::lt::a> screen;
      tbc::view<TerminalEffects<Memory>, tbc::lt::a> effects;
      tbc::view<GraphicsStorage<Memory>, tbc::lt::a> graphics;

    private:
      // The media to feed, or none once abortControl let it go.
      TerminalMedia* attached(TerminalMedia& media) const noexcept;

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
      std::optional<std::uint32_t> scrollbackOriginRow() const;

      void updateScroll();

      tbc::view<GhosttyAllocatorBridge<Memory>, tbc::lt::a> allocator_;
      TerminalHandle terminal_;
      RenderStateHandle render_state_;
      RowIteratorHandle row_iterator_;
      RowCellsHandle row_cells_;
      tbc::view<std::shared_ptr<PtyResponseQueue>, tbc::lt::a> responses_;
      tbc::view<ResponseOutbox<Memory>, tbc::lt::a> response_outbox_;
      // Which media the terminal feeds, never dereferenced: its owner passes it to every call.
      const TerminalMedia* media_ = nullptr;
      static constexpr std::size_t control_input_limit = 128 * 1024;
      // The engine keeps the queue responses_ owns, a shared type, so the terminal stays where it was built.
      tbc::view<control::Engine<Memory>, tbc::lt::a> control_;
      tbc::view<ByteQueue<Memory>, tbc::lt::a> pending_control_input_;
      TerminalPurpose purpose_;
      CellProjection projection_;
      TerminalSize size_{};
      std::array<GhosttyColorRgb, 256> default_palette_{};
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

    extern template class Terminal<telar::ConcurrentMemory>;

  }
}

// Interface: terminal/scrollback_rows.cppm
export {
  namespace telar::runtime {

    // Reads rows of a terminal's scrollback for `ReadPaneRows`, by their stable number, into
    // buffers it keeps between requests. A reply views them, and the terminal's screen, until the
    // next read or refresh.
    template <Allocator Memory>
    class ScrollbackRows {
    public:
      explicit ScrollbackRows(tbc::view<Memory&, tbc::lt::a> memory);

      // The rows from `request.from` the scrollback still has, at most a screen of them. The
      // terminal is scrolled to them to read them, and left at its bottom again.
      tbc::view<PaneRows, tbc::lt::a> read(tbc::view<Terminal<Memory>&, tbc::lt::a> terminal, const ReadPaneRows& request);

    private:
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> cells_;
      tbc::view<Vector<MetadataRun, Memory>, tbc::lt::a> runs_;
    };

    extern template class ScrollbackRows<telar::ConcurrentMemory>;

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
    template <Allocator Memory>
    void formatTerminalSelection(Terminal<Memory>& terminal, const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer);

    extern template void formatTerminalSelection<telar::ConcurrentMemory>(Terminal<telar::ConcurrentMemory>& terminal, const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer);

  }
}

// Interface: terminal/text_reader.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class TextReader {
    public:
      explicit TextReader(Memory& memory, Terminal<Memory>& terminal, std::size_t capacity);

      void read(PaneTextSource source, std::uint16_t wanted_rows);

      void copy(const CopySelection& request);

      std::span<const Byte> bytes() const noexcept;

      std::string_view text() const noexcept;

      bool truncated() const noexcept;

    private:
      std::uint32_t totalRows() const;

      GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const;

      bool rowIsBlank(GhosttyPointTag tag, std::uint32_t row) const;

      void format(const GhosttySelection& selection, bool unwrap, TrailingSpaces spaces);

      static bool receive(void* context, const Byte* bytes, std::size_t count) noexcept;

      Terminal<Memory>& terminal_;
      // The text is written before it is read, so the storage is not zeroed first.
      ByteStorage<Memory> storage_;
      std::size_t position_ = 0;
      std::size_t length_ = 0;
      bool wrapped_ = false;
    };

    extern template class TextReader<telar::ConcurrentMemory>;

    template <Allocator Memory>
    TextReader(Memory& memory, Terminal<Memory>& terminal, std::size_t capacity) -> TextReader<Memory>;

  }
}
