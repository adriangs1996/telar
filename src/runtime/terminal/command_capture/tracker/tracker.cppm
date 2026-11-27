module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.command_capture.tracker;

import std;
import telar.ghostty.vt;
import telar.tbc;
import telar.wire.vocabulary;
import telar.wire.content;
import telar.platform.primitives;
import telar.runtime.terminal.control;

import telar.platform.events;
import telar.runtime.history.command;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.terminal.shell_integration.token;
import telar.runtime.terminal.text_reader;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.history;
import telar.runtime.terminal.ghostty;
import telar.base.ds;
import telar.sys.socket;

// The work is in tracker.cpp. What stays here are the relays over the caller's sinks, which hand
// each sink to that work behind a virtual call.
export namespace telar::runtime {

  template <typename Sink>
  concept CapturedCommandSink = requires(Sink& sink, const CapturedCommand& command) {
    { sink.emit(command) } -> std::same_as<void>;
  };

  // A CapturedCommandSink behind a virtual call, for the work in tracker.cpp. It hears of a
  // command as it starts, too, which a sink without `start` ignores.
  class CapturedCommandEmitter {
  public:
    virtual void emit(const CapturedCommand& command) = 0;
    virtual void start(const CapturedCommand& command) = 0;

  protected:
    CapturedCommandEmitter() = default;
    ~CapturedCommandEmitter() = default;
    CapturedCommandEmitter(const CapturedCommandEmitter&) = default;
    CapturedCommandEmitter& operator=(const CapturedCommandEmitter&) = default;
    CapturedCommandEmitter(CapturedCommandEmitter&&) = default;
    CapturedCommandEmitter& operator=(CapturedCommandEmitter&&) = default;
  };

  template <CapturedCommandSink Sink>
  class [[tbc::generic]] CapturedCommandRelay final : public CapturedCommandEmitter {
  public:
    inline explicit CapturedCommandRelay(tbc::mut_a<Sink> sink) noexcept
        : sink_(sink) {}

    inline void emit(const CapturedCommand& command) override {
      sink_.emit(command);
    }

    inline void start(const CapturedCommand& command) override {
      if constexpr (requires { sink_.start(command); }) {
        sink_.start(command);
      }
    }

  private:
    tbc::mut_a<Sink> sink_;
  };

  struct CommandByteObservation {
    std::span<const Byte> bytes;
    ObservationTime time;
    ds::Option<bool> shell_foreground;
  };

  class CommandInputScanner {
  public:
    struct Event {
      bool submitted = false;
      bool cancelled = false;
    };

    Event feed(std::span<const Byte> bytes) noexcept;
    void reset() noexcept;
    [[nodiscard]] ds::Option<std::string_view> typedText() const noexcept;

  private:
    enum class State : std::uint8_t {
      ground,
      escape,
      sequence,
      paste,
      paste_escape,
      paste_sequence,
    };
    static constexpr Byte escape = 0x1b;
    static constexpr unsigned paste_start = 200;
    static constexpr unsigned paste_end = 201;
    static constexpr std::size_t typed_capacity = 255;

    void ground(Byte byte, Event& event) noexcept;
    void beginSequence(Byte byte, bool pasted) noexcept;
    void sequence(Byte byte, bool pasted) noexcept;

    State state_ = State::ground;
    unsigned parameter_ = 0;
    bool has_parameter_ = false;
    ds::Array<char, typed_capacity> typed_{};
    std::size_t typed_count_ = 0;
    bool typed_exact_ = true;
  };

  struct CommandCompletion {
    ObservationTime time;
    ds::Option<int> exit_code;
    HistoryStatus status = HistoryStatus::completed;
  };

  template <typename Sink>
  concept CommandCompletionSink = requires(Sink& sink, CommandCompletion completion) {
    { sink.complete(completion) } -> std::same_as<void>;
  };

  // Where a command starts, as the shell is when its C mark arrives: the directory it reported,
  // the host and user it runs as, and the branch of the repository that directory is in. Views
  // that live for the call they are passed to.
  struct CommandPlace {
    std::string_view directory;
    std::string_view host;
    std::string_view user;
    std::string_view branch;
    // The shell runs on a host `ssh` reached: this host's user and repository are not its.
    bool remote = false;
  };

  // A signed mark (A, B, C or D) and the offset just past it in the bytes fed, for a sink that
  // places it on the terminal those bytes reach. Two more say where the marks come from: N when
  // the shell `ssh` reached takes over, U when the pane's own shell is back.
  struct CommandMark {
    char action = 0;
    std::size_t end = 0;
    // The status a D mark reported, when it reported one.
    ds::Option<int> status;
    // Where a C mark's command starts: what the zones know of it.
    CommandPlace place;
  };

