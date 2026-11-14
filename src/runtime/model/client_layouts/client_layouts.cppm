module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_render/sequence.hpp"
#include <cerrno>
#include <limits.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

export module telar.runtime.model.client_layouts;

import std;
import telar.sys.posix;
import telar.tbc;

export import telar.runtime.agents.description_generator;
export import telar.runtime.graphics.synchronizer;
export import telar.runtime.platform.process_probe;
export import telar.runtime.terminal.osc_scanner;
export import telar.runtime.terminal.text_reader;
export import telar.runtime.transport.connection;
export import telar.runtime.model.slot_store;

export import telar.runtime.agents.screen_inference;
export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.graphics.pane_media;
export import telar.runtime.observation.processor;
export import telar.runtime.shell_integration.git_context;
export import telar.runtime.model.launch_record;
export import telar.base.memory.allocators;
export import telar.base.memory.containers;
export import telar.platform.process;

export import telar.base.diagnostics;

export import telar.config.runtime;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.worktrees;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.client;
import telar.platform.events;
import telar.platform.net;

// Interface: model/pending_clipboard.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class PendingClipboard {
    public:
      static constexpr std::size_t capacity = 1024 * 1024;

      explicit PendingClipboard(Memory& memory);

      void replace(std::uint64_t pane, std::span<const Byte> bytes);

      bool pending() const noexcept;

      PaneClipboard message() const noexcept;

      void delivered() noexcept;

    private:
      Vector<Byte, Memory> bytes_;
      std::uint64_t pane_ = 0;
      bool pending_ = false;
    };

    extern template class PendingClipboard<SystemAllocator>;
    extern template class PendingClipboard<ConcurrentMemory>;
    extern template class PendingClipboard<BudgetAllocator<SystemAllocator>>;

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

      [[nodiscard]] Item* find(std::uint64_t id) noexcept;

      Item* add(std::uint64_t id) noexcept;

      void erase(std::size_t index) noexcept;

      [[nodiscard]] bool settled(std::uint64_t at_revision, std::uint64_t at_generation, std::uint64_t at_trimmed) const noexcept;

      void settle(std::uint64_t at_revision, std::uint64_t at_generation, std::uint64_t at_trimmed) noexcept;

      std::array<Item, ::telar::render::max_pane_documents> items{};
      std::size_t count = 0;
      // The terminal's inline documents and scrollback numbering the client is up to date with.
      std::uint64_t revision = std::numeric_limits<std::uint64_t>::max();
      std::uint64_t generation = 0;
      std::uint64_t trimmed = 0;
    };

    template <Allocator Memory>
    struct Attachment {
      explicit Attachment(Memory& memory, GraphicsCreditBudget& budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media);

      std::uint64_t pane_id;
      std::size_t slot = 0;
      FrameSync<Memory> frames;
      GraphicsSynchronizer<Memory> graphics;
      std::optional<std::uint32_t> viewport;
      std::optional<ConfigurePaneDesktop> desktop;
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
    };

    // client_layouts.cpp instantiates the constructor for SystemAllocator and ConcurrentMemory. It is
    // not declared `extern template` here: with that declaration, Clang 23 crashes in importers that
    // emit ~GraphicsSynchronizer<SystemAllocator> (GetVTTParameter, from runtime-tests' units).

    // The clients a runtime serves at once; a client's slot is its bit in what a pane is observed by.
    inline constexpr std::size_t client_capacity = 32;

    template <Allocator Memory>
    class Pane;

    template <Allocator Memory>
    class ClientSession {
    public:
      static constexpr std::size_t attachment_capacity = 64;

      struct ForegroundStamp {
        std::uint64_t pane = 0;
        std::uint64_t revision = 0;
      };

      explicit ClientSession(Memory& memory, std::uint64_t identity, FileDescriptor descriptor);

      std::size_t availableAttachmentSlot() const;

      // The bit its slot sets in a pane's observers; none before the client is stored.
      std::uint32_t observerBit() const noexcept;

      Attachment<Memory>* attachment(std::uint64_t pane_id) const noexcept;

      // Whether the runtime verified this client runs inside `pane`, the generation it has now.
      bool verifiedFor(const Pane<Memory>& pane) const noexcept;

      std::uint64_t id;
      std::uint64_t generation;
      std::uint64_t event_identity = 0;
      std::uint64_t identity = 0;
      GraphicsCreditBudget graphics_credit;
      ClientRole role = ClientRole::undecided;
      std::uint64_t last_input_pane = 0;
      std::uint64_t last_input_sequence = 0;
      std::optional<PendingClientCommand> pending_command;
      std::optional<PendingPaneFocus> pending_focus;
      Connection<Memory> connection;
      Vector<Owned<Attachment<Memory>, Memory>, Memory> attachments;
      PendingClipboard<Memory> clipboard;
      std::size_t next_attachment = 0;
      std::optional<std::uint64_t> completing_exit;
      bool layout_sent = false;
      bool proxy_status_sent = false;
      bool agent_snapshot_requested = false;
      bool subscribed = false;
      bool shared_graphics = false;
      std::uint64_t editor_source = 0;
      std::uint64_t editor_generation = 0;
      std::optional<ProcessIdentity> peer_identity;
      std::uint64_t agent_revision = 0;
      std::uint64_t metrics_revision = 0;
      std::uint64_t verified_pane = 0;
      std::uint64_t verified_generation = 0;
      ProcessLineage verified_lineage;
      std::optional<DescentCheck> pending_descent;
      bool descent_running = false;
      DeferredReport<Memory> deferred_report;
      unsigned limit_reports = 0;
      std::chrono::steady_clock::time_point limit_report_window{};
      std::optional<std::uint64_t> workspace;
      std::chrono::nanoseconds frame_interval{1'000'000'000 / 60};
      std::uint64_t workspace_revision = 0;
      std::uint64_t agent_workspace_revision = 0;
      std::uint64_t pane_revision = 0;
      std::uint64_t pane_workspace_revision = 0;
      std::optional<ResyncRequired> workspace_resync;
      std::array<ForegroundStamp, 256> foregrounds;
      std::optional<TextSearch> search;
      ConfigureTerminalColors colors{};
      // The client draws telar's editor in place of the shell's prompt: shells it starts print none.
      bool bare_prompt = false;
      HeldTabs held_tabs;
    };

    extern template class ClientSession<SystemAllocator>;
    extern template class ClientSession<ConcurrentMemory>;
    extern template Attachment<Memory>* ClientSession<Memory>::attachment(std::uint64_t pane_id) const noexcept;
    extern template std::uint32_t ClientSession<Memory>::observerBit() const noexcept;
    extern template Attachment<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>* ClientSession<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::attachment(std::uint64_t pane_id) const noexcept;
    extern template std::uint32_t ClientSession<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::observerBit() const noexcept;

  }
}

