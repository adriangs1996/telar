export module telar.runtime.terminal.control.engine;

import std;
import telar.ghostty.vt;
import telar.tbc;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.vocabulary;
import telar.runtime.terminal.control;
import telar.runtime.terminal.control.checksum;

// Engine::clipboard() hands out the clipboard state machine.
import telar.runtime.terminal.control.clipboard;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;
import telar.base.ds;

export namespace telar::runtime::control {

  class Engine {
  public:
    // What the engine keeps of its terminal, its allocator, response queue and resources included, is region `a`.
    explicit Engine(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<PtyResponseQueue> responses, bool enabled, tbc::val_a<GraphicsQueryResources> resources = {});

    void bind(tbc::val_a<GhosttyTerminal> terminal, tbc::val_a<GhosttyRenderState> render, bool separate_media) noexcept;

    void failWrite() noexcept;

    void enableMediaBoundaries() noexcept;

    bool awaitingMedia() const noexcept;

    void mediaComplete() noexcept;

    void discard() noexcept;

    std::size_t feed(std::span<const std::uint8_t> input);

    // Only a verified quiet atomic envelope may cross multiple graphics
    // boundaries. Its fixed suffix has no queries; the caller bounds the group.
    std::size_t feedAtomicMedia(std::span<const std::uint8_t> input);

    bool blocked() const noexcept;

    bool ground() const noexcept;

    void ordinary(std::span<const std::uint8_t> input);

    [[gnu::noinline]] std::size_t ordinaryRun(std::span<const std::uint8_t> input, std::size_t offset);

    void escapeBoundary();

    bool streamable(Sequence sequence) noexcept;

    bool borrowableApc(Sequence header) const noexcept;

    bool streamComplete() noexcept;

    bool enquire();

    // The first attempt snapshots state and applies mutations once. Retrying a
    // full queue only publishes that owned reply; it never re-executes setters.
    bool complete(Sequence sequence);

    void configureSize(TerminalSize size);

    void configureFacts(ClientFacts facts) noexcept;

    void publishReports();

    void externalColorsChanged() noexcept;

    Clipboard& clipboard() noexcept;

    // A document that stands for the rows its program wrote between the sequences that began and
    // ended it, on the primary screen; `end` is the row after them, or their last row when the
    // cursor stopped within it.
    struct Zone {
      tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> bytes;
      tbc::val_a<TrackedRow> first;
      tbc::val_a<TrackedRow> end;
      bool end_inclusive = false;
    };

    // The oldest zone a program closed since the last call, if any: it leaves with its bytes, in
    // the memory of region `a`, and nothing of the engine.
    tbc::val_a<ds::Option<Zone>> takeZone() noexcept;

    // Moves the document a program wrote since the last call into into.
    bool takeDocument(ds::Vec<std::uint8_t, ConcurrentMemory>& into) noexcept;

    bool pasteEvents() const noexcept;

    Policy policy;

  private:
    // Keeps the encoded document a sequence begins. On the alternate screen it covers the pane;
    // on the primary screen it opens a zone at the cursor's row, which only its end sequence
    // makes a document, so a sequence alone never takes rows over. A body that is no base64 is
    // ignored; the window validates the rest.
    void document(std::string_view encoded) noexcept;

    void closeZone() noexcept;

    struct ReleaseProducer {
      PtyResponseQueue::Producer& producer;

      ~ReleaseProducer();
    };

    void passthrough(Sequence sequence);

    void escape(Sequence sequence);

    void attributes(bool secondary);

    void csi(Sequence sequence, bool history_erased, bool homed);

    // `clear` erases the scrollback before the screen (ED 3, CUP, ED 2), and Ghostty moves a screen
    // whose last line is a prompt into the scrollback on ED 2 rather than erase it. The scrollback
    // is erased again after it, so nothing of the screen the program asked to erase stays.
    // busybox's `clear` moves home and erases below it instead (CUP, ED 0): on the primary screen
    // that is ED 2, sent as such so a prompt's screen moves into the scrollback the same way. Only
    // right after the CUP: a line editor erases below its prompt at the top row too.
    void eraseDisplay(Sequence sequence, unsigned mode, bool history_erased, bool homed);

    bool homeOnPrimary() const;

    void privateModes(const Parameters& parameters);

    void modeEffect(unsigned mode, bool set);

    void operatingStatus();

    void status(const Parameters& parameters);

    void reportCursor(bool extended);

    static bool knownMode(std::uint16_t value, bool ansi) noexcept;

    void modeReport(const Parameters& parameters);

    void sizeEvent();

    void sizeReport(unsigned request);

    // Only an offset survives retries; the parser owns the complete request
    // until this method has published every admitted capability response.
    bool termcap(std::string_view request);

    void dcs(Sequence sequence);

    void statusString(std::string_view request);

    void attributesString();

    void styleColor(const GhosttyStyleColor& color, bool background);

    void osc(Sequence sequence);

    void apc(Sequence sequence);

    static constexpr unsigned paste_events_mode = 5522;
    static constexpr unsigned focus_events_mode = 1004;
    static constexpr unsigned visibility_mode = 2033;
    static constexpr unsigned size_events_mode = 2048;
    static constexpr unsigned origin_mode = 6;
    static constexpr unsigned cursor_blink_mode = 12;
    static constexpr unsigned left_right_margin_mode = 69;
    static constexpr unsigned erase_color_mode = 117;
    static constexpr unsigned scheme_events_mode = 2031;
    static constexpr unsigned scheme_request = 996;
    static constexpr unsigned visibility_request = 998;
    static constexpr unsigned pixels_request = 14;
    static constexpr unsigned cell_request = 16;
    static constexpr unsigned text_request = 18;
    static constexpr unsigned screen_request = 19;
    static constexpr unsigned title_request = 21;

    tbc::val_a<Parser<ConcurrentMemory>> parser_;
    tbc::val_a<Reply<ConcurrentMemory>> reply_;
    tbc::val_a<VtState> state_;
    tbc::val_a<Checksum> checksum_;
    tbc::val_a<Clipboard> clipboard_;
    tbc::val_a<GraphicsQueries<ConcurrentMemory>> graphics_queries_;
    tbc::val_a<Reports<ConcurrentMemory>> reports_;
    ColorQueries<ConcurrentMemory> colors_;
    tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> document_;
    tbc::val_a<ds::Option<Zone>> open_zone_;
    tbc::val_a<ds::Vec<Zone, ConcurrentMemory>> zones_;
    ClientFacts facts_;
    tbc::val_a<PtyResponseQueue::Producer> responses_;
    bool enabled_;
    bool closed_ = false;
    bool media_boundaries_ = false;
    bool awaiting_media_ = false;
    bool streamed_media_ = false;
    bool prepared_ = false;
    bool clipboard_before_reply_ = false;
    bool document_pending_ = false;
    // The scrollback was just erased, with at most the cursor moved since.
    bool history_erased_ = false;
    // The last sequence moved the cursor home (CUP).
    bool homed_ = false;
    ds::Array<bool, desktop_modes.size()> saved_desktop_modes_{};
    std::size_t capability_offset_ = 0;
    bool paste_events_ = false;
  };

}
