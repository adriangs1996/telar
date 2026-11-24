module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.core.model.client_layouts;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.agents.description_generator;
import telar.runtime.terminal.graphics.synchronizer;
import telar.runtime.host.process_probe;
import telar.runtime.terminal.osc_scanner;
import telar.runtime.terminal.text_reader;
import telar.runtime.transport.connection;
import telar.runtime.core.model.slot_store;
import telar.runtime.nvim.editor;
import telar.runtime.nvim.frames;

import telar.runtime.agents.screen_inference;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.terminal.graphics.pane_media;
import telar.runtime.agents.observation.processor;
import telar.runtime.terminal.shell_integration.git_context;
export import :launch_record;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.process;

import telar.base.diagnostics;

import telar.config.runtime;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.editor;
import telar.wire.layout;
import telar.wire.files;
import telar.wire.pane_io;
import telar.wire.worktrees;
import telar.platform.primitives;
import telar.render.document;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.platform.net;
import telar.config.core;
import telar.runtime.terminal.command_capture.tracker;
import telar.runtime.history.event;
import telar.base.ds;

// Interface: model/pending_clipboard.cppm
export {
  namespace telar::runtime {

    class PendingClipboard {
    public:
      static constexpr std::size_t capacity = std::size_t{1024} * 1024;

      explicit PendingClipboard(ConcurrentMemory& memory);

      void replace(std::uint64_t pane, std::span<const Byte> bytes);

      [[nodiscard]] bool pending() const noexcept;

      [[nodiscard]] PaneClipboard message() const noexcept;

      void delivered() noexcept;

    private:
      ds::Vec<Byte, ConcurrentMemory> bytes_;
      std::uint64_t pane_ = 0;
      bool pending_ = false;
    };

  }
}

// Interface: model/client.cppm
export {
  namespace telar::runtime {

    // The inline documents a client has, or is being sent, oldest first, with the rows it last
    // heard each one stands for.
    struct SentDocuments {
      struct Item {
        std::uint64_t id = 0;
        std::uint32_t offset = 0;
        std::uint64_t generation = 0;
        std::uint64_t first_row = 0;
        std::uint32_t rows = 0;
      };

      // A document's item, added when absent, as Rust's entry().or_insert; null once the list is full.
      Item* entry(std::uint64_t id) noexcept;

      void erase(std::size_t index) noexcept;

      // A terminal's inline documents and scrollback numbering at one moment.
      struct Mark {
        std::uint64_t revision = std::numeric_limits<std::uint64_t>::max();
        std::uint64_t generation = 0;
        std::uint64_t trimmed = 0;

        bool operator==(const Mark&) const noexcept = default;
      };

      [[nodiscard]] bool settled(Mark current) const noexcept;

      void settle(Mark current) noexcept;

      ds::Array<Item, ::telar::render::max_pane_documents> items{};
      std::size_t count = 0;
      // The numbering the client is up to date with.
      Mark mark;
    };

    struct Attachment {
      // `media` is the pane's, null for a pane that shows no images.
      explicit Attachment(ConcurrentMemory& memory, GraphicsCreditBudget& budget, std::uint64_t pane, std::shared_ptr<PaneMedia> media);

      std::uint64_t pane_id;
      // What the pane is, which says whose frames an acknowledgment answers.
      PaneKind kind = PaneKind::terminal;
      std::size_t slot = 0;
      FrameSync frames;
      GraphicsSynchronizer graphics;
      ds::Option<std::uint32_t> viewport;
      ds::Option<ConfigurePaneDesktop> desktop;
      bool exit_sent = false;
      std::uint64_t title_revision = 1;
      std::uint64_t cwd_revision = 0;
      std::uint64_t clipboard_revision = 0;
      std::uint64_t foreground_revision = 0;
      std::uint64_t progress_revision = 1;
      std::uint64_t shell_revision = 0;
      std::uint64_t git_revision = 0;
      std::uint64_t blocks_revision = 0;
      SentDocuments inline_documents;
      // The pane document revision this client has, whole once document_offset reaches its size.
      std::uint64_t document_revision = 0;
      std::uint32_t document_offset = 0;
      bool document_whole = true;
      // How the pane's scrollback numbered its rows when this client last heard; generation 0
      // before it heard at all.
      std::uint64_t scrollback_generation = 0;
      std::uint64_t scrollback_trimmed = 0;
      FramePacer pacer;
      // An editor pane's frames: the one this client applied, and the one it was last sent,
      // which it has yet to acknowledge while the two differ. Zero is a client that has none
      // and is sent the screen whole.
      std::uint64_t editor_seen = 0;
      std::uint64_t editor_sent = 0;
      // The count of the editor's prompt this client was last told.
      std::uint64_t editor_prompt = 0;
    };

    // client_layouts.cpp instantiates the constructor for ConcurrentMemory. It is not declared
    // `extern template` here: with that declaration, Clang 23 crashed in importers that emitted
    // ~GraphicsSynchronizer<SystemAllocator> (GetVTTParameter, from runtime-tests' units).

    // The clients a runtime serves at once; a client's slot is its bit in what a pane is observed by.
    inline constexpr std::size_t client_capacity = 32;

    // The panes and workspaces a runtime holds at once.
    inline constexpr std::size_t pane_capacity = 256;
    inline constexpr std::size_t workspace_capacity = 64;

    class Pane;

    class ClientSession {
    public:
      static constexpr std::size_t attachment_capacity = 64;
      static constexpr int default_frames_per_second = 60;

      struct ForegroundStamp {
        std::uint64_t pane = 0;
        std::uint64_t revision = 0;
      };

      explicit ClientSession(ConcurrentMemory& memory, std::uint64_t session_id, FileDescriptor descriptor);

      [[nodiscard]] std::size_t availableAttachmentSlot() const;

      // The bit its slot sets in a pane's observers; none before the client is stored.
      [[nodiscard]] std::uint32_t observerBit() const noexcept;

      [[nodiscard]] const Attachment* attachment(std::uint64_t pane_id) const noexcept;
      Attachment* attachmentMut(std::uint64_t pane_id) noexcept;

      // Whether the runtime verified this client runs inside `pane`, the generation it has now.
      [[nodiscard]] bool verifiedFor(const Pane& pane) const noexcept;

      std::uint64_t id;
      std::uint64_t generation;
      std::uint64_t event_identity = 0;
      std::uint64_t identity = 0;
      GraphicsCreditBudget graphics_credit;
      ClientRole role = ClientRole::undecided;
      std::uint64_t last_input_pane = 0;
      std::uint64_t last_input_sequence = 0;
      ds::Option<PendingClientCommand> pending_command;
      ds::Option<PendingPaneFocus> pending_focus;
      Connection<ConcurrentMemory> connection;
      ds::Vec<ds::Box<Attachment, ConcurrentMemory>, ConcurrentMemory> attachments;
      PendingClipboard clipboard;
      std::size_t next_attachment = 0;
      ds::Option<std::uint64_t> completing_exit;
      bool layout_sent = false;
      bool proxy_status_sent = false;
      bool agent_snapshot_requested = false;
      bool subscribed = false;
      bool shared_graphics = false;
      std::uint64_t editor_source = 0;
      std::uint64_t editor_generation = 0;
      ds::Option<ProcessIdentity> peer_identity;
      std::uint64_t agent_revision = 0;
      std::uint64_t metrics_revision = 0;
      std::uint64_t verified_pane = 0;
      std::uint64_t verified_generation = 0;
      ProcessLineage verified_lineage;
      ds::Option<DescentCheck> pending_descent;
      bool descent_running = false;
      DeferredReport<ConcurrentMemory> deferred_report;
      unsigned limit_reports = 0;
      std::chrono::steady_clock::time_point limit_report_window;
      ds::Option<std::uint64_t> workspace;
      std::chrono::nanoseconds frame_interval{std::chrono::nanoseconds{std::chrono::seconds{1}} / default_frames_per_second};
      std::uint64_t workspace_revision = 0;
      std::uint64_t agent_workspace_revision = 0;
      std::uint64_t pane_revision = 0;
      std::uint64_t pane_workspace_revision = 0;
      ds::Option<ResyncRequired> workspace_resync;
      ds::Array<ForegroundStamp, pane_capacity> foregrounds;
      ds::Option<TextSearch> search;
      ConfigureTerminalColors colors{};
      // The client draws telar's editor in place of the shell's prompt: shells it starts print none.
      bool bare_prompt = false;
      HeldTabs held_tabs;
    };

  }
}