// Interface: model/pane.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Pane {
      // Kept whole: the default writer of write, which stays here, on every PTY write.
      struct TBC_HOT_PATH ResponseWriter {
        inline ssize_t operator()(int descriptor, std::span<const iovec> vectors) const {
          return ::writev(descriptor, vectors.data(), static_cast<int>(vectors.size()));
        }
      };

    public:
      enum class ReadMode {
        once,
        burst,
      };

      explicit Pane(Memory& memory, std::uint64_t identity, TabLocation location, Command<Memory>& command, PaneLaunch settings);

      bool read(ReadMode mode = ReadMode::once);

      // Reads where the integrated shell is and how the line discipline is set, and counts a
      // change. Two ioctls; the runtime calls it after output and, while a program runs, on its
      // tick, since a program can change the terminal without printing.
      void observeShell() noexcept;

      // The response writer borrows vectors only for this call. Only a positive
      // syscall result consumes the admitted prefix; EINTR/EAGAIN retain it.
      // Generic over the caller's writer: control_desktop_test passes its own.
      template <typename WriteResponses = ResponseWriter>
      TBC_HOT_PATH inline void write(WriteResponses write_responses = {}) {
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
            std::array<iovec, PtyResponseQueue::message_capacity> vectors;

            for (std::size_t index = 0; index < batch.count; ++index) {
              const auto message = batch.message(index);

              vectors[index] = {const_cast<Byte*>(message.data()), message.size()};
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

      void requestClose() noexcept;

      void enqueueInput(std::span<const Byte> bytes);

      // The text of the command a client runs at the prompt, recorded before the bytes that type it,
      // so the command's history keeps it instead of reading it back from the screen.
      void submitCommand(std::span<const Byte> text);

      // The terminal feeds the pane's media as it resumes.
      void resumeControl();

      void resize(TerminalSize size);

      std::optional<bool> shellForeground() const noexcept;

      std::optional<std::int32_t> exitCode() const noexcept;

      static constexpr std::size_t input_limit = 128 * 1024;
      static constexpr std::size_t read_buffer_size = 16 * 1024;
#if TELAR_DIAGNOSTICS
      diagnostics::PaneCounters* counters = nullptr;
      std::uint64_t input_dropped_bytes = 0;
#endif
      std::uint64_t id;
      std::uint64_t event_identity = 0;
      std::optional<ConfigurePaneDesktop> desktop_theme;
      std::uint64_t generation = 1;
      std::array<Byte, 16> history_session;
      TabLocation location;
      LaunchRecord<Memory> launch;
      std::optional<AgentResume> restored_agent;
      std::shared_ptr<PtyResponseQueue> pty_responses;
      std::shared_ptr<PaneObserver<Memory>> observer;
      std::shared_ptr<PaneMedia<Memory>> media;
      // Reports its graphics queries to media.
      tbc::view<Terminal<Memory>, tbc::lt::self> terminal;
      ByteQueue<Memory> input;
      // Reads rows of `terminal`'s scrollback for clients that ask for them.
      ScrollbackRows<Memory> scrollback_rows;
      String<Memory> cwd;
      std::optional<PtyProcess> process;
      std::uint32_t observers = 0;
      std::uint64_t cwd_revision = 0;
      std::optional<std::uint64_t> worktree_checked_cwd;
      std::uint64_t input_revision = 0;
      FixedText<48> foreground;
      std::uint64_t foreground_revision = 1;
      // The process group holding the terminal and since when, as the pane list reports them.
      pid_t foreground_group = 0;
      std::chrono::steady_clock::time_point foreground_since = std::chrono::steady_clock::now();
      bool foreground_shell = true;
      // The TCP ports that process group listens on, and when they were last read.
      ListeningPorts listening_ports;
      std::chrono::steady_clock::time_point ports_checked{};
      bool output_closed = false;
      bool exit_observed = false;
      bool shell_markers = false;
      bool needs_foreground_observation = false;
      // The integrated shell's own reading of its signed marks, on the runtime's thread so its
      // state reaches clients with the output that changed it.
      std::optional<CommandZones> shell_zones;
      // The commands it ran, anchored in `terminal`, which outlives them.
      std::optional<CommandBlocks<Memory>> blocks;
      // When input last reached a remote shell's line editor, until its echo arrives, and the
      // link's round trip so far, smoothed.
      std::optional<std::chrono::steady_clock::time_point> echo_sent;
      double link_average_ms = 0;
      PaneShell shell_state{};
      // The shell the pane started, which an `ssh` session it nests stands in for.
      IntegratedShell local_shell = IntegratedShell::none;
      // Zero until the pane has an integrated shell: other panes never send their state.
      std::uint64_t shell_revision = 0;
      // The repository the integrated shell works in, read after each command; zero until read.
      ShellGitSummary git{};
      std::uint64_t git_revision = 0;
      std::uint32_t git_commands = std::numeric_limits<std::uint32_t>::max();
      FixedText<PATH_MAX> git_directory;
      bool write_interest = false;
      bool read_paused = false;
      std::optional<int> exit_status;
      std::chrono::steady_clock::time_point sync_started{};
      std::optional<std::chrono::steady_clock::time_point> last_input;
      bool close_requested = false;
      ProcessCache process_cache;
      std::uint32_t process_rechecks = 0;
      bool process_recheck_requested = false;
      bool process_recheck_running = false;
      std::optional<RejectedReporter> rejected_reporter;

    private:
      // Counts the commands the integrated shell finished, for its clients, and keeps the marks
      // the bytes held, for the command blocks. A mark past the last kept one is not placed.
      struct ShellCompletions {
        struct Mark {
          char action = 0;
          std::size_t end = 0;
          std::optional<int> status;
        };

        PaneShell& state;
        std::array<Mark, 16> kept{};
        std::size_t count = 0;

        void complete(CommandCompletion completion) noexcept;

        void mark(CommandMark mark) noexcept;

        std::span<const Mark> marks() const noexcept;
      };

      // Folds one round trip into the link's; clients hear of it when it moves by a tenth.
      void timeLink(std::chrono::steady_clock::duration elapsed) noexcept;

      void expireProgress(std::optional<bool> shell_foreground) noexcept;

#if TELAR_DIAGNOSTICS
      void recordRead(std::size_t size, bool folded) noexcept;
#endif
    };

    extern template class Pane<SystemAllocator>;
    extern template class Pane<ConcurrentMemory>;
    extern template Pane<Memory>::Pane(Memory& memory, std::uint64_t identity, TabLocation location, Command<Memory>& command, PaneLaunch settings);
    extern template void Pane<Memory>::observeShell() noexcept;
    extern template bool Pane<Memory>::hasInput() const noexcept;
    extern template void Pane<Memory>::requestClose() noexcept;
    extern template void Pane<Memory>::resumeControl();
    extern template std::optional<std::int32_t> Pane<Memory>::exitCode() const noexcept;
    extern template Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::Pane(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory, std::uint64_t identity, TabLocation location, Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& command, PaneLaunch settings);
    extern template void Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::observeShell() noexcept;
    extern template bool Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::hasInput() const noexcept;
    extern template void Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::requestClose() noexcept;
    extern template void Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::resumeControl();
    extern template std::optional<std::int32_t> Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::exitCode() const noexcept;

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

    template <Allocator Memory>
    struct Tab {
      explicit Tab(Memory& memory, std::uint64_t identity, std::string_view name);

      std::uint64_t id;
      String<Memory> label;
      Vector<std::uint64_t, Memory> panes;
    };

    extern template struct Tab<SystemAllocator>;
    extern template struct Tab<ConcurrentMemory>;
    extern template struct Tab<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

    template <Allocator Memory>
    class Workspace {
    public:
      explicit Workspace(Memory& memory, std::uint64_t identity, std::string_view directory, std::string_view label);

      Tab<Memory>* tab(std::uint64_t tab_id) noexcept;

      const Tab<Memory>* tab(std::uint64_t tab_id) const noexcept;

      std::string_view displayName() const noexcept;

      std::uint64_t id;
      String<Memory> path;
      String<Memory> name;
      Vector<Tab<Memory>, Memory> tabs;
      std::optional<std::uint64_t> geometry_client;
      FixedText<200> git_branch;
      std::chrono::steady_clock::time_point git_checked_at{};
      bool git_dirty = false;
      bool git_timed_out = false;
    };

    extern template class Workspace<SystemAllocator>;
    extern template class Workspace<ConcurrentMemory>;
    extern template Workspace<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::Workspace(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory, std::uint64_t identity, std::string_view directory, std::string_view label);

  }
}

