module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "terminal/ghostty_grid.hpp"
#include <ghostty/vt.h>

export module telar.runtime.command_capture.tracker;

import std;
import telar.tbc;
import telar.base.text;
import telar.wire.vocabulary;
import telar.wire.content;
import telar.platform.primitives;
import telar.runtime.terminal.control;

export import telar.platform.events;
export import telar.runtime.history.command;
export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.shell_integration.token;
export import telar.runtime.terminal.text_reader;

// The work is in tracker.cpp, on Memory-free types. What stays here are the shells that the
// runtime's templates instantiate per allocator and per sink, and the tests over SystemAllocator:
// each keeps its terminal and its buffers, and hands the rest to the type it derives from.
export namespace telar::runtime {

  template <typename Sink>
  concept CapturedCommandSink = requires(Sink& sink, const CapturedCommand& command) {
    { sink.emit(command) } -> std::same_as<void>;
  };

  // A CapturedCommandSink behind a virtual call, for the work in tracker.cpp.
  class CapturedCommandEmitter {
  public:
    virtual void emit(const CapturedCommand& command) = 0;

  protected:
    ~CapturedCommandEmitter() = default;
  };

  template <CapturedCommandSink Sink>
  class TBC_HOT_PATH CapturedCommandRelay final : public CapturedCommandEmitter {
  public:
    inline explicit CapturedCommandRelay(tbc::view<Sink&, tbc::lt::a> sink) noexcept
        : sink_(sink) {}

    inline void emit(const CapturedCommand& command) override {
      sink_.emit(command);
    }

  private:
    tbc::view<Sink&, tbc::lt::a> sink_;
  };

  struct CommandByteObservation {
    std::span<const Byte> bytes;
    ObservationTime time;
    std::optional<bool> shell_foreground;
  };

  class CommandInputScanner {
  public:
    struct Event {
      bool submitted = false;
      bool cancelled = false;
    };

    Event feed(std::span<const Byte> bytes) noexcept;
    void reset() noexcept;
    std::optional<std::string_view> typedText() const noexcept;

  private:
    enum class State {
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

    void ground(Byte byte, Event& event) noexcept;
    void beginSequence(Byte byte, bool pasted) noexcept;
    void sequence(Byte byte, bool pasted) noexcept;

    State state_ = State::ground;
    unsigned parameter_ = 0;
    bool has_parameter_ = false;
    std::array<char, 255> typed_{};
    std::size_t typed_count_ = 0;
    bool typed_exact_ = true;
  };

  struct CommandCompletion {
    ObservationTime time;
    std::optional<int> exit_code;
    HistoryStatus status = HistoryStatus::completed;
  };

  template <typename Sink>
  concept CommandCompletionSink = requires(Sink& sink, CommandCompletion completion) {
    { sink.complete(completion) } -> std::same_as<void>;
  };

  // A signed mark (A, B, C or D) and the offset just past it in the bytes fed, for a sink that
  // places it on the terminal those bytes reach. Two more say where the marks come from: N when
  // the shell `ssh` reached takes over, U when the pane's own shell is back.
  struct CommandMark {
    char action = 0;
    std::size_t end = 0;
  };

  // A CommandCompletionSink behind a virtual call, for the scan in tracker.cpp. It receives the
  // marks too, which a sink without `mark` ignores.
  class CommandZoneSink {
  public:
    virtual void complete(CommandCompletion completion) = 0;
    virtual void mark(CommandMark mark) = 0;

  protected:
    ~CommandZoneSink() = default;
  };

  template <CommandCompletionSink Sink>
  class TBC_HOT_PATH CommandZoneRelay final : public CommandZoneSink {
  public:
    inline explicit CommandZoneRelay(tbc::view<Sink&, tbc::lt::a> sink) noexcept
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
    tbc::view<Sink&, tbc::lt::a> sink_;
  };

  class CommandZones {
  public:
    // With a token, only marks signed with it count: the pane's shell integration signs its
    // own, and a program cannot sign the ones it prints.
    explicit CommandZones(std::string_view directory, std::optional<ShellToken> token = std::nullopt);