  // A CommandCompletionSink behind a virtual call, for the scan in tracker.cpp. It receives the
  // marks too, which a sink without `mark` ignores.
  class CommandZoneSink {
  public:
    virtual void complete(CommandCompletion completion) = 0;
    virtual void mark(CommandMark mark) = 0;

  protected:
    CommandZoneSink() = default;
    ~CommandZoneSink() = default;
    CommandZoneSink(const CommandZoneSink&) = default;
    CommandZoneSink& operator=(const CommandZoneSink&) = default;
    CommandZoneSink(CommandZoneSink&&) = default;
    CommandZoneSink& operator=(CommandZoneSink&&) = default;
  };

  template <CommandCompletionSink Sink>
  class [[tbc::generic]] CommandZoneRelay final : public CommandZoneSink {
  public:
    inline explicit CommandZoneRelay(tbc::mut_a<Sink> sink) noexcept
        : sink_(sink) {}

    inline void complete(CommandCompletion completion) override {
      sink_.complete(completion);
    }

    inline void mark(CommandMark mark) override {
      if constexpr (requires { sink_.mark(mark); }) {
        sink_.mark(mark);
      }
    }

  private:
    tbc::mut_a<Sink> sink_;
  };

  class CommandZones {
  public:
    // With a token, only marks signed with it count: the pane's shell integration signs its
    // own, and a program cannot sign the ones it prints.
    // The shell's names are kept in `memory`, which must outlive the zones and every copy of them.
    explicit CommandZones(ConcurrentMemory& memory, std::string_view directory, ds::Option<ShellToken> token = ds::none);

    [[nodiscard]] ConcurrentMemory& memory() const noexcept;

    [[nodiscard]] ds::Option<ShellToken> token() const noexcept;

    // Whether the marks come from a shell on another host, which `ssh` started with telar's
    // integration, and which shell that is.
    [[nodiscard]] bool remote() const noexcept;
    [[nodiscard]] IntegratedShell remoteShell() const noexcept;

    // A shell over scan, for any sink: the sink only hears of a finished sequence, so the
    // bytes are read without a virtual call.
    template <CommandCompletionSink Sink>
    [[tbc::generic]] inline void feed(std::span<const Byte> bytes, ObservationTime time, Sink& sink) {
      CommandZoneRelay<Sink> relay{sink};

      scan(bytes, time, relay);
    }

    void scan(std::span<const Byte> bytes, ObservationTime time, CommandZoneSink& sink);

    // Forgets every mark and report, as a new observation starts, keeping the memory, the token
    // and the directory.
    void restart();
    void input(std::span<const Byte> bytes) noexcept;
    [[nodiscard]] bool editing() const noexcept;
    [[nodiscard]] bool markersReady() const noexcept;
    [[nodiscard]] bool running() const noexcept;
    void setDirectory(std::string_view directory);
    [[nodiscard]] std::string_view directory() const noexcept;

    // The PATH the integrated shell last reported; empty until it does.
    [[nodiscard]] std::string_view path() const noexcept;

    // The aliases and functions the shell last reported, blank-separated: names it runs that
    // no PATH directory holds. Null until it reports them, or when they did not fit.
    // Shared, not copied, with the completion requests that read them on another thread.
    [[nodiscard]] const std::shared_ptr<const ds::String<ConcurrentMemory>>& names() const noexcept;

    // The host a shell `ssh` reached runs on, as its working directory report names it.
    [[nodiscard]] std::string_view remoteHost() const noexcept;

    // Where that shell works, as it reports it; empty until it does. `directory()` stays this
    // host's.
    [[nodiscard]] std::string_view remoteDirectory() const noexcept;

    // The socket of the connection `ssh` shares with that shell's session, as the pane's own
    // shell named it in the nonce it signed: an absolute path of plain characters a socket
    // address holds. Empty when the session shares none, or until the remote shell answers.
    [[nodiscard]] std::string_view remoteControl() const noexcept;

    // The line the shell's line editor held when telar last had it cleared, before a command
    // its editor ran: keys typed while that editor was not up. Printable text and the newlines
    // and tabs of a multi-line line, at most `typeahead_capacity` bytes, cut on a character.
    [[nodiscard]] std::string_view typeahead() const noexcept;
    // Counts the shell's reports of its line, so a reader tells a new one from the last.
    [[nodiscard]] std::uint64_t typeaheadSerial() const noexcept;