// Interface: model/pane.cppm
export {
  namespace telar::runtime {

    // What a pane whose program runs on a PTY has of its own: the terminal the program writes
    // to and what the runtime reads of it. It changes nothing of what every pane has: what
    // changes both is a function of the pane as a terminal, `PaneRef<TerminalBody>`.
    class TerminalBody {
      // The default writer of write: writev on the PTY.
      struct ResponseWriter {
        ssize_t operator()(int descriptor, std::span<const iovec> vectors) const;
      };

    public:
      static constexpr PaneKind pane_kind = PaneKind::terminal;

      enum class ReadMode : std::uint8_t {
        once,
        burst,
      };

      explicit TerminalBody(ConcurrentMemory& memory, std::uint64_t identity, const Command<ConcurrentMemory>& command, const PaneLaunch& settings);

      // Starts the pane's program, once the body is in its pane; the process it started.
      pid_t start(ConcurrentMemory& memory, Command<ConcurrentMemory>& command, const PaneLaunch& settings);

      // Reads what the program wrote; false once its output closed.
      bool read(ReadMode mode = ReadMode::once);

      // Reads where the integrated shell is and how the line discipline is set, and counts a
      // change. Two ioctls; the runtime calls it after output and, while a program runs, on its
      // tick, since a program can change the terminal without printing.
      void observeShell() noexcept;

      // The response writer borrows vectors only for this call. Only a positive
      // syscall result consumes the admitted prefix; EINTR/EAGAIN retain it.
      // Generic over the caller's writer: control_desktop_test passes its own.
      template <typename WriteResponses = ResponseWriter>
      TBC_GENERIC inline void write(WriteResponses write_responses = {}) {
        const auto batch = pty_responses->peekBatch();
        const bool response = batch.count != 0;
        const auto bytes = input.readable();

        if (response && batch.bytes == 0) {
          pty_responses->consumeBytes(0);
          terminal.resumeControl(*media);
          return;
        }

        if (!response && bytes.empty()) {
          return;
        }

        const auto count = [&] {
          TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->input_write});
          if (response) {
            ds::Array<iovec, PtyResponseQueue::message_capacity> vectors; // NOLINT(cppcoreguidelines-pro-type-member-init): the PTY write path fills the batch's vectors, the only ones writev reads

            for (std::size_t index = 0; index < batch.count; ++index) {
              const auto message = batch.message(index);

              vectors.atMut(index) = {.iov_base = const_cast<Byte*>(message.data()), .iov_len = message.size()}; // NOLINT(cppcoreguidelines-pro-type-const-cast): iovec's base is non-const for readv, and writev only reads through it
            }

            return write_responses(process->descriptor(), std::span<const iovec>{vectors}.first(batch.count));
          }

          return ::write(process->descriptor(), bytes.data(), bytes.size());
        }();
        if (count > 0) {
          if (response) {
            pty_responses->consumeBytes(static_cast<std::size_t>(count));
            terminal.resumeControl(*media);
          } else {
            input.consume(static_cast<std::size_t>(count));
            // A remote line editor echoes what it reads: the next output times the link.
            if (shell_state.remote && shell_zones && shell_zones->editing() && !echo_sent) {
              echo_sent = std::chrono::steady_clock::now();
            }
          }

          return;
        }

        if (count < 0 && socketWouldBlock(sys::lastError())) {
          return;
        }

        input.clear();
        pty_responses->clear();
        throw std::system_error{count < 0 ? sys::lastError() : EIO, std::generic_category(), "PTY write failed"};
      }

      bool hasInput() const noexcept;

      // Ends the program, as closing its pane does.
      void endProgram() noexcept;

      void enqueueInput(std::span<const Byte> bytes);

      // The text of the command a client runs at the prompt, recorded before the bytes that type it,
      // so the command's history keeps it instead of reading it back from the screen.
      void submitCommand(std::span<const Byte> text);

      // The terminal feeds the pane's media as it resumes.
      void resumeControl();

      // False when the terminal has that size already.
      bool resize(TerminalSize size);

      ds::Option<bool> shellForeground() const noexcept;

      static constexpr std::size_t input_limit = std::size_t{128} * 1024;
      static constexpr std::size_t read_buffer_size = std::size_t{16} * 1024;
#if TELAR_DIAGNOSTICS
      diagnostics::PaneCounters* counters = nullptr;
      std::uint64_t input_dropped_bytes = 0;
#endif
      // The link's round trip so far, smoothed, which echo_sent times.
      double link_average_ms = 0;
      // Zero until the pane has an integrated shell: other panes never send their state.
      std::uint64_t shell_revision = 0;
      std::chrono::steady_clock::time_point sync_started;
      std::shared_ptr<PtyResponseQueue> pty_responses;
      std::shared_ptr<PaneObserver> observer;
      std::shared_ptr<PaneMedia> media;
      // When input last reached a remote shell's line editor, until its echo arrives.
      ds::Option<std::chrono::steady_clock::time_point> echo_sent;
      ByteQueue<ConcurrentMemory> input;
      // The integrated shell's own reading of its signed marks, on the runtime's thread so its
      // state reaches clients with the output that changed it.
      ds::Option<CommandZones> shell_zones;
      // Its host and directory view `shell_zones`' fixed buffers, made once with the pane.
      tbc::val_self<PaneShell> shell_state{};
      // Reports its graphics queries to media.
      tbc::val_self<Terminal> terminal;
      // The commands it ran, anchored in `terminal`, which outlives them.
      ds::Option<CommandBlocks> blocks;
      // Reads rows of `terminal`'s scrollback for clients that ask for them.
      ScrollbackRows scrollback_rows;
      ds::Option<PtyProcess> process;
      bool shell_markers = false;
      bool needs_foreground_observation = false;
      // The shell the pane started, which an `ssh` session it nests stands in for.
      IntegratedShell local_shell = IntegratedShell::none;

    private:
      // Counts the commands the integrated shell finished, for its clients, and keeps the marks
      // the bytes held, for the command blocks. A mark past the last kept one is not placed.
      struct ShellCompletions {
        struct Mark {
          char action = 0;
          std::size_t end = 0;
          ds::Option<int> status;
        };

        static constexpr std::size_t kept_capacity = 16;

        PaneShell& state;
        ds::Array<Mark, kept_capacity> kept{};
        std::size_t count = 0;

        void complete(CommandCompletion completion) noexcept;

        void mark(CommandMark mark) noexcept;

        [[nodiscard]] std::span<const Mark> marks() const noexcept;
      };

      // Hands a read's bytes to the shell's marks, the observer and the terminal.
      void ingest(std::span<const Byte> bytes, bool folded);

      // Feeds the terminal up to each signed mark, so a command's block anchors where its mark was printed.
      void feedMarks(std::span<const Byte> bytes, const ShellCompletions& completions);

      // Folds one round trip into the link's; clients hear of it when it moves by a tenth.
      void timeLink(std::chrono::steady_clock::duration elapsed) noexcept;

      void expireProgress(ds::Option<bool> shell_foreground) noexcept;

#if TELAR_DIAGNOSTICS
      void recordRead(std::size_t size, bool folded) noexcept;
#endif
    };

    // What a pane that shows a Neovim has of its own: the Neovim the runtime started with
    // --embed and is the only UI of. What Neovim draws is kept in `editor` and reaches clients
    // grid by grid, drawn natively.
    class NvimBody {
    public:
      static constexpr PaneKind pane_kind = PaneKind::nvim;
      // The bytes one read takes from Neovim, and the reads one event takes before other panes
      // have their turn.
      static constexpr std::size_t read_buffer_size = std::size_t{64} * 1024;
      static constexpr unsigned read_burst = 8;

      explicit NvimBody(ConcurrentMemory& memory, TerminalSize size);

      // How a read of what Neovim wrote ended: there may be more, the read failed, or Neovim
      // closed its output or wrote what the editor refuses.
      enum class Read : std::uint8_t {
        open,
        failed,
        closed,
      };

      // Starts Neovim, once the body is in its pane; the process it started.
      pid_t start(Command<ConcurrentMemory>& command, TerminalSize size);

      // Reads what Neovim wrote and applies it to the editor's screen.
      Read read();

      // Reads and drops what Neovim wrote to its standard error; false once that closed.
      bool readErrors() noexcept;

      // Writes the requests the editor queued to Neovim's input, as many as it takes now.
      void write();

      [[nodiscard]] bool hasInput() const noexcept;

      // Asks Neovim to leave, as closing its pane does.
      void endProgram() noexcept;

      NvimEditor editor;
      ds::Option<PipeProcess> process;
      // The flush that set the directory the pane last took from Neovim.
      std::uint64_t directory_at = 0;
      // The client that last drove the editor: what Neovim says back is for it.
      std::uint64_t driver = 0;

      // A client's question about the editor's buffers, until Neovim lists them.
      struct BufferQuery {
        std::uint64_t client = 0;
        std::uint64_t request_id = 0;
        std::uint16_t limit = 0;
        FixedText<FindPaths::maximum_query_bytes> query;
      };

      ds::Option<BufferQuery> buffer_query;
    };

    // What a pane that is the explorer of a window has of its own: the windows the explorer is
    // split into, as the last window that showed it gave them. It runs no program, so it reads
    // nothing and nothing is written to it: a window draws it from what it knows of the files.
    class ExplorerBody {
    public:
      static constexpr PaneKind pane_kind = PaneKind::explorer;

      explicit ExplorerBody(ConcurrentMemory& memory);

      // Keeps the windows a client gives. Ones that name no window, or a current one that is
      // none of them, are refused, and what was kept stays.
      void keep(const ExplorerLayout& layout);

      // What is kept, as a KeepExplorer encodes it; empty before a client gave any.
      [[nodiscard]] std::span<const Byte> kept() const noexcept;

      // It has no program to ask.
      void endProgram() noexcept;

    private:
      ds::Vec<Byte, ConcurrentMemory> kept_;
    };

    // A pane: what every pane has, whatever its kind, which is where it is, the process it
    // started and what the runtime reports of both, and `body`, the state of the kind it is. Code
    // that needs that state asks for the body by name, `as<TerminalBody>()`, and gets none from a
    // pane of another kind.
    class Pane {
    public:
      // A terminal, whose program `command` is.
      explicit Pane(ConcurrentMemory& memory, std::uint64_t identity, TabLocation tab, Command<ConcurrentMemory>& command, PaneLaunch settings);

      // An editor, whose Neovim `command` is.
      explicit Pane(ConcurrentMemory& memory, std::uint64_t identity, TabLocation tab, Command<ConcurrentMemory>& command, TerminalSize size);

      // An explorer, which is drawn at `size` and whose windows start from `directory`.
      struct Explorer {
        std::string_view directory;
        TerminalSize size{};
      };

      explicit Pane(ConcurrentMemory& memory, std::uint64_t identity, TabLocation tab, Explorer explorer);

      ~Pane() = default;

      Pane(const Pane&) = delete;
      Pane& operator=(const Pane&) = delete;
      Pane(Pane&&) = delete;
      Pane& operator=(Pane&&) = delete;

      // The body of the kind `Body` names; null when the pane is of another kind.
      template <typename Body>
      TBC_GENERIC [[nodiscard]] inline const Body* as() const noexcept {
        return std::get_if<Body>(&body);
      }

      template <typename Body>
      TBC_GENERIC [[nodiscard]] inline Body* asMut() noexcept {
        return std::get_if<Body>(&body);
      }

      [[nodiscard]] PaneKind kind() const noexcept;

      [[nodiscard]] ds::Option<std::int32_t> exitCode() const noexcept;

      // The bytes of the foreground program's name the pane list shows.
      static constexpr std::size_t foreground_bytes = 48;
      std::uint64_t id;
      std::uint64_t event_identity = 0;
      std::uint64_t generation = 1;
      std::uint64_t cwd_revision = 0;
      std::uint64_t input_revision = 0;
      std::uint64_t foreground_revision = 1;
      // Since when foreground_group holds the terminal, as the pane list reports it.
      std::chrono::steady_clock::time_point foreground_since = std::chrono::steady_clock::now();
      // When listening_ports were last read.
      std::chrono::steady_clock::time_point ports_checked;
      std::uint64_t git_revision = 0;
      ds::Option<std::uint64_t> worktree_checked_cwd;
      ds::Option<std::chrono::steady_clock::time_point> last_input;
      TabLocation location;
      ds::String<ConcurrentMemory> cwd;
      LaunchRecord<ConcurrentMemory> launch;
      FixedText<foreground_bytes> foreground;
      ds::Option<ConfigurePaneDesktop> desktop_theme;
      ProcessCache process_cache;
      ds::Option<AgentResume> restored_agent;
      // The repository the pane works in, read after each command; zero until read.
      ShellGitSummary git{};
      FixedText<PATH_MAX> git_directory;
      // The cells the pane's program draws on.
      TerminalSize extent{};
      std::uint32_t observers = 0;
      // The process the pane started; zero while it has none.
      pid_t process_id = 0;
      // The process group in the foreground of the pane's program, as the pane list reports it.
      pid_t foreground_group = 0;
      std::uint32_t git_commands = std::numeric_limits<std::uint32_t>::max();
      std::uint32_t process_rechecks = 0;
      ds::Option<int> exit_status;
      ds::Option<RejectedReporter> rejected_reporter;
      // The TCP ports that process group listens on.
      ListeningPorts listening_ports;
      bool foreground_shell = true;
      bool output_closed = false;
      bool exit_observed = false;
      bool write_interest = false;
      bool read_paused = false;
      bool close_requested = false;
      bool process_recheck_requested = false;
      bool process_recheck_running = false;
      ds::Array<Byte, history_session_bytes> history_session{};

      // The state of the kind the pane is. Last, so that a body is made in a pane whose every
      // other member is.
      std::variant<TerminalBody, NvimBody, ExplorerBody> body;
    };

    // A pane a request works on as one kind: what every pane has and the state of that kind. A
    // const Body borrows a pane that is not changed.
    template <typename Body>
    struct PaneRef {
      std::conditional_t<std::is_const_v<Body>, const Pane, Pane>& core;
      Body& body;

      // As a reference to a value is also one to the value unchanged.
      TBC_HOT_PATH [[nodiscard]] inline operator PaneRef<const Body>() const noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): as T& is a const T&
        requires(!std::is_const_v<Body>)
      {
        return {.core = core, .body = body};
      }
    };

    // Calls `visitor` with the body of the kind the pane is. A kind the visitor has no overload
    // for does not compile, so a new kind is decided at every visit; the assertion says where to
    // add one.
    template <typename Visitor>
    TBC_GENERIC inline void visitPane(Pane& pane, Visitor&& visitor) {
      static_assert(std::variant_size_v<decltype(pane.body)> == 3, "a new kind of pane is visited here");

      if (auto* terminal = std::get_if<TerminalBody>(&pane.body)) {
        std::forward<Visitor>(visitor)(*terminal);
        return;
      }

      if (auto* editor = std::get_if<NvimBody>(&pane.body)) {
        std::forward<Visitor>(visitor)(*editor);
        return;
      }

      std::forward<Visitor>(visitor)(*std::get_if<ExplorerBody>(&pane.body));
    }

    template <typename Visitor>
    TBC_GENERIC inline void visitPane(const Pane& pane, Visitor&& visitor) {
      static_assert(std::variant_size_v<decltype(pane.body)> == 3, "a new kind of pane is visited here");

      if (const auto* terminal = std::get_if<TerminalBody>(&pane.body)) {
        std::forward<Visitor>(visitor)(*terminal);
        return;
      }

      if (const auto* editor = std::get_if<NvimBody>(&pane.body)) {
        std::forward<Visitor>(visitor)(*editor);
        return;
      }

      std::forward<Visitor>(visitor)(*std::get_if<ExplorerBody>(&pane.body));
    }

    // Calls `visitor` with the pane as the kind it is, for what works on a kind's state and on
    // the pane's.
    template <typename Visitor>
    TBC_GENERIC inline void visitPaneAs(Pane& pane, Visitor&& visitor) {
      visitPane(pane, [&]<typename Body>(Body& body) {
        std::forward<Visitor>(visitor)(PaneRef<Body>{.core = pane, .body = body});
      });
    }

    // The pane as the kind `Body` names; none for no pane and for a pane of another kind.
    template <typename Body>
    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<Body>>> paneAs(tbc::val_a<Pane*> pane) noexcept {
      auto* const body = pane == nullptr ? nullptr : pane->asMut<Body>();

      return body == nullptr ? ds::Option<PaneRef<Body>>{} : ds::Option<PaneRef<Body>>{PaneRef<Body>{.core = *pane, .body = *body}};
    }

    template <typename Body>
    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<const Body>>> paneAs(tbc::val_a<const Pane*> pane) noexcept {
      const auto* const body = pane == nullptr ? nullptr : pane->template as<Body>();

      return body == nullptr ? ds::Option<PaneRef<const Body>>{} : ds::Option<PaneRef<const Body>>{PaneRef<const Body>{.core = *pane, .body = *body}};
    }

    // The terminal a pane is; none for no pane and for a pane of another kind.
    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<TerminalBody>>> asTerminal(tbc::val_a<Pane*> pane) noexcept {
      return paneAs<TerminalBody>(pane);
    }

    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<const TerminalBody>>> asTerminal(tbc::val_a<const Pane*> pane) noexcept {
      return paneAs<TerminalBody>(pane);
    }

    // The editor a pane is; none for no pane and for a pane of another kind.
    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<NvimBody>>> asNvim(tbc::val_a<Pane*> pane) noexcept {
      return paneAs<NvimBody>(pane);
    }

    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<const NvimBody>>> asNvim(tbc::val_a<const Pane*> pane) noexcept {
      return paneAs<NvimBody>(pane);
    }

    // The explorer a pane is; none for no pane and for a pane of another kind.
    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<ExplorerBody>>> asExplorer(tbc::val_a<Pane*> pane) noexcept {
      return paneAs<ExplorerBody>(pane);
    }

    TBC_HOT_PATH [[nodiscard]] inline tbc::val_a<ds::Option<PaneRef<const ExplorerBody>>> asExplorer(tbc::val_a<const Pane*> pane) noexcept {
      return paneAs<ExplorerBody>(pane);
    }

    // The bytes the windows of an explorer pane are decoded into.
    using ExplorerScratch = ds::Array<Byte, FileLimits::explorer_windows * sizeof(ExplorerWindow)>;

    // The windows an explorer pane keeps, as a client is told them; none for a pane of another
    // kind, and for an explorer no client gave any. They view `scratch` and the pane.
    [[nodiscard]] tbc::val_a<ds::Option<ExplorerKept>> explorerKept(tbc::ref_a<Pane> pane, tbc::mut_a<ExplorerScratch> scratch);

    // What changes a kind's state and the pane's with it.

    // Reads what the terminal's program wrote; false once its output closed.
    bool read(PaneRef<TerminalBody> pane, TerminalBody::ReadMode mode = TerminalBody::ReadMode::once);

    // Reads what Neovim wrote and applies it to the editor's screen. False once Neovim closed its
    // output, or wrote what the editor refuses: the pane is then to be closed.
    bool read(PaneRef<NvimBody> pane);

    // Queues bytes for the terminal's program, as input a client typed.
    void enqueueInput(PaneRef<TerminalBody> pane, std::span<const Byte> bytes);

    void resize(PaneRef<TerminalBody> pane, TerminalSize size);

    void resize(PaneRef<NvimBody> pane, TerminalSize size);

    // An explorer keeps the size its window draws it at, and tells no program.
    void resize(PaneRef<ExplorerBody> pane, TerminalSize size) noexcept;

    // Asks a pane's program to end, as closing the pane does, whatever its kind.
    void requestClose(Pane& pane) noexcept;

    // The exit status of a pane's process once it ended; none while it runs.
    ds::Option<int> reapProcess(Pane& pane) noexcept;

    // Sends a signal to a pane's process.
    void signalProcess(const Pane& pane, int number) noexcept;

    // What the pane's program titled it, and a count of the times it changed.
    struct ProgramTitle {
      std::string_view text;
      std::uint64_t revision = 0;
    };

    ProgramTitle programTitle(const Pane& pane) noexcept;

  }
}