    std::optional<ShellToken> token() const noexcept;

    // Whether the marks come from a shell on another host, which `ssh` started with telar's
    // integration, and which shell that is.
    bool remote() const noexcept;
    IntegratedShell remoteShell() const noexcept;

    // A shell over scan, for any sink: the sink only hears of a finished sequence, so the
    // bytes are read without a virtual call.
    template <CommandCompletionSink Sink>
    TBC_HOT_PATH inline void feed(std::span<const Byte> bytes, ObservationTime time, Sink& sink) {
      CommandZoneRelay<Sink> relay{sink};

      scan(bytes, time, relay);
    }

    void scan(std::span<const Byte> bytes, ObservationTime time, CommandZoneSink& sink);
    void input(std::span<const Byte> bytes) noexcept;
    bool editing() const noexcept;
    bool markersReady() const noexcept;
    bool running() const noexcept;
    void setDirectory(std::string_view directory);
    std::string_view directory() const noexcept;

    // The PATH the integrated shell last reported; empty until it does.
    std::string_view path() const noexcept;

    // The aliases and functions the shell last reported, blank-separated: names it runs that
    // no PATH directory holds. Null until it reports them, or when they did not fit.
    const std::shared_ptr<const std::string>& names() const noexcept;

    // The host a shell `ssh` reached runs on, as its working directory report names it.
    std::string_view remoteHost() const noexcept;

    // Where that shell works, as it reports it; empty until it does. `directory()` stays this
    // host's.
    std::string_view remoteDirectory() const noexcept;

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters takeMetrics() noexcept;
#endif

  private:
    enum class ParserState {
      ground,
      escape,
      osc,
      osc_escape,
    };
    enum class Zone {
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

    void finishSequence(ObservationTime time, CommandZoneSink& sink, std::size_t end);
    bool privateReport(std::string_view body);
    void semantic(std::string_view body, ObservationTime time, CommandZoneSink& sink, std::size_t end);
    void directoryReport(std::string_view body);

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters metrics_;
#endif
    std::optional<ShellToken> token_;
    std::optional<ShellToken> remote_;
    std::optional<ShellToken> nest_;
    IntegratedShell remote_shell_ = IntegratedShell::none;
    ParserState parser_ = ParserState::ground;
    Zone zone_ = Zone::unknown;
    std::array<char, 16 * 1024> bytes_{};
    std::size_t length_ = 0;
    bool overflow_ = false;
    bool markers_ready_ = false;
    bool has_input_ = false;
    bool running_ = false;
    bool nested_running_ = false;
    FixedText<directory_capacity> directory_;
    FixedText<path_capacity> path_;
    FixedText<host_capacity> host_;
    FixedText<directory_capacity> remote_directory_;
    std::shared_ptr<const std::string> names_;
  };

  // The last bytes of a command's output, kept in storage its owner allocates: empty storage
  // keeps nothing.
  class CommandOutputWindow {
  public:
    static constexpr std::size_t capacity = 64 * 1024;

    void append(std::span<std::uint8_t> storage, std::span<const std::uint8_t> bytes) noexcept;
    tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> storage) const noexcept;
    std::uint64_t observed() const noexcept;
    void clear() noexcept;

  private:
    std::size_t length_ = 0;
    std::uint64_t observed_ = 0;
  };

  template <Allocator Memory>
  class TBC_HOT_PATH CommandOutputTail {
  public:
    static constexpr std::size_t capacity = CommandOutputWindow::capacity;

    inline explicit CommandOutputTail(Memory& memory, bool enabled)
        : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
      if (enabled) {
        enable();
      }
    }

    inline void enable() {
      bytes_.resize(capacity);
    }

    inline void append(std::span<const std::uint8_t> bytes) noexcept {
      window_.append(bytes_, bytes);
    }

    inline std::span<const std::uint8_t> bytes() const noexcept {
      return window_.bytes(bytes_);
    }

    inline std::uint64_t observed() const noexcept {
      return window_.observed();
    }

    inline void clear() noexcept {
      window_.clear();
    }

  private:
    Vector<std::uint8_t, Memory> bytes_;
    CommandOutputWindow window_;
  };