    static constexpr std::size_t typeahead_capacity = 4096;
    static constexpr std::size_t user_capacity = 64;
    static constexpr std::size_t control_capacity = sizeof(sockaddr_un::sun_path) - 1;

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters takeMetrics() noexcept;
#endif

  private:
    enum class ParserState : std::uint8_t {
      ground,
      escape,
      osc,
      osc_escape,
    };
    enum class Zone : std::uint8_t {
      unknown,
      prompt,
      input,
      output,
    };
    static constexpr Byte escape = 0x1b;
    static constexpr Byte bell = 0x07;
    static constexpr std::size_t directory_capacity = 4096;
    static constexpr std::size_t path_capacity = 8192;
    static constexpr std::size_t host_capacity = 255;
    static constexpr std::string_view private_code = "6973";
    static constexpr std::size_t sequence_capacity = std::size_t{16} * 1024;

    // What the shell's marks and reports said, apart from the sequence being read, so a report's
    // body, which views that sequence, is handed to it.
    struct Shell {
      // Not inlined: a sequence finishes for every OSC a pane prints, and these two only for OSC
      // 6973 and OSC 7; their buffers in its frame would put every prompt mark (OSC 133) on deeper
      // stack pages.
      [[gnu::noinline]] bool privateReport(std::string_view body);
      // Whether `body` is a signed report that the running command's output ended
      // (telar=<token>;ended), as the shell's own output, such as zsh's PROMPT_SP, starts.
      [[nodiscard]] bool endReport(std::string_view body) const noexcept;
      // The lines a signed report that the shell's report of its background jobs ended
      // (telar=<token>;jobs=<lines>) says bash may have printed above where the command's output
      // ended; nothing for another report.
      [[nodiscard]] ds::Option<int> jobsReport(std::string_view body) const noexcept;
      void semantic(std::string_view body, ObservationTime time, CommandZoneSink& sink, std::size_t end);
      // Whether a mark's signature is the pane's shell's or the remote one's; the pane's own ends a
      // session `ssh` nested, and an A or D mark of it, `clears_nest`, drops the nonce it handed.
      bool signedMark(std::string_view options, bool clears_nest, CommandZoneSink& sink, std::size_t end);
      [[gnu::noinline]] void directoryReport(std::string_view body);
      [[gnu::noinline]] void typeaheadReport(std::string_view encoded);
      // The nonce the pane's shell hands `ssh`, and the socket of the connection it shares.
      void nestReport(std::string_view body);
      // Where a command starting now starts.
      [[nodiscard]] CommandPlace place() const noexcept;

#if TELAR_DIAGNOSTICS
      diagnostics::CommandCaptureCounters metrics_;
#endif
      ConcurrentMemory* memory_ = nullptr;
      ds::Option<ShellToken> token_;
      ds::Option<ShellToken> remote_;
      ds::Option<ShellToken> nest_;
      IntegratedShell remote_shell_ = IntegratedShell::none;
      Zone zone_ = Zone::unknown;
      bool markers_ready_ = false;
      bool has_input_ = false;
      bool running_ = false;
      bool nested_running_ = false;
      FixedText<directory_capacity> directory_;
      FixedText<path_capacity> path_;
      FixedText<host_capacity> host_;
      FixedText<directory_capacity> remote_directory_;
      // The host the pane's own shell names in its working directory reports.
      FixedText<host_capacity> local_host_;
      // The user the remote shell runs as, as it answered ssh's nonce.
      FixedText<user_capacity> remote_user_;
      // The shared connection's socket: named with the nonce, and the session's once answered.
      FixedText<control_capacity> nest_control_;
      FixedText<control_capacity> control_;
      FixedText<typeahead_capacity> typeahead_;
      std::uint64_t typeahead_serial_ = 0;
      std::shared_ptr<const ds::String<ConcurrentMemory>> names_;
    };

    // Reads one byte of an escape sequence; `end` is the offset just past it.
    void step(Byte byte, ObservationTime time, CommandZoneSink& sink, std::size_t end);
    void finishSequence(ObservationTime time, CommandZoneSink& sink, std::size_t end);

    Shell shell_;
    ParserState parser_ = ParserState::ground;
    ds::Array<char, sequence_capacity> bytes_{};
    std::size_t length_ = 0;
    bool overflow_ = false;
  };