// Interface: model/runtime_limits.cppm
export {
  namespace telar::runtime {

    struct RuntimeLimits {
      LimitLedger runtime;
      LimitLedger clients;
      std::uint64_t refused_reports = 0;
    };

  }
}

// Interface: model/workspace.cppm
export {
  namespace telar::runtime {

    struct Tab {
      explicit Tab(ConcurrentMemory& memory, std::uint64_t identity, std::string_view name);

      std::uint64_t id;
      ds::String<ConcurrentMemory> label;
      ds::Vec<std::uint64_t, ConcurrentMemory> panes;
    };

    // What a workspace starts from: its id, its directory and its name, which it copies.
    struct WorkspaceSpec {
      std::uint64_t id = 0;
      std::string_view path;
      std::string_view name;
    };

    class Workspace {
    public:
      explicit Workspace(ConcurrentMemory& memory, WorkspaceSpec spec);

      Tab* tabMut(std::uint64_t tab_id) noexcept;

      [[nodiscard]] const Tab* tab(std::uint64_t tab_id) const noexcept;

      [[nodiscard]] std::string_view displayName() const noexcept;

      static constexpr std::size_t git_branch_bytes = 200;

      std::uint64_t id;
      ds::String<ConcurrentMemory> path;
      ds::String<ConcurrentMemory> name;
      ds::Vec<Tab, ConcurrentMemory> tabs;
      ds::Option<std::uint64_t> geometry_client;
      FixedText<git_branch_bytes> git_branch;
      std::chrono::steady_clock::time_point git_checked_at;
      bool git_dirty = false;
      bool git_timed_out = false;
    };

  }
}