  // The terminal a selection reads, as it is at the call.
  struct CommandScreen {
    GhosttyTerminal terminal = nullptr;
    std::uint16_t columns = 0;
  };

  template <Allocator Memory>
  TBC_HOT_PATH inline CommandScreen commandScreen(Terminal<Memory>& terminal) noexcept {
    return {terminal.handle(), terminal.screen.cols};
  }

  // Receives a formatted selection into a buffer, keeping what fits.
  class CommandTextWriter {
  public:
    explicit CommandTextWriter(tbc::view<std::span<Byte>, tbc::lt::a> destination) noexcept;

    GhosttyWriter ghostty() noexcept;

    // Cuts the text to a whole UTF-8 prefix of at most CommandSelection::maximum_bytes. Whether
    // that cut it short, or nothing when it is empty.
    std::optional<bool> finish() noexcept;
    std::size_t length() const noexcept;

  private:
    static bool receive(void* context, const Byte* bytes, std::size_t count) noexcept;

    tbc::view<std::span<Byte>, tbc::lt::a> destination_;
    std::size_t length_ = 0;
    bool overflow_ = false;
  };

  // The text typed at a prompt, from where the input starts to the cursor, read back from the
  // terminal's screen. Anchors that follow the rows as the terminal scrolls keep where it starts.
  class CommandSelection {
  public:
    static constexpr std::size_t maximum_bytes = 64 * 1024;
    // A buffer that holds maximum_bytes and the rest of a scalar cut at its end.
    static constexpr std::size_t buffer_bytes = maximum_bytes + 4;

    explicit CommandSelection(GhosttyTerminal terminal);

    bool primary(CommandScreen screen) const;
    void begin(CommandScreen screen);
    void rebase(CommandScreen screen, std::optional<std::string_view> typed);

    // What to read from the anchor to the cursor, or nothing when there is no text to read.
    std::optional<GhosttySelection> select(CommandScreen screen) const;

  private:
    using TrackedReference = GhosttyHandle<GhosttyTrackedGridRef, ghostty_tracked_grid_ref_free>;

    void findRightPrompt(CommandScreen screen);
    GhosttyPointCoordinate selectionFinish(CommandScreen screen, GhosttyPointCoordinate start, GhosttyPointCoordinate fallback) const;

    TrackedReference anchor_;
    TrackedReference right_prompt_;
    std::uint64_t right_prompt_hash_ = 0;
    bool right_prompt_active_ = false;
    bool erased_ = false;
  };

  // Reads `selection` into `destination`. Whether it was cut short, or nothing when it is empty.
  template <Allocator Memory>
  TBC_HOT_PATH inline std::optional<bool> captureCommandText(Terminal<Memory>& terminal, const GhosttySelection& selection, Vector<Byte, Memory>& destination) {
    destination.resize(CommandSelection::buffer_bytes);
    CommandTextWriter writer{destination};

    formatTerminalSelection(terminal, selection, true, TrailingSpaces::trimmed, writer.ghostty());
    const auto captured = writer.finish();

    destination.resize(writer.length());
    return captured;
  }

  // The commands a pane's integrated shell ran, each anchored to the row its prompt starts on
  // in the pane's own terminal, so a client can mark them in the scrollback and jump to them.
  // The anchors follow the rows as output scrolls and the scrollback drops its oldest lines.
  // CommandBlocks gives it the terminal and the buffer it reads a command into.
  class CommandBlockRing {
  public:
    static constexpr std::size_t capacity = PaneBlocks::capacity;
    static constexpr std::size_t command_bytes = 160;

    CommandBlockRing(const CommandBlockRing&) = delete;
    CommandBlockRing& operator=(const CommandBlockRing&) = delete;

    // A signed mark, reached by the terminal as the shell printed it.
    void mark(char action, std::chrono::steady_clock::time_point now);

    // The status a D mark reported, for the block it ends: ssh's own, after its session.
    void finished(std::optional<int> status, std::chrono::steady_clock::time_point now);