  // The last bytes of a command's output, kept in storage its owner allocates, storage_bytes of
  // it: empty storage keeps nothing. A ring holds the last `capacity` bytes and the `lookback`
  // before them, which tell where an escape sequence the tail would start inside of ends.
  class CommandOutputWindow {
  public:
    static constexpr std::size_t capacity = std::size_t{64} * 1024;
    static constexpr std::size_t lookback = 4096;
    static constexpr std::size_t storage_bytes = capacity + lookback;

    void append(std::span<std::uint8_t> storage, std::span<const std::uint8_t> bytes) noexcept;
    // The last `capacity` bytes of the output, or all of it, from the first byte that starts a
    // character outside an escape sequence; it lays the ring out in order in `storage` first.
    [[nodiscard]] tbc::val_a<std::span<const std::uint8_t>> bytes(tbc::val_a<std::span<std::uint8_t>> storage) noexcept;
    [[nodiscard]] std::uint64_t observed() const noexcept;
    void clear() noexcept;

  private:
    std::size_t head_ = 0;
    std::size_t length_ = 0;
    std::uint64_t observed_ = 0;
  };

  template <Allocator Memory>
  class CommandOutputTail {
  public:
    static constexpr std::size_t capacity = CommandOutputWindow::capacity;

    explicit CommandOutputTail(Memory& memory, bool enabled);

    void enable();
    void append(std::span<const std::uint8_t> bytes) noexcept;
    [[nodiscard]] std::span<const std::uint8_t> bytes() noexcept;
    [[nodiscard]] std::uint64_t observed() const noexcept;
    void clear() noexcept;

  private:
    ds::Vec<std::uint8_t, Memory> bytes_;
    CommandOutputWindow window_;
  };

  extern template class CommandOutputTail<ConcurrentMemory>;

  // The terminal a selection reads, as it is at the call.
  struct CommandScreen {
    GhosttyTerminal terminal = nullptr;
    std::uint16_t columns = 0;
  };

  CommandScreen commandScreen(const Terminal& terminal) noexcept;

  // Receives a formatted selection into a buffer, keeping what fits.
  class CommandTextWriter {
  public:
    explicit CommandTextWriter(tbc::val_a<std::span<Byte>> destination) noexcept;

    GhosttyWriter ghostty() noexcept;

    // Cuts the text to a whole UTF-8 prefix of at most CommandSelection::maximum_bytes. Whether
    // that cut it short, or nothing when it is empty.
    ds::Option<bool> finish() noexcept;
    [[nodiscard]] std::size_t length() const noexcept;

  private:
    static bool receive(void* context, const Byte* bytes, std::size_t count) noexcept;

    tbc::val_a<std::span<Byte>> destination_;
    std::size_t length_ = 0;
    bool overflow_ = false;
  };

  // The text typed at a prompt, from where the input starts to the cursor, read back from the
  // terminal's screen. Anchors that follow the rows as the terminal scrolls keep where it starts.
  class CommandSelection {
  public:
    static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;
    // A buffer that holds maximum_bytes and the rest of a scalar cut at its end.
    static constexpr std::size_t buffer_bytes = maximum_bytes + 4;

    explicit CommandSelection(GhosttyTerminal terminal);

    [[nodiscard]] static bool primary(CommandScreen screen);
    void begin(CommandScreen screen);
    void rebase(CommandScreen screen, ds::Option<std::string_view> typed);

    // What to read from the anchor to the cursor, or nothing when there is no text to read.
    // Ghostty's own references into its grid, which it keeps valid until the screen changes: a raw
    // value, as Rust keeps an FFI library's handles.
    [[nodiscard]] [[tbc::raw]] tbc::val_a<ds::Option<GhosttySelection>> select(tbc::val_a<CommandScreen> screen) const;

  private:
    using TrackedReference = GhosttyHandle<GhosttyTrackedGridRef, ghostty_tracked_grid_ref_free>;

    void findRightPrompt(CommandScreen screen);
    [[nodiscard]] GhosttyPointCoordinate selectionFinish(CommandScreen screen, GhosttyPointCoordinate start, GhosttyPointCoordinate fallback) const;

    tbc::val_a<TrackedReference> anchor_;
    TrackedReference right_prompt_;
    std::uint64_t right_prompt_hash_ = 0;
    bool right_prompt_active_ = false;
    bool erased_ = false;
  };

  // A block as a checkpoint keeps it: what its command was, how it ended, where and when it
  // started. Its rows stay with the scrollback of the runtime that drew them.
  struct CommandBlockRecord {
    CommandBlockState state = CommandBlockState::succeeded;
    std::int32_t status = 0;
    std::uint32_t duration_ms = 0;
    std::int64_t started_ms = 0;
    std::uint16_t lines = 0;
    CommandBlockNest nest = CommandBlockNest::none;
    std::string_view command;
    std::string_view directory;
    std::string_view host;
    std::string_view user;
    std::string_view branch;
  };