// Interface: model/worktrees.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct Worktree {
      explicit Worktree(Memory& memory, std::uint64_t identity, const RegisterWorktree& request);

      WorktreeListEntry entry() const noexcept;

      std::uint64_t id;
      std::uint64_t source;
      std::optional<std::uint64_t> workspace;
      std::optional<std::uint64_t> created_by;
      std::optional<CoordinatorReference> coordinator;
      WorktreeOrigin origin;
      WorktreeState state = WorktreeState::active;
      String<Memory> path;
      FixedText<200> branch;
      FixedText<200> base;
      FixedText<96> title;
      FixedText<512> brief;
      FixedText<32> dispatched_from;
      FixedText<48> command_label;
      std::uint32_t diff_added = 0;
      std::uint32_t diff_removed = 0;
      std::uint32_t diff_files = 0;
      std::uint32_t commits_ahead = 0;
      unsigned probe_failures = 0;
      bool had_changes = false;
      std::chrono::steady_clock::time_point checked_at{};
      CommandState command_state = CommandState::none;
      std::int32_t command_exit = 0;
      std::optional<std::uint64_t> command_pane;
    };

    extern template struct Worktree<SystemAllocator>;
    extern template struct Worktree<ConcurrentMemory>;

    template <Allocator Memory>
    class Worktrees {
    public:
      explicit Worktrees(Memory& memory);

      WorktreeRegistered registerEntry(const RegisterWorktree& request, std::uint64_t restored_identity = 0);

      Worktree<Memory>* find(std::uint64_t identity) noexcept;

      std::span<Worktree<Memory>* const> items() const noexcept;

      void remove(std::uint64_t identity) noexcept;

      Worktree<Memory>* containing(std::string_view path) noexcept;

      std::uint64_t sourceFor(std::uint64_t workspace) const noexcept;

      static constexpr std::size_t capacity = 64;

    private:
      static constexpr std::size_t reserved_for_telar = 16;
      Memory& memory_;
      SlotStore<Worktree<Memory>, capacity, Memory> entries_;
    };

    extern template class Worktrees<SystemAllocator>;
    extern template class Worktrees<ConcurrentMemory>;
    extern template Worktrees<Memory>::Worktrees(Memory& memory);
    extern template Worktrees<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::Worktrees(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory);

  }
}