    // Reads where the blocks are now: output scrolled them, the scrollback dropped some, or a
    // resize reflowed them. Only the oldest is read unless it moved. The anchors are on the
    // primary screen: while a full-screen program has the alternate one, they cannot be read,
    // and they stay as they were.
    void follow(bool reflowed = false);

    std::uint64_t revision() const noexcept;
    PaneBlocks message(std::uint64_t pane_id, std::array<CommandBlock, capacity>& storage) const;

  protected:
    explicit CommandBlockRing(GhosttyTerminal terminal);
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

      GhosttyTrackedGridRef get() const noexcept;
      GhosttyTrackedGridRef* output() noexcept;

    private:
      void release() noexcept;

      GhosttyTrackedGridRef handle_ = nullptr;
    };

    struct Entry {
      TrackedReference anchor;
      std::uint32_t row = 0;
      std::uint16_t rows = 1;
      std::uint16_t lines = 0;
      CommandBlockState state = CommandBlockState::running;
      CommandBlockNest nest = CommandBlockNest::none;
      std::int32_t status = 0;
      std::uint32_t duration_ms = 0;
      std::chrono::steady_clock::time_point started{};
      FixedText<command_bytes> command;
    };

    virtual CommandScreen screen() const noexcept = 0;

    // Reads `selection` into the buffer `captured` shows.
    virtual std::optional<bool> capture(const GhosttySelection& selection) = 0;
    virtual std::span<const Byte> captured() const noexcept = 0;

    Entry& entry(std::size_t index) noexcept;
    const Entry& entry(std::size_t index) const noexcept;
    std::optional<TrackedReference> track();
    std::optional<std::uint32_t> row(const TrackedReference& tracked) const;
    void start(std::chrono::steady_clock::time_point now);
    void finish(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);
    void closeSession(CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);
    void end(Entry& block, CommandBlockState state, std::int32_t status, std::chrono::steady_clock::time_point now);