  // Reads `selection` into `destination`. Whether it was cut short, or nothing when it is empty.
  ds::Option<bool> captureCommandText(const Terminal& terminal, const GhosttySelection& selection, ds::Vec<Byte, ConcurrentMemory>& destination);

  // The commands a pane's integrated shell ran, each anchored to the row its prompt starts on
  // in the pane's own terminal, so a client can mark them in the scrollback and jump to them.
  // The anchors follow the rows as output scrolls and the scrollback drops its oldest lines.
  // CommandBlocks gives it the terminal and the buffer it reads a command into.
  //
  // A block lives as long as the rows it was drawn on: rows the scrollback drops, or that
  // `clear` or a reset erases, take their blocks with them, and so does a prompt drawn over
  // them, as Ctrl-L draws one where the screen it cleared was. What clients hear is always in
  // order: each block's output starts at or before the row the next block's prompt starts on.
  class CommandBlockRing {
  public:
    static constexpr std::size_t capacity = PaneBlocks::capacity;
    static constexpr std::size_t command_bytes = 160;

    CommandBlockRing(const CommandBlockRing&) = delete;
    CommandBlockRing& operator=(const CommandBlockRing&) = delete;
    CommandBlockRing(CommandBlockRing&&) = delete;
    CommandBlockRing& operator=(CommandBlockRing&&) = delete;

    // A signed mark, reached by the terminal as the shell printed it. A C mark's command starts
    // at `place`.
    void mark(char action, std::chrono::steady_clock::time_point now, const CommandPlace& place = {});

    // A signed mark as the zones read it: a D mark ends its block with the status it reported.
    void place(CommandMark mark, std::chrono::steady_clock::time_point now);

    // The status a D mark reported, for the block it ends: ssh's own, after its session.
    void finished(ds::Option<int> status, std::chrono::steady_clock::time_point now);

    // Reads where the blocks are now: output scrolled them, the scrollback dropped some, or a
    // resize reflowed them. Only the oldest is read unless it moved. The anchors are on the
    // primary screen: while a full-screen program has the alternate one, they cannot be read,
    // and they stay as they were.
    void follow(bool reflowed = false);

    [[nodiscard]] std::uint64_t revision() const noexcept;
    // The blocks view their commands in the ring, region `b`, through `storage`.
    tbc::val_b<PaneBlocks> message(std::uint64_t pane_id, tbc::mut_b<ds::Array<CommandBlock, capacity>> storage) const;

    // The blocks of commands, oldest first, as a checkpoint keeps them: they view the ring, region
    // `b`, through `storage`. Output no command printed has nothing to keep.
    tbc::val_b<std::span<const CommandBlockRecord>> records(tbc::mut_b<ds::Array<CommandBlockRecord, capacity>> storage) const;

    // A block of a command an earlier runtime ran, after the others restored and before every
    // block of this one's; nothing once the ring is full. A command that still ran when that
    // runtime ended was interrupted.
    void restore(const CommandBlockRecord& block);

    // The command the shell runs or last ran. It outlives its block, which the ring drops with
    // the rows the scrollback loses: a pane's card still says what ran after `clear`.
    struct Latest {
      // running, also while an ssh hosts a remote shell, or how the command ended.
      CommandBlockState state = CommandBlockState::running;
      std::int32_t status = 0;
      std::uint32_t duration_ms = 0;
      // The command had lines after the first, or more of that line than `command` holds.
      bool truncated = false;
      std::chrono::steady_clock::time_point started;
      FixedText<command_bytes> command;
    };

    // Nothing until the shell runs a command.
    [[nodiscard]] const ds::Option<Latest>& latest() const noexcept;
    // Counts the times `latest` changed: a command started or ended.
    [[nodiscard]] std::uint64_t commandRevision() const noexcept;

  protected:
    // A block's places are kept in `memory`, region `c`, which must outlive the ring.
    CommandBlockRing(tbc::mut_c<ConcurrentMemory> memory, tbc::val_a<GhosttyTerminal> terminal);
    ~CommandBlockRing() = default;