// Interface: model/worktrees.cppm
export {
  namespace telar::runtime {

    struct Worktree {
      explicit Worktree(ConcurrentMemory& memory, std::uint64_t identity, const RegisterWorktree& request);

      [[nodiscard]] WorktreeListEntry entry() const noexcept;

      static constexpr std::size_t branch_bytes = 200;
      static constexpr std::size_t title_bytes = 96;
      static constexpr std::size_t brief_bytes = 512;
      static constexpr std::size_t dispatched_from_bytes = 32;
      static constexpr std::size_t command_label_bytes = 48;

      std::uint64_t id;
      std::uint64_t source;
      ds::Option<std::uint64_t> workspace;
      ds::Option<std::uint64_t> created_by;
      ds::Option<CoordinatorReference> coordinator;
      WorktreeOrigin origin;
      WorktreeState state = WorktreeState::active;
      ds::String<ConcurrentMemory> path;
      FixedText<branch_bytes> branch;
      FixedText<branch_bytes> base;
      FixedText<title_bytes> title;
      FixedText<brief_bytes> brief;
      FixedText<dispatched_from_bytes> dispatched_from;
      FixedText<command_label_bytes> command_label;
      std::uint32_t diff_added = 0;
      std::uint32_t diff_removed = 0;
      std::uint32_t diff_files = 0;
      std::uint32_t commits_ahead = 0;
      unsigned probe_failures = 0;
      bool had_changes = false;
      std::chrono::steady_clock::time_point checked_at;
      CommandState command_state = CommandState::none;
      std::int32_t command_exit = 0;
      ds::Option<std::uint64_t> command_pane;
    };

    class Worktrees {
    public:
      explicit Worktrees(ConcurrentMemory& memory);

      WorktreeRegistered registerEntry(const RegisterWorktree& request, std::uint64_t restored_identity = 0);

      Worktree* find(std::uint64_t identity) noexcept;

      [[nodiscard]] std::span<Worktree* const> items() const noexcept;

      void remove(std::uint64_t identity) noexcept;

      Worktree* containing(std::string_view path) noexcept;

      [[nodiscard]] std::uint64_t sourceFor(std::uint64_t workspace) const noexcept;

      static constexpr std::size_t capacity = 64;

    private:
      static constexpr std::size_t reserved_for_telar = 16;
      ConcurrentMemory& memory_;
      SlotStore<Worktree, capacity, ConcurrentMemory> entries_;
    };

  }
}