    CommandSelection selection_;
    std::optional<TrackedReference> prompt_;
    std::array<Entry, capacity> entries_{};
    std::size_t first_ = 0;
    std::size_t count_ = 0;
    std::uint64_t revision_ = 0;
    bool running_ = false;
    // Commands run in the shell ssh reached; that shell just left, and ssh's D ends its block.
    bool nested_ = false;
    bool closing_ = false;
  };

  template <Allocator Memory>
  class TBC_HOT_PATH CommandBlocks final : public CommandBlockRing {
  public:
    inline CommandBlocks(Memory& memory, Terminal<Memory>& terminal)
        : CommandBlockRing(terminal.handle()),
          terminal_(terminal),
          text_(AllocatorRef<Byte, Memory>{memory}) {}

  private:
    inline CommandScreen screen() const noexcept override {
      return commandScreen(terminal_);
    }

    inline std::optional<bool> capture(const GhosttySelection& selection) override {
      return captureCommandText(terminal_, selection, text_);
    }

    inline std::span<const Byte> captured() const noexcept override {
      return text_;
    }

    Terminal<Memory>& terminal_;
    Vector<Byte, Memory> text_;
  };

  // Captures the commands typed at a pane's prompt, with their directory, duration, status and
  // output. CommandTracker gives it the terminal and the buffers.
  class CommandTrackerCore {
  public:
    CommandTrackerCore(const CommandTrackerCore&) = delete;
    CommandTrackerCore& operator=(const CommandTrackerCore&) = delete;

    std::size_t input(const CommandByteObservation& observation, CapturedCommandEmitter& emitter);
    void output(CommandByteObservation observation, CapturedCommandEmitter& emitter);
    void complete(CommandCompletion completion, CapturedCommandEmitter& emitter);
    void reset() noexcept;
    void resetObservation();
    void updateDirectory(std::string_view directory);
    std::string_view directory() const noexcept;
    bool markersReady() const noexcept;
    bool needsForegroundObservation() const noexcept;

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters takeMetrics() noexcept;
#endif

  protected:
    CommandTrackerCore(GhosttyTerminal terminal, std::string_view directory, std::optional<ShellToken> shell_token);
    ~CommandTrackerCore() = default;

  private:
    enum class Phase {
      idle,
      editing,
      awaiting_commit,
      running,
    };

    class CompletionRelay;

    virtual CommandScreen screen() const noexcept = 0;

    // Feeds the terminal and drops what it would answer.
    virtual void feedTerminal(std::span<const Byte> bytes) = 0;

    // Reads `selection` into the buffer `command` shows.
    virtual std::optional<bool> capture(const GhosttySelection& selection) = 0;
    virtual std::span<const Byte> command() const noexcept = 0;
    virtual void clearCommand() noexcept = 0;

    // Makes the submitted text the command, whole: the protocol bounds it to the capture's
    // size. False when no text was submitted.
    virtual bool adoptSubmitted() noexcept = 0;
    virtual void clearSubmitted() noexcept = 0;

    // Empty while output capture is off.
    virtual std::span<std::uint8_t> outputStorage() noexcept = 0;

    void afterOutput(const CommandByteObservation& observation, CapturedCommandEmitter& emitter);

#if TELAR_DIAGNOSTICS
    diagnostics::CommandCaptureCounters metrics_;
#endif
    CommandSelection selection_;
    CommandZones zones_;
    CommandOutputWindow output_;
    CommandInputScanner input_;
    FixedText<4096> command_directory_;
    ObservationTime started_;
    std::int64_t last_output_ns_ = 0;
    Phase phase_ = Phase::idle;
    bool truncated_ = false;
    bool saw_foreground_child_ = false;
  };

  template <Allocator Memory>
  class TBC_HOT_PATH CommandTracker final : public CommandTrackerCore {
  public:
    inline explicit CommandTracker(Memory& memory, Terminal<Memory>& terminal, std::string_view directory, bool capture_output = false, std::optional<ShellToken> shell_token = std::nullopt)
        : CommandTrackerCore(terminal.handle(), directory, shell_token),
          terminal_(terminal),
          output_(AllocatorRef<std::uint8_t, Memory>{memory}),
          command_(AllocatorRef<Byte, Memory>{memory}),
          submitted_(AllocatorRef<Byte, Memory>{memory}) {
      if (capture_output) {
        enableOutputCapture();
      }
    }

    inline void enableOutputCapture() {
      output_.resize(CommandOutputWindow::capacity);
    }

    // The text of the command a client is about to type at the prompt. The submission that
    // follows records it as the command instead of reading the command back from the screen.
    inline void submitCommand(std::span<const Byte> text) {
      submitted_.assign(text.begin(), text.end());
    }

    template <CapturedCommandSink Sink>
    inline std::size_t input(const CommandByteObservation& observation, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      return CommandTrackerCore::input(observation, relay);
    }

    template <CapturedCommandSink Sink>
    inline void output(CommandByteObservation observation, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      CommandTrackerCore::output(observation, relay);
    }

    template <CapturedCommandSink Sink>
    inline void complete(CommandCompletion completion, Sink& sink) {
      CapturedCommandRelay<Sink> relay{sink};

      CommandTrackerCore::complete(completion, relay);
    }

  private:
    inline CommandScreen screen() const noexcept override {
      return commandScreen(terminal_);
    }

    inline void feedTerminal(std::span<const Byte> bytes) override {
      terminal_.feed(bytes);
      terminal_.discardResponses();
    }

    inline std::optional<bool> capture(const GhosttySelection& selection) override {
      return captureCommandText(terminal_, selection, command_);
    }

    inline std::span<const Byte> command() const noexcept override {
      return command_;
    }

    inline void clearCommand() noexcept override {
      command_.clear();
    }

    inline bool adoptSubmitted() noexcept override {
      if (submitted_.empty()) {
        return false;
      }

      command_.swap(submitted_);
      submitted_.clear();
      return true;
    }

    inline void clearSubmitted() noexcept override {
      submitted_.clear();
    }

    inline std::span<std::uint8_t> outputStorage() noexcept override {
      return output_;
    }

    Terminal<Memory>& terminal_;
    Vector<std::uint8_t, Memory> output_;
    Vector<Byte, Memory> command_;
    // Survives a previous command's completion, which the input typing this one triggers.
    Vector<Byte, Memory> submitted_;
  };

}