  private:
    // A tracked reference the block owns, moved as the ring drops its oldest.
    class TrackedReference {
    public:
      TrackedReference() = default;
      TrackedReference(const TrackedReference&) = delete;
      TrackedReference& operator=(const TrackedReference&) = delete;
      TrackedReference(TrackedReference&& other) noexcept;
      TrackedReference& operator=(TrackedReference&& other) noexcept;
      ~TrackedReference();

      [[nodiscard]] GhosttyTrackedGridRef get() const noexcept;
      GhosttyTrackedGridRef* output() noexcept;

    private:
      void release() noexcept;

      GhosttyTrackedGridRef handle_ = nullptr;
    };

    // Where a block's command started, as long as the block lives: only what the shell reported,
    // so a block costs the bytes of its own place.
    struct Place {
      explicit Place(ConcurrentMemory& memory);

      ds::String<ConcurrentMemory> directory;
      ds::String<ConcurrentMemory> host;
      ds::String<ConcurrentMemory> user;
      ds::String<ConcurrentMemory> branch;
    };

    struct Entry {
      TrackedReference anchor;
      // The row the command's output starts on, mark C's, which ends the rows the prompt and
      // the command line take however a resize reflows them.
      TrackedReference output;
      std::uint32_t row = 0;
      std::uint16_t rows = 1;
      std::uint16_t lines = 0;
      // `command` holds less than the command's first line.
      bool cut = false;
      CommandBlockState state = CommandBlockState::running;
      CommandBlockNest nest = CommandBlockNest::none;
      std::int32_t status = 0;
      std::uint32_t duration_ms = 0;
      std::chrono::steady_clock::time_point started;
      std::int64_t started_ms = 0;
      ds::Option<Place> place;
      // An earlier runtime's, restored without rows: its anchors track nothing.
      bool restored = false;
      FixedText<command_bytes> command;
    };

    [[nodiscard]] virtual CommandScreen screen() const noexcept = 0;

    // Reads `selection` into the buffer `captured` shows.
    virtual ds::Option<bool> capture(const GhosttySelection& selection) = 0;
    [[nodiscard]] virtual std::span<const Byte> captured() const noexcept = 0;

    Entry& entryMut(std::size_t index) noexcept;
    [[nodiscard]] tbc::ref_b<Entry> entry(std::size_t index) const noexcept;
    // A tracked reference ghostty keeps into its grid, which the block owns: a raw handle.
    [[tbc::raw]] ds::Option<TrackedReference> track();
    // A reference to the start of row `row` of the active screen.
    [[tbc::raw]] ds::Option<TrackedReference> track(std::uint16_t row);
    // The prompt a line editor drew again without the shell's precmd, which printed no A mark:
    // the next block starts where it now is.
    // `idle`: no command was taken back, so output above the prompt came while none ran.
    void redrawn(std::chrono::steady_clock::time_point now, bool idle);
    // Drops the newest blocks a prompt starting on `row` was drawn over.
    void cover(std::uint32_t row);
    // Output printed from the prompt's row while no command ran: a block of its own, which takes
    // the prompt's anchor, or, `reported`, the shell's report of its jobs, which takes the
    // report's.
    void background(std::chrono::steady_clock::time_point now, bool reported = false);
    // The command's output ended (zsh's E, or the D of a shell without it): what the shell
    // prints from here until it says its report ended is its report of its background jobs.
    void reportStarts();
    // The shell's report of its jobs ends at the cursor: its rows, and the `above` lines just
    // above where the command's output ended that bash printed as job reports, become a
    // background block at the next prompt.
    void reportEnds(std::uint32_t above);
    // The first of the job reports bash printed in the `above` lines just above `row`, no higher
    // than `floor`; `row` when there is none.
    [[nodiscard]] std::uint32_t reportsAbove(std::uint32_t row, std::uint32_t above, std::uint32_t floor) const;
    // A reference to the start of row `row` of the screen, from the top of the scrollback.
    [[tbc::raw]] ds::Option<TrackedReference> trackScreen(std::uint32_t row);
    // The rows a block's output starts on and its prompt starts on, or nothing once its rows are
    // gone. A background block's output starts on its first row.
    [[nodiscard]] ds::Option<std::uint32_t> outputRow(const Entry& block, ds::Option<std::uint32_t> first) const;
    // The line editor took the running command back before it ran.
    void takeBack();
    [[nodiscard]] ds::Option<std::uint32_t> row(const TrackedReference& tracked) const;
    void start(std::chrono::steady_clock::time_point now, const CommandPlace& place);

    void finish(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);
    void closeSession(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);
    void end(Entry& block, CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);
    // Ends `latest_`, the command that ran until now.
    void settle(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);