// Interface: model/runtime_model.cppm
export {
  namespace telar::runtime {

    // The runtime's tables. Functions take the ones they read or change, so the borrows they keep of one
    // table are not disturbed by another, as Rust's disjoint field borrows are.
    using PaneStore = SlotStore<Pane, pane_capacity, ConcurrentMemory>;
    using ClientStore = SlotStore<ClientSession, client_capacity, ConcurrentMemory>;
    using WorkspaceStore = SlotStore<Workspace, workspace_capacity, ConcurrentMemory>;

    // Calls `send` for each open client `admits` accepts. A client whose send throws is closed: its
    // connection may hold part of a frame, and every broadcast treats that failure alike.
    // Generic over the caller's predicate and sender, and run for every message sent to all clients. Takes
    // both themselves, as the lambdas callers pass build them in place.
    template <typename Admits, typename Send>
    TBC_GENERIC inline void deliver(ClientStore& clients, Admits admits, Send send) noexcept {
      for (auto* client : clients.items()) {
        if (client == nullptr || client->connection.flags().closing || !admits(*client)) {
          continue;
        }

        try {
          send(*client);
        } catch (...) {
          client->connection.flagsMut().closing = true;
        }
      }
    }

    // Sends `message` to each open client `admits` accepts, as deliver does; how many queued it.
    // Generic over the caller's predicate and message, as deliver.
    template <typename Admits, typename Message>
    TBC_GENERIC inline std::size_t broadcast(ClientStore& clients, Admits admits, const Message& message) noexcept {
      std::size_t delivered = 0;

      deliver(clients, admits, [&](ClientSession& client) {
        delivered += client.connection.trySend(message);
      });

      return delivered;
    }

    // Whether a live client holds a tab.
    bool tabHeld(const ClientStore& clients, TabLocation location) noexcept;

    // The stored client with an identity, which a request names.
    ClientSession& requireClient(const ClientStore& clients, std::uint64_t identity);

    // The pane `key` names while it has the key's generation; none for another generation. No pane
    // has generation 0, so 0 finds none.
    tbc::val_a<Pane*> findPane(tbc::mut_a<PaneStore> panes, PaneKey key) noexcept;

    tbc::val_a<const Pane*> findPane(tbc::ref_a<PaneStore> panes, PaneKey key) noexcept;

    // The same pane while its process runs and nobody asked it to close.
    tbc::val_a<Pane*> livePane(tbc::mut_a<PaneStore> panes, PaneKey key) noexcept;

    tbc::val_a<const Pane*> livePane(tbc::ref_a<PaneStore> panes, PaneKey key) noexcept;

    // The terminal a request names by id: a request that only a terminal answers is refused for
    // a pane of another kind, and for an id that names none.
    tbc::val_a<PaneRef<TerminalBody>> requireTerminal(tbc::mut_a<PaneStore> panes, std::uint64_t identity);

    // The terminal `pane` is, as a request that only a terminal answers needs it.
    tbc::val_a<PaneRef<TerminalBody>> requireTerminal(tbc::mut_a<Pane> pane);

    // The editor a request names by id, refused as requireTerminal refuses.
    tbc::val_a<PaneRef<NvimBody>> requireNvim(tbc::mut_a<PaneStore> panes, std::uint64_t identity);

    // The explorer the pane `identity` is: a request only an explorer answers is refused for a
    // pane of another kind.
    tbc::val_a<PaneRef<ExplorerBody>> requireExplorer(tbc::mut_a<PaneStore> panes, std::uint64_t identity);

    // The pane an agent's report names, which must still run the generation it names and be the one
    // the runtime verified the reporting client inside.
    tbc::mut_a<Pane> requireReporterPane(tbc::mut_a<PaneStore> panes, const ClientSession& client, PaneKey key);

    // The runtime's data apart from its clients, whose table is separate so that a call can borrow one
    // client and the model at once, as Rust borrows two fields of a struct.
    struct RuntimeModel {
      explicit RuntimeModel(ConcurrentMemory& memory, GraphicsLimits graphics = {});

      GraphicsLimits graphics_limits;
      RuntimeLimits limits;
      // The buffers an editor pane's frames are written in, one set for every pane and client.
      NvimFrames editor_frames;
      [[no_unique_address]] diagnostics::RuntimeCounters metrics;
      MediaBudget media_budget;
      AgentManifests manifests = builtinManifests();
      std::string_view cli_executable;
      bool capture_output = false;
      PaneStore panes;
      WorkspaceStore workspaces;
      Worktrees worktrees;
      ExitedPanes exited_panes;
      std::shared_ptr<PaneObserver> retired_observers;
      std::size_t retired_observer_count = 0;
      std::shared_ptr<PaneMedia> retired_media;
      std::size_t retired_media_count = 0;
      std::uint64_t next_tab_id = 1;
      std::uint64_t workspace_revision = 1;
      // Advances when a pane joins or leaves the pane list or its foreground process changes.
      std::uint64_t pane_revision = 1;
      std::uint64_t next_pane_generation = 1;
      std::uint64_t input_sequence = 0;
      bool stopping = false;
    };

  }
}