// Interface: model/runtime_model.cppm
export {
  namespace telar::runtime {

    // The runtime's tables. Functions take the ones they read or change, so the borrows they keep of one
    // table are not disturbed by another, as Rust's disjoint field borrows are.
    template <Allocator Memory>
    using PaneStore = SlotStore<Pane<Memory>, 256, Memory>;
    template <Allocator Memory>
    using ClientStore = SlotStore<ClientSession<Memory>, client_capacity, Memory>;
    template <Allocator Memory>
    using WorkspaceStore = SlotStore<Workspace<Memory>, 64, Memory>;

    // Calls `send` for each open client `admits` accepts. A client whose send throws is closed: its
    // connection may hold part of a frame, and every broadcast treats that failure alike.
    // Generic over the caller's predicate and sender, and run for every message sent to all clients.
    template <Allocator Memory, typename Admits, typename Send>
    TBC_HOT_PATH inline void deliver(ClientStore<Memory>& clients, Admits&& admits, Send&& send) noexcept {
      for (auto* client : clients.items()) {
        if (client == nullptr || client->connection.closing || !admits(*client)) {
          continue;
        }

        try {
          send(*client);
        } catch (...) {
          client->connection.closing = true;
        }
      }
    }

    // Sends `message` to each open client `admits` accepts, as deliver does; how many queued it.
    // Generic over the caller's predicate and message, as deliver.
    template <Allocator Memory, typename Admits, typename Message>
    TBC_HOT_PATH inline std::size_t broadcast(ClientStore<Memory>& clients, Admits&& admits, const Message& message) noexcept {
      std::size_t delivered = 0;

      deliver(clients, admits, [&](ClientSession<Memory>& client) {
        delivered += client.connection.trySend(message);
      });

      return delivered;
    }

    // Whether a live client holds a tab.
    template <Allocator Memory>
    bool tabHeld(const ClientStore<Memory>& clients, TabLocation location) noexcept;

    // The stored client with an identity, which a request names.
    template <Allocator Memory>
    ClientSession<Memory>& requireClient(ClientStore<Memory>& clients, std::uint64_t identity);

    // The pane `identity` names while it has `generation`; none for another generation. No pane has
    // generation 0, so 0 finds none.
    template <Allocator Memory>
    tbc::view<Pane<Memory>*, tbc::lt::a> findPane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;

    template <Allocator Memory>
    tbc::view<const Pane<Memory>*, tbc::lt::a> findPane(tbc::view<const PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;

    // The same pane while its process runs and nobody asked it to close.
    template <Allocator Memory>
    tbc::view<Pane<Memory>*, tbc::lt::a> livePane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;

    template <Allocator Memory>
    tbc::view<const Pane<Memory>*, tbc::lt::a> livePane(tbc::view<const PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;

    // The pane an agent's report names, which must still run the generation it names and be the one
    // the runtime verified the reporting client inside.
    template <Allocator Memory>
    tbc::view<Pane<Memory>&, tbc::lt::a> requireReporterPane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, const ClientSession<Memory>& client, std::uint64_t identity, std::uint64_t generation);

    extern template bool tabHeld<SystemAllocator>(const ClientStore<SystemAllocator>& clients, TabLocation location) noexcept;
    extern template ClientSession<SystemAllocator>& requireClient<SystemAllocator>(ClientStore<SystemAllocator>& clients, std::uint64_t identity);
    extern template tbc::view<Pane<SystemAllocator>*, tbc::lt::a> findPane<SystemAllocator>(tbc::view<PaneStore<SystemAllocator>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<SystemAllocator>*, tbc::lt::a> findPane<SystemAllocator>(tbc::view<const PaneStore<SystemAllocator>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<Pane<SystemAllocator>*, tbc::lt::a> livePane<SystemAllocator>(tbc::view<PaneStore<SystemAllocator>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<SystemAllocator>*, tbc::lt::a> livePane<SystemAllocator>(tbc::view<const PaneStore<SystemAllocator>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<Pane<SystemAllocator>&, tbc::lt::a> requireReporterPane<SystemAllocator>(tbc::view<PaneStore<SystemAllocator>&, tbc::lt::a> panes, const ClientSession<SystemAllocator>& client, std::uint64_t identity, std::uint64_t generation);
    extern template bool tabHeld<ConcurrentMemory>(const ClientStore<ConcurrentMemory>& clients, TabLocation location) noexcept;
    extern template ClientSession<ConcurrentMemory>& requireClient<ConcurrentMemory>(ClientStore<ConcurrentMemory>& clients, std::uint64_t identity);
    extern template tbc::view<Pane<ConcurrentMemory>*, tbc::lt::a> findPane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<ConcurrentMemory>*, tbc::lt::a> findPane<ConcurrentMemory>(tbc::view<const PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<Pane<ConcurrentMemory>*, tbc::lt::a> livePane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<ConcurrentMemory>*, tbc::lt::a> livePane<ConcurrentMemory>(tbc::view<const PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<Pane<ConcurrentMemory>&, tbc::lt::a> requireReporterPane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, const ClientSession<ConcurrentMemory>& client, std::uint64_t identity, std::uint64_t generation);
    extern template tbc::view<Pane<Memory>*, tbc::lt::a> findPane<Memory>(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<Memory>*, tbc::lt::a> findPane<Memory>(tbc::view<const PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>*, tbc::lt::a> findPane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(tbc::view<PaneStore<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
    extern template tbc::view<const Pane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>*, tbc::lt::a> findPane<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(tbc::view<const PaneStore<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;

    // The runtime's data apart from its clients, whose table is separate so that a call can borrow one
    // client and the model at once, as Rust borrows two fields of a struct.
    template <Allocator Memory>
    struct RuntimeModel {
      explicit RuntimeModel(Memory& memory, GraphicsLimits graphics = {});

      GraphicsLimits graphics_limits;
      RuntimeLimits limits;
      [[no_unique_address]] diagnostics::RuntimeCounters metrics;
      MediaBudget media_budget;
      AgentManifests manifests = builtin_manifests;
      std::string_view cli_executable;
      bool capture_output = false;
      PaneStore<Memory> panes;
      WorkspaceStore<Memory> workspaces;
      Worktrees<Memory> worktrees;
      ExitedPanes exited_panes;
      std::shared_ptr<PaneObserver<Memory>> retired_observers;
      std::size_t retired_observer_count = 0;
      std::shared_ptr<PaneMedia<Memory>> retired_media;
      std::size_t retired_media_count = 0;
      std::uint64_t next_tab_id = 1;
      std::uint64_t workspace_revision = 1;
      // Advances when a pane joins or leaves the pane list or its foreground process changes.
      std::uint64_t pane_revision = 1;
      std::uint64_t next_pane_generation = 1;
      std::uint64_t input_sequence = 0;
      bool stopping = false;
    };

    extern template struct RuntimeModel<SystemAllocator>;
    extern template struct RuntimeModel<Memory>;
    extern template struct RuntimeModel<ConcurrentMemory>;
    extern template struct RuntimeModel<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  }
}

// Interface: model/client_layouts.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class ClientLayouts {
    public:
      explicit ClientLayouts(Memory& memory);

      void retain(const RuntimeModel<Memory>& model, std::uint64_t identity, const UpdateClientLayout& update);

      // Kept here (P9.12): out of line, the lifetime checker's summary takes the whole receiver as
      // mutated, and Runtime::writeClient's StateProjection, which borrows these layouts, then
      // overlaps the client it publishes to (tbc-invalidated-borrow).
      TBC_HOT_PATH inline void publish(const RuntimeModel<Memory>& model, ClientSession<Memory>& client) {
        auto* record = find(client.identity);
        if (record == nullptr) {
          client.connection.send(ClientLayoutSnapshot{});
          return;
        }

        std::array<ClientTabLayout, maximum_tabs> tabs;
        std::size_t count = 0;
        std::optional<TabLocation> active;

        for (std::size_t index = 0; index < record->tab_count; ++index) {
          const auto tab = record->tabAt(index);
          if (!current(model, tab)) {
            continue;
          }

          tabs[count++] = tab;
          if (sameLocation(tab.location, record->active_tab)) {
            active = tab.location;
          }
        }

        record->last_used = ++clock_;
        client.connection.send(ClientLayoutSnapshot{
            .restored = true,
            .sidebar_visible = record->sidebar_visible,
            .sidebar_width = record->sidebar_width,
            .workspace_list_collapsed = record->workspace_list_collapsed,
            .active_tab = active,
            .tabs = std::span{tabs}.first(count),
        });
      }

      std::optional<std::uint64_t> focusedPane(std::uint64_t identity) const noexcept;

      std::uint64_t revision() const noexcept;

      // Generic over the caller's consumer, which each record is handed to.
      template <typename Consumer>
      TBC_HOT_PATH inline void exportRecords(const RuntimeModel<Memory>& model, Consumer&& consume) const {
        std::array<ClientTabLayout, maximum_tabs> tabs;

        for (const auto& record : records_) {
          std::size_t count = 0;
          bool active_valid = false;

          for (std::size_t index = 0; index < record.tab_count; ++index) {
            const auto tab = record.tabAt(index);
            if (!current(model, tab)) {
              continue;
            }

            tabs[count++] = tab;
            active_valid |= sameLocation(tab.location, record.active_tab);
          }

          if (!active_valid) {
            continue;
          }

          consume(record.identity, record.last_used, UpdateClientLayout{record.sidebar_visible, record.sidebar_width, record.workspace_list_collapsed, record.active_tab, std::span{tabs}.first(count)});
        }
      }

    private:
      static constexpr std::size_t maximum_identities = 16;
      static constexpr std::size_t maximum_tabs = 256;
      static constexpr std::size_t maximum_nodes = 511;

      struct StoredTab {
        TabLocation location;
        std::uint64_t focused_pane;
        bool fullscreen;
        bool workspace_active;
        std::uint16_t node_start;
        std::uint16_t node_count;
      };

      struct Record {
        std::uint64_t identity = 0;
        std::uint64_t last_used = 0;
        bool sidebar_visible = true;
        std::uint16_t sidebar_width = 0;
        bool workspace_list_collapsed = false;
        TabLocation active_tab{};
        std::array<StoredTab, maximum_tabs> tabs{};
        std::array<ClientLayoutNode, maximum_nodes> nodes{};
        std::size_t tab_count = 0;
        std::size_t node_count = 0;

        ClientTabLayout tabAt(std::size_t index) const noexcept;

        void append(const ClientTabLayout& tab);
      };

      static bool sameWorkspace(WorkspaceLocation left, WorkspaceLocation right) noexcept;

      static bool sameLocation(TabLocation left, TabLocation right) noexcept;

      static bool current(const RuntimeModel<Memory>& model, const ClientTabLayout& layout) noexcept;

      Record* find(std::uint64_t identity) noexcept;

      Vector<Record, Memory> records_;
      std::uint64_t clock_ = 0;
    };

    extern template class ClientLayouts<SystemAllocator>;
    extern template class ClientLayouts<ConcurrentMemory>;

  }
}