    tbc::mut_c<ConcurrentMemory> memory_;
    // The terminal the selection reads, region `a`.
    tbc::val_a<CommandSelection> selection_;
    ds::Option<TrackedReference> prompt_;
    // The rows from the prompt's A mark to its B mark, once its B was printed: a prompt drawn
    // again is as tall, also after a command the line editor took back.
    ds::Option<std::uint32_t> prompt_height_;
    tbc::val_b<ds::Array<Entry, capacity>> entries_{};
    std::size_t first_ = 0;
    std::size_t count_ = 0;
    std::uint64_t revision_ = 0;
    ds::Option<Latest> latest_;
    // What `latest_` was before the running command started, for a command taken back.
    ds::Option<Latest> previous_;
    std::uint64_t command_revision_ = 0;
    bool running_ = false;
    // Commands run in the shell ssh reached; that shell just left, and ssh's D ends its block.
    bool nested_ = false;
    bool closing_ = false;
    // Where the shell's report of its jobs starts once the command's output ended: the row the
    // output ended on, or the one after it when the output's last line has no newline.
    ds::Option<TrackedReference> report_;
    bool report_next_row_ = false;
    // The first row of a report that printed something, which the next prompt makes a block.
    ds::Option<TrackedReference> reported_;
  };

  // Feeds a read's bytes to the terminal the blocks anchor in, cut at each signed mark the zones
  // find in them, and places each mark once the terminal holds what the shell printed before it,
  // so a block starts on the row its mark was printed on. Every mark is placed, however many one
  // read holds: the work is bounded by the bytes, not by a count of marks. `feed` is the
  // caller's way to reach its terminal, a template so the call is direct; `fed` counts the bytes
  // it reached, which the caller feeds the rest from once the zones read them all.
  template <typename Feed>
  class [[tbc::generic]] CommandBlockFeed {
  public:
    // `local` is the user this host's shell runs as and the branch its directory is in, for the
    // commands it starts; a remote shell's come with its marks.
    // NOLINTNEXTLINE(readability-function-size): the ring, the read, the terminal it feeds and how far, and when and where commands start, each its own borrow
    inline CommandBlockFeed(tbc::mut_a<CommandBlockRing> blocks, tbc::val_a<std::span<const Byte>> bytes, tbc::mut_a<Feed> feed, tbc::mut_a<std::size_t> fed, std::chrono::steady_clock::time_point now, tbc::val_a<CommandPlace> local = {}) noexcept
        : blocks_(blocks),
          bytes_(bytes),
          feed_(feed),
          fed_(fed),
          now_(now),
          local_(local) {}

    inline void mark(CommandMark mark) {
      if (mark.end > fed_) {
        feed_(bytes_.subspan(fed_, mark.end - fed_));
        fed_ = mark.end;
      }

      if (!mark.place.remote) {
        mark.place.user = local_.user;
        mark.place.branch = local_.branch;
      }

      blocks_.place(mark, now_);
    }

  private:
    tbc::mut_a<CommandBlockRing> blocks_;
    tbc::val_a<std::span<const Byte>> bytes_;
    tbc::mut_a<Feed> feed_;
    tbc::mut_a<std::size_t> fed_;
    std::chrono::steady_clock::time_point now_;
    tbc::val_a<CommandPlace> local_;
  };

  class CommandBlocks final : public CommandBlockRing {
  public:
    CommandBlocks(ConcurrentMemory& memory, Terminal& terminal);

  private:
    [[nodiscard]] CommandScreen screen() const noexcept override;
    ds::Option<bool> capture(const GhosttySelection& selection) override;
    [[nodiscard]] std::span<const Byte> captured() const noexcept override;

    Terminal& terminal_;
    ds::Vec<Byte, ConcurrentMemory> text_;
  };

  // Captures the commands typed at a pane's prompt, with their directory, duration, status and
  // output. CommandTracker gives it the terminal and the buffers.
  class CommandTrackerCore {
  public:
    CommandTrackerCore(const CommandTrackerCore&) = delete;
    CommandTrackerCore& operator=(const CommandTrackerCore&) = delete;
    CommandTrackerCore(CommandTrackerCore&&) = delete;
    CommandTrackerCore& operator=(CommandTrackerCore&&) = delete;