// Interface: model/client_layouts.cppm
export {
  namespace telar::runtime {

    class ClientLayouts {
    public:
      explicit ClientLayouts(ConcurrentMemory& memory);

      void retain(const RuntimeModel& model, std::uint64_t identity, const UpdateClientLayout& update);

      void publish(const RuntimeModel& model, ClientSession& client);

      [[nodiscard]] ds::Option<std::uint64_t> focusedPane(std::uint64_t identity) const noexcept;

      // The marks and the jump list of a window's explorer, kept for the windows that come after
      // it: one set for the runtime, which the last window to give one replaces. Places that say
      // more than the runtime keeps are not taken, and what was kept stays.
      void keepPlaces(const KeepPlaces& places);

      // Answers a window what is kept.
      void publishPlaces(std::uint64_t request, ClientSession& client) const;

      // What is kept, as the message that gave it encodes; empty when nothing is.
      [[nodiscard]] std::span<const Byte> places() const noexcept;

      [[nodiscard]] std::uint64_t revision() const noexcept;

      // Generic over the caller's consumer, which each record is handed to. Takes the consumer itself, as
      // the lambda callers pass builds it in place.
      template <typename Consumer>
      TBC_GENERIC inline void exportRecords(const RuntimeModel& model, Consumer consume) const {
        ds::Array<ClientTabLayout, maximum_tabs> tabs;

        for (const auto& record : records_) {
          std::size_t count = 0;
          bool active_valid = false;

          for (std::size_t index = 0; index < record.tab_count; ++index) {
            const auto tab = record.tabAt(index);
            if (!current(model, tab)) {
              continue;
            }

            tabs.atMut(count++) = tab;
            active_valid |= sameLocation(tab.location, record.active_tab);
          }

          if (!active_valid) {
            continue;
          }

          consume(record.identity, record.last_used, UpdateClientLayout{.sidebar_visible = record.sidebar_visible, .sidebar_width = record.sidebar_width, .workspace_list_collapsed = record.workspace_list_collapsed, .active_tab = record.active_tab, .tabs = std::span{tabs}.first(count)});
        }
      }

    private:
      static constexpr std::size_t maximum_identities = 16;
      static constexpr std::size_t maximum_tabs = max_layout_tabs;
      static constexpr std::size_t maximum_nodes = max_retained_layout_nodes;

      struct StoredTab {
        TabLocation location;
        std::uint64_t focused_pane = 0;
        bool fullscreen = false;
        bool workspace_active = false;
        std::uint16_t node_start = 0;
        std::uint16_t node_count = 0;
      };

      struct Record {
        std::uint64_t identity = 0;
        std::uint64_t last_used = 0;
        bool sidebar_visible = true;
        std::uint16_t sidebar_width = 0;
        bool workspace_list_collapsed = false;
        TabLocation active_tab{};
        ds::Array<StoredTab, maximum_tabs> tabs{};
        ds::Array<ClientLayoutNode, maximum_nodes> nodes{};
        std::size_t tab_count = 0;
        std::size_t node_count = 0;

        [[nodiscard]] ClientTabLayout tabAt(std::size_t index) const noexcept;

        void append(const ClientTabLayout& tab);
      };

      static bool sameWorkspace(WorkspaceLocation left, WorkspaceLocation right) noexcept;

      static bool sameLocation(TabLocation left, TabLocation right) noexcept;

      static bool current(const RuntimeModel& model, const ClientTabLayout& layout) noexcept;

      Record* find(std::uint64_t identity) noexcept;

      ds::Vec<Record, ConcurrentMemory> records_;
      ds::Vec<Byte, ConcurrentMemory> places_;
      std::uint64_t clock_ = 0;
    };

  }
}