    std::size_t input(const CommandByteObservation& observation, CapturedCommandEmitter& emitter);
    void output(CommandByteObservation observation, CapturedCommandEmitter& emitter);
    void complete(CommandCompletion completion, CapturedCommandEmitter& emitter);
    void reset() noexcept;
    void resetObservation();
    void updateDirectory(std::string_view directory);
    [[nodiscard]] std::string_view directory() const noexcept;
    [[nodiscard]] bool markersReady() const noexcept;
    [[nodiscard]] bool needsForegroundObservation() const noexcept;

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters takeMetrics() noexcept;
#endif

  protected:
    CommandTrackerCore(ConcurrentMemory& memory, GhosttyTerminal terminal, std::string_view directory, ds::Option<ShellToken> shell_token);
    ~CommandTrackerCore() = default;

  private:
    enum class Phase : std::uint8_t {
      idle,
      editing,
      awaiting_commit,
      running,
    };

    class CompletionRelay;

    static constexpr std::size_t directory_capacity = 4096;

    [[nodiscard]] virtual CommandScreen screen() const noexcept = 0;

    // Feeds the terminal and drops what it would answer.
    virtual void feedTerminal(std::span<const Byte> bytes) = 0;

    // Reads `selection` into the buffer `command` shows.
    virtual ds::Option<bool> capture(const GhosttySelection& selection) = 0;
    [[nodiscard]] virtual std::span<const Byte> command() const noexcept = 0;
    virtual void clearCommand() noexcept = 0;

    // Makes the submitted text the command, whole: the protocol bounds it to the capture's
    // size. False when no text was submitted.
    virtual bool adoptSubmitted() noexcept = 0;
    virtual void clearSubmitted() noexcept = 0;

    // Empty while output capture is off.
    virtual std::span<std::uint8_t> outputStorage() noexcept = 0;

    // `committed`: these bytes end with the newline that started the command, so the marks in
    // them came before it.
    void afterOutput(const CommandByteObservation& observation, CapturedCommandEmitter& emitter, bool committed);

    // Keeps `bytes` of the running command's output, without the shell integration's marks.
    void appendOutput(std::span<const Byte> bytes) noexcept;

    // The command as it stands, for its start and its end.
    [[nodiscard]] CapturedCommand captured() const noexcept;

    // The line the shell committed: the command it holds starts running, or none was captured.
    void commit(CapturedCommandEmitter& emitter);

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters metrics_;
#endif
    CommandSelection selection_;
    CommandZones zones_;
    CommandOutputWindow output_;
    IntegrationMarkFilter marks_;
    CommandInputScanner input_;
    FixedText<directory_capacity> command_directory_;
    ObservationTime started_;
    std::int64_t last_output_ns_ = 0;
    Phase phase_ = Phase::idle;
    bool truncated_ = false;
    // The shell said the command's output ended: what it prints until the command's end mark is
    // its own.
    bool output_ended_ = false;
    bool saw_foreground_child_ = false;
  };

  class CommandTracker final : public CommandTrackerCore {
  public:
    explicit CommandTracker(ConcurrentMemory& memory, Terminal& terminal, std::string_view directory, bool capture_output = false, ds::Option<ShellToken> shell_token = ds::none);

    void enableOutputCapture();

    // The text of the command a client is about to type at the prompt. The submission that
    // follows records it as the command instead of reading the command back from the screen.
    void submitCommand(std::span<const Byte> text);

    // Generic over the caller's sink, as the relay that hands it each command.
    template <CapturedCommandSink Sink>
    [[tbc::generic]] inline std::size_t input(const CommandByteObservation& observation, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      return CommandTrackerCore::input(observation, relay);
    }

    template <CapturedCommandSink Sink>
    [[tbc::generic]] inline void output(CommandByteObservation observation, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      CommandTrackerCore::output(observation, relay);
    }

    template <CapturedCommandSink Sink>
    [[tbc::generic]] inline void complete(CommandCompletion completion, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      CommandTrackerCore::complete(completion, relay);
    }

  private:
    [[nodiscard]] CommandScreen screen() const noexcept override;
    void feedTerminal(std::span<const Byte> bytes) override;
    ds::Option<bool> capture(const GhosttySelection& selection) override;
    [[nodiscard]] std::span<const Byte> command() const noexcept override;
    void clearCommand() noexcept override;
    bool adoptSubmitted() noexcept override;
    void clearSubmitted() noexcept override;
    std::span<std::uint8_t> outputStorage() noexcept override;

    Terminal& terminal_;
    ds::Vec<std::uint8_t, ConcurrentMemory> output_;
    ds::Vec<Byte, ConcurrentMemory> command_;
    // Survives a previous command's completion, which the input typing this one triggers.
    ds::Vec<Byte, ConcurrentMemory> submitted_;
  };

}
