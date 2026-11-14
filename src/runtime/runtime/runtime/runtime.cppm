module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.runtime.runtime;

import std;
import telar.sys.posix;
import telar.tbc;

export import telar.runtime.agents.screen_inference;
export import telar.runtime.agents.snapshot;
export import telar.runtime.model.client_layouts;
export import telar.runtime.platform.process_probe;
export import telar.runtime.runtime.media_service;
export import telar.runtime.runtime.execution_service;

export import telar.runtime.agents.description_generator;
export import telar.runtime.persistence.session_store;
export import telar.config.runtime;

export import telar.runtime.plugins.service;
export import telar.runtime.runtime.client_control;

export import telar.runtime.platform.local_listener;
export import telar.runtime.worktrees.git_probe;

export import telar.runtime.runtime.runtime_telemetry;
export import telar.runtime.vocabulary.exchange;

export import telar.runtime.platform.background_executor;

import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.execution;
import telar.wire.graphics;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.base.editors;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.client;
import telar.runtime.exchange_capture.pipeline;
import telar.runtime.platform.launch_program;
import telar.runtime.platform.stream_read_buffer;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.suggestions.engine;
import telar.runtime.shell_integration.words;

// The workers runRuntime builds for the runtime (telar.runtime.cli.server); the services below are
// instantiated for them.
namespace telar::runtime {

  using RuntimeBackground = BackgroundPool<ConcurrentMemory, BackgroundService<ConcurrentMemory>, PathService<ConcurrentMemory>, EditorService<ConcurrentMemory>, SuggestionService<ConcurrentMemory>>;

}

// Interface: agents/snapshot.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class AgentSnapshotBuilder {
    public:
      void publish(ClientSession<Memory>& client, const RuntimeModel<Memory>& model, const AgentRegistry<Memory>& registry);

    private:
      std::array<FixedText<48>, AgentRegistry<Memory>::capacity> directories_;
      std::array<FixedText<96>, AgentRegistry<Memory>::capacity> placeholders_;
    };

    extern template class AgentSnapshotBuilder<ConcurrentMemory>;

  }
}

// Interface: runtime/agent_service.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
    class AgentService {
    public:
      using Panes = PaneService<Memory, Poller, History>;

      explicit AgentService(Memory& memory);

      void enableDescriptions(bool enabled) noexcept;

      void observeInput(const Pane<Memory>& pane, std::span<const Byte> bytes);

      std::optional<DescriptionRequest> nextDescription();

      std::optional<HistorySessionTitle> completeDescription(const DescriptionResult& result);

      void report(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const ReportAgent& request);

      void reportSession(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const ReportAgentSession& request);

      void reportTitle(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const ReportAgentTitle& request);

      std::optional<SessionFileRequest> nextSessionFile(std::chrono::steady_clock::time_point now) const;

      void completeSessionFile(const SessionFileResult& result, std::chrono::steady_clock::time_point now);

      bool reportProgress(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const ReportAgentProgress& request);

      tbc::view<Pane<Memory>&, tbc::lt::a> validateCommand(tbc::view<RuntimeModel<Memory>&, tbc::lt::a> model, ClientSession<Memory>& client, const ReportAgentCommand& request);

      // Sends text to a pane, which its caller says no attached window focuses.
      void sendText(RuntimeModel<Memory>& model, Panes& panes, ClientSession<Memory>& client, const SendPaneText& request, bool focused);

      void acknowledge(const AcknowledgeAgent& request) noexcept;

      // Interrupts a pane's agent, which its caller says no attached window focuses.
      void interrupt(RuntimeModel<Memory>& model, Panes& panes, ClientSession<Memory>& client, const InterruptAgent& request, bool focused);

      // Whether an attached window focuses a pane.
      static bool focused(const ClientStore<Memory>& clients, const ClientLayouts<Memory>& layouts, std::uint64_t pane) noexcept;

      bool blocked(const Pane<Memory>& pane) const noexcept;

      void query(const RuntimeModel<Memory>& model, ClientSession<Memory>& client);

      std::uint64_t revision() const noexcept;

      const Agent* find(std::uint64_t pane, std::uint64_t generation) const noexcept;

      void observeProcess(Pane<Memory>& pane, std::optional<ProcessIdentity> identity, AgentProvider provider);

      void observeProcess(Pane<Memory>& pane, const ProcessProbeResult& observation);

      void observeScreen(Pane<Memory>& pane, const AgentSignal& signal, ObservationTime time);

      void refresh(RuntimeModel<Memory>& model, Panes& panes, const ClientStore<Memory>& clients, const ClientLayouts<Memory>& layouts, std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now());

      Agent& ensure(Pane<Memory>& pane);

      // Sends the agent sounds reported since the last delivery to subscribed clients.
      void deliverSounds(ClientStore<Memory>& clients) noexcept;

    private:
      // Stamps an agent whose projection changed, named by its pane: it may queue for a description and
      // takes the next sequence. The table lends one entry at a time, so the caller holds none across it.
      void projected(std::uint64_t pane, std::uint64_t generation) noexcept;

      // Whether a change of status calls for a sound.
      static bool alerts(const Agent& agent, AgentStatus previous) noexcept;

      // Ends an interrupt once its pane settles; whether the agent's projection changed.
      static bool settleInterrupt(Panes& panes, bool focused, Pane<Memory>& pane, Agent& agent, std::chrono::steady_clock::time_point now);

      static Pane<Memory>& require(PaneStore<Memory>& panes, std::uint64_t identity, std::uint64_t generation);

      tbc::view<Pane<Memory>&, tbc::lt::a> authorize(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, const ClientSession<Memory>& client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider);

      // Queues an agent's sound, delivered once no client is borrowed.
      // Agent sounds queued while a client is borrowed, delivered to the subscribed clients afterwards.
      class SoundQueue {
      public:
        void push(const Agent& agent) noexcept;

        std::span<const AgentSoundNotification> queued() const noexcept;

        void clear() noexcept;

      private:
        std::array<AgentSoundNotification, 32> entries_{};
        std::size_t count_ = 0;
      };

      AgentRegistry<Memory> agents_;
      DescriptionQueue<Memory> descriptions_;
      AgentSnapshotBuilder<Memory> snapshots_;
      PromptBudget prompt_budget_;
      std::uint64_t sequence_ = 0;
      std::uint64_t session_watch_revision_ = 0;
      bool has_session_files_ = false;
      SoundQueue sounds_;
    };

    extern template class AgentService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
    extern template class AgentService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  }
}

// Interface: runtime/launch_directory.cppm
export {
  namespace telar::runtime {

    using LaunchDirectoryScope = std::variant<std::monostate, WorkspaceLocation, TabLocation>;

    // Storage for a launch's working directory taken from the model, so that the launch borrows none of
    // the model a launch then changes.
    using LaunchDirectory = FixedText<4096>;

    // Points a launch at a copy of a directory.
    void ownDirectory(tbc::view<Launch&, tbc::lt::a> launch, tbc::view<LaunchDirectory&, tbc::lt::a> storage, std::string_view directory);

    // The launch with the directory of the pane it names as its source, copied into `directory`.
    template <Allocator Memory>
    tbc::view<Launch, tbc::lt::a> resolveLaunchDirectory(const RuntimeModel<Memory>& model, const ClientSession<Memory>& client, tbc::view<Launch, tbc::lt::a> launch, tbc::view<LaunchDirectory&, tbc::lt::a> directory, LaunchDirectoryScope scope = {});

    extern template tbc::view<Launch, tbc::lt::a> resolveLaunchDirectory<ConcurrentMemory>(const RuntimeModel<ConcurrentMemory>& model, const ClientSession<ConcurrentMemory>& client, tbc::view<Launch, tbc::lt::a> launch, tbc::view<LaunchDirectory&, tbc::lt::a> directory, LaunchDirectoryScope scope);

  }
}

// Interface: runtime/options.cppm
export {
  namespace telar::runtime {

    struct RuntimeOptions {
      std::string_view socket;
      std::string_view cli_executable;
      checkpoint::Options session;
      bool fresh = false;
      bool capture_output = false;
      const AgentManifests* manifests = &builtin_manifests;
      DescriptionOptions descriptions;
      GraphicsLimits graphics;
      control::Policy control_policy{};
      std::string_view shell_integration;
      bool ssh_integration = false;
      // Where the user's completion specs live: the configuration's own directory.
      std::string_view configuration_directory;
    };

  }
}

// Interface: runtime/plugin_delivery.cppm
export {
  namespace telar::runtime {

    // Shows plugins' notifications on the clients and reports their dropped work as limits.
    template <Allocator Memory>
    class PluginDelivery {
    public:
      explicit PluginDelivery(LimitService<Memory>& limits) noexcept;

      // Generic over the caller's plugin event source; the metrics it reads are reported in the
      // implementation unit.
      template <plugins::EventSource Source>
      TBC_HOT_PATH inline void collect(ClientStore<Memory>& clients, Source& source) {
        source.collect([&](const plugins::EffectBatch& batch) {
          for (const auto& notification : std::span{batch.notifications}.first(batch.count)) {
            publish(clients, notification);
          }
        });

        reportMetrics(source.metrics());
      }

    private:
      // Reports the work the plugins dropped since the last collection as limits.
      void reportMetrics(const plugins::TapMetrics& now);

      static void publish(ClientStore<Memory>& clients, const NotificationBody& body);

      void reportGrowth(std::uint64_t current, std::uint64_t previous, const LimitReach& reach);

      static constexpr std::size_t validation_bytes = 512;
      LimitService<Memory>& limits_;
      plugins::TapMetrics previous_;
    };

    template <Allocator Memory>
    PluginDelivery(LimitService<Memory>& limits) -> PluginDelivery<Memory>;

    extern template class PluginDelivery<ConcurrentMemory>;

  }
}

// Interface: runtime/workspace_service.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
    class WorkspaceService {
    public:
      using Panes = PaneService<Memory, Poller, History>;

      explicit WorkspaceService(Memory& memory);

      static Workspace<Memory>& require(WorkspaceStore<Memory>& workspaces, WorkspaceLocation location);

      static Tab<Memory>& requireTab(WorkspaceStore<Memory>& workspaces, TabLocation location);

      // The colors of a workspace's geometry owner, which its new panes take.
      static tbc::view<const ConfigureTerminalColors*, tbc::lt::a> ownerColors(const WorkspaceStore<Memory>& workspaces, tbc::view<const ClientStore<Memory>&, tbc::lt::a> clients, std::uint64_t workspace) noexcept;

      // Whether a workspace's geometry owner draws telar's editor, so its new panes' shells print no prompt.
      static bool ownerBarePrompt(const WorkspaceStore<Memory>& workspaces, const ClientStore<Memory>& clients, std::uint64_t workspace) noexcept;

      void open(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const OpenPane& request);

      void createWorkspace(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const CreateWorkspace& request);

      void createTab(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const CreateTab& request);

      // A tab launched without a client, in the colors of its workspace's geometry owner.
      std::uint64_t launchBackground(RuntimeModel<Memory>& model, Panes& panes, const ConfigureTerminalColors* owner_colors, bool bare_prompt, const LaunchTab& request);

      void launchTab(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const LaunchTab& request);

      void createPane(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const CreatePane& request);

      void renameWorkspace(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const RenameWorkspace& request);

      void renameTab(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const RenameTab& request);

      void moveTab(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const MoveTab& request);

      static void closePane(RuntimeModel<Memory>& model, const ClientSession<Memory>& client, const ClosePane& request);

      void collectExited(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients);

      void holdTab(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const HoldTab& request);

      void releaseHeldTabs(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id);

      void closeTab(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const CloseTab& request);

      void closeWorkspace(RuntimeModel<Memory>& model, ClientStore<Memory>& clients, std::uint64_t identity);

      static void tabSnapshot(RuntimeModel<Memory>& model, ClientStore<Memory>& clients, std::uint64_t client_id, const RequestTabSnapshot& request);

      static void workspaceSnapshot(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const RequestWorkspaceSnapshot& request);

      static void publishList(const RuntimeModel<Memory>& model, ClientSession<Memory>& client);

      // Marks the clients viewing the workspaces changed since the last delivery for a resync.
      void deliverNotices(ClientStore<Memory>& clients) noexcept;

    private:
      struct Notice {
        std::uint64_t workspace = 0;
        std::uint64_t origin = 0;
        std::optional<std::uint64_t> previous;
      };

      // Queues a workspace change for the clients that view it but did not make it.
      void notify(std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous = {}) noexcept;

      void releaseEmptyTab(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, TabLocation location);

      // Tells each client viewing the closed tab's workspace, after `seen` notes it; one whose queue
      // is full resynchronizes the workspace instead.
      template <typename Seen>
      static void broadcastTabClosed(ClientStore<Memory>& clients, const TabClosed& closed, Seen&& seen) noexcept;

      static TabClosed removeTab(RuntimeModel<Memory>& model, TabLocation location);

      void leaveEmptyViews(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t workspace) noexcept;

      void retainFinalText(ExitedPanes& exited, Pane<Memory>& pane) noexcept;

      std::uint64_t createRoot(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const Launch& launch, TerminalSize size, std::string_view name, bool replace_view = false);

      static std::uint64_t nextTabIdentity(const RuntimeModel<Memory>& model);

      // A pane launched into a tab whose workspace the client takes the geometry of.
      std::uint64_t createAt(RuntimeModel<Memory>& model, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, TabLocation location, Launch launch, TerminalSize size);

      static std::optional<std::uint64_t> firstPane(const PaneStore<Memory>& panes, const Workspace<Memory>& workspace) noexcept;

      static std::optional<std::uint64_t> firstPane(const PaneStore<Memory>& panes, const Tab<Memory>& tab) noexcept;

      static void createDirectories(std::string_view path);

      enum class GenerationField {
        included,
        omitted,
      };

      static void sendOpened(ClientSession<Memory>& client, std::uint64_t request, const Pane<Memory>& pane, bool created, GenerationField generation = GenerationField::included);

      static constexpr std::size_t maximum_tabs = 64;
      static constexpr std::size_t maximum_panes_per_tab = 64;
      Memory& memory_;
      std::array<Notice, 64> notices_{};
      std::size_t notice_count_ = 0;
      bool overflowed_ = false;
    };

    extern template class WorkspaceService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
    extern template class WorkspaceService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  }
}

// Interface: runtime/worktree_service.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
    class WorktreeService {
    public:
      using Workspaces = WorkspaceService<Memory, Poller, History>;
      using Panes = PaneService<Memory, Poller, History>;

      explicit WorktreeService(Memory& memory, LimitService<Memory>& limits);

      static void registerEntry(RuntimeModel<Memory>& model, ClientSession<Memory>& client, const RegisterWorktree& request);

      void launch(RuntimeModel<Memory>& model, Workspaces& workspaces, Panes& panes, ClientStore<Memory>& clients, std::uint64_t client_id, const LaunchWorktree& request);

      static void forget(RuntimeModel<Memory>& model, Workspaces& workspaces, ClientStore<Memory>& clients, std::uint64_t client_id, const ForgetWorktree& request);

      template <typename Background>
      void observe(const RuntimeModel<Memory>& model, Background& background);

      void observed(RuntimeModel<Memory>& model, const WorktreeProbeResult& result);

      static void refresh(RuntimeModel<Memory>& model) noexcept;

    private:
      static Worktree<Memory>& require(Worktrees<Memory>& worktrees, std::uint64_t identity);

      std::optional<std::uint64_t> observing_;
      Memory& memory_;
      LimitService<Memory>& limits_;
    };

    extern template class WorktreeService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
    extern template class WorktreeService<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  }
}

// Interface: runtime/background_executor.cppm
export {
  namespace telar::runtime {

    template <typename Executor, typename Message>
    concept SubmitsRequest = requires(Executor& executor, std::uint64_t client, const RequestContext& context) {
      { executor.submit(client, Message{}, context) } -> std::same_as<void>;
    };

    // Whether `Executor` takes every request of the list that runs off the runtime's thread.
    template <typename Executor, typename List>
    inline constexpr bool submits_worker_requests = false;

    template <typename Executor, typename... Requests>
    inline constexpr bool submits_worker_requests<Executor, ClientRequestList<Requests...>> = ((Requests::lane < RequestLane::worker || SubmitsRequest<Executor, typename Requests::Type>) && ...);

    template <typename Executor, typename Memory>
    concept BackgroundExecutor = Allocator<Memory> && HistoryEventSink<Executor> && requires(Executor& executor, std::uint64_t client, const RequestContext& context, void (*consume)(std::uint64_t, ClientTag, std::span<const Byte>)) {
      { executor.descriptors() } noexcept -> std::same_as<std::array<int, 5>>;
      { executor.collect(consume) } -> std::same_as<void>;
      { executor.cancel(client) } noexcept -> std::same_as<void>;
      { executor.suggestionsAvailable() } noexcept -> std::same_as<bool>;
      { executor.editorBusy() } noexcept -> std::same_as<bool>;
      { executor.takeHistoryFailures() } noexcept -> std::same_as<std::uint64_t>;
    } && submits_worker_requests<Executor, ClientRequests> && requires(Executor& executor, Connection<Memory>& reply, const WorktreeProbeRequest& request, void (*consume)(const WorktreeProbeResult&)) {
      { executor.tryPaths(std::uint64_t{}, FindPaths{}, reply) } -> std::same_as<bool>;
      { executor.observeWorktree(request) } -> std::same_as<bool>;
      { executor.collectWorktrees(consume) } -> std::same_as<void>;
    };

  }
}

// Interface: runtime/runtime.cppm
export {
  namespace telar::runtime {

    // The runtime owns the model, the client table and the services, and lends each service the tables
    // a call needs. A request names its client by identity, and a handler looks the client up again after
    // any call that can change the table, as Rust code holds an index across a mutation, not a reference.
    template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
      requires BackgroundExecutor<Background, Memory>
    class Runtime {
      using Agents = AgentService<Memory, Poller, Background>;
      using Panes = PaneService<Memory, Poller, Background>;
      using Workspaces = WorkspaceService<Memory, Poller, Background>;
      using Worktrees = WorktreeService<Memory, Poller, Background>;
      using Control = ClientControl<Memory>;
      using Descents = DescentService<Memory, ProcessInspector>;
      using Frames = typename Connection<Memory>::Frames;

    public:
      explicit Runtime(Memory& memory, Poller& poller, Background& background, const RuntimeOptions& options, ProxyClientConfiguration proxy = {});

      void run();

      // Generic over the caller's capture source, the proxy in production.
      template <CaptureEventSource Captures>
      TBC_HOT_PATH inline void run(Captures& captures) {
        plugins::IgnoreEvents plugins;

        run(captures, plugins);
      }

      // Generic over the caller's capture and plugin event sources, the proxy and the plugin service in
      // production; each ready event is routed in the implementation unit.
      template <CaptureEventSource Captures, plugins::EventSource Plugins>
      TBC_HOT_PATH inline void run(Captures& captures, Plugins& plugins) {
        TELAR_TRACE("runtime.run");
        TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::interactive});
        std::array<Event, Poller::event_capacity> ready{};
        PluginDelivery delivery{limits_};
        const int capture_descriptor = captures.descriptor();
        if (capture_descriptor >= 0) {
          poller_.watch(capture_descriptor, eventToken(EventSource::worker, 0));
        }

        const int plugin_descriptor = plugins.descriptor();
        if (plugin_descriptor >= 0) {
          poller_.watch(plugin_descriptor, eventToken(EventSource::worker, 0));
        }

        while (!model_.stopping) {
          if (captures.collect()) {
            limits_.report(LimitReach{.name = "proxy.capture.joiner_capacity", .noun = "pending exchanges", .value = CaptureJoiner<Memory>::capacity});
          }

          delivery.collect(clients_, plugins);
          const auto now = Clock::now();
          auto timeout = publish(now);

          TELAR_DIAGNOSTIC(model_.metrics.system = metrics_.diagnostics());
          TELAR_DIAGNOSTIC(timeout = std::min(timeout, telemetry_.tick(model_, clients_, memory_, captures, background_, Clock::now())));

          for (const auto& event : poller_.wait(timeout, ready)) {
            if (!route(event)) {
              break;
            }
          }
        }

        if (capture_descriptor >= 0) {
          poller_.remove(capture_descriptor);
        }

        if (plugin_descriptor >= 0) {
          poller_.remove(plugin_descriptor);
        }

        stop();
      }

    private:
      using Clock = std::chrono::steady_clock;

      // Hands a ready event to what its source names; false once a stop signal arrives.
      bool route(const Event& event);

      void accept();

      void admitClient(FileDescriptor descriptor);

      void dropClient(std::uint64_t identity) noexcept;

      // Cross-client effects the services queued while a client was borrowed reach their clients before
      // the clients are written.
      void deliverQueued() noexcept;

      void clientEvent(const Event& event);

      void paneEvent(const Event& event);

      // The client's frames leave its connection while their requests run, so a request can change any
      // client, its own included, without touching the bytes it was decoded from.
      void receive(std::uint64_t identity);

      template <typename Message>
      void request(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage& storage);

      // A failed request answers its client unless the request dropped it.
      void fail(std::uint64_t identity, const RequestFailed& failure);

      void dispatch(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage& storage);

      void handle(std::uint64_t identity, const ReportLimit& message);

      void handle(std::uint64_t identity, const QueryLimits& message);

      void handle(std::uint64_t identity, const LaunchTab& message);

      void handle(std::uint64_t identity, const RegisterWorktree& message);

      void handle(std::uint64_t identity, const LaunchWorktree& message);

      void handle(std::uint64_t identity, const ForgetWorktree& message);

      void handle(std::uint64_t identity, const ExecutionRequest& message);

      void handle(std::uint64_t identity, const VerifyPaneDescent& message);

      void handle(std::uint64_t identity, const ReportAgent& message);

      void handle(std::uint64_t identity, const ReportAgentTitle& message);

      void handle(std::uint64_t identity, const ReportAgentSession& message);

      void handle(std::uint64_t identity, const ReportAgentProgress& message);

      void handle(std::uint64_t identity, const InterruptAgent& message);

      void handle(std::uint64_t, const AcknowledgeAgent& message);

      void handle(std::uint64_t identity, const QueryAgents&);

      void handle(std::uint64_t identity, const ReportAgentCommand& message);

      // Values for a completion: found where the pane's shell runs, from its own PATH and
      // directory when its integration reported them.
      void handle(std::uint64_t identity, const CompleteWords& message);

      // A command's completion spec, for a command the pane's shell runs. A remote shell's
      // commands are its host's, which this runtime cannot tell.
      void handle(std::uint64_t identity, const RequestCommandSpec& message);

      // What a completion asks for, from the PATH and shell of the pane's shell where its
      // integration reported them, this runtime's PATH otherwise.
      WordRequest makeWordRequest(const ClientSession<Memory>& client, std::uint64_t request_id, CompletionProvider provider, std::string_view prefix, const Pane<Memory>& pane) const;

      void handle(std::uint64_t identity, const FindPaths& message);

      void handle(std::uint64_t identity, const OpenEditor& message);

      void handle(std::uint64_t identity, const SuggestCommand& message);

      void handle(std::uint64_t identity, const OpenPane& message);

      void handle(std::uint64_t identity, const CreatePane& message);

      void handle(std::uint64_t identity, const ClosePane& message);

      void handle(std::uint64_t identity, const CreateWorkspace& message);

      void handle(std::uint64_t identity, const RenameWorkspace& message);

      void handle(std::uint64_t identity, const CreateTab& message);

      void handle(std::uint64_t identity, const RenameTab& message);

      void handle(std::uint64_t identity, const CloseTab& message);

      void handle(std::uint64_t identity, const HoldTab& message);

      void handle(std::uint64_t identity, const MoveTab& message);

      void handle(std::uint64_t identity, const RequestTabSnapshot& message);

      void handle(std::uint64_t identity, const RequestWorkspaceSnapshot& message);

      void handle(std::uint64_t identity, const PaneInput& message);

      void handle(std::uint64_t identity, const PaneCommand& message);

      void handle(std::uint64_t identity, const ConfigureShellPrompt& message);

      void handle(std::uint64_t identity, const PaneResize& message);

      void handle(std::uint64_t identity, const ReadRuntimeClipboard& message);

      void handle(std::uint64_t identity, const CompleteClipboardDesktop& message);

      void handle(std::uint64_t identity, const PastePaneClipboard& message);

      void handle(std::uint64_t identity, const ConfigurePaneDesktop& message);

      void handle(std::uint64_t identity, const ConfigureTerminalColors& message);

      void handle(std::uint64_t identity, const SearchPane& message);

      void handle(std::uint64_t identity, const SearchPaneRows& message);

      void handle(std::uint64_t identity, const ReadPaneRows& message);

      void handle(std::uint64_t identity, const CopySelection& message);

      void handle(std::uint64_t identity, const ReadPane& message);

      void handle(std::uint64_t identity, const SendPaneText& message);

      void handle(std::uint64_t identity, const DetachPane& message);

      void handle(std::uint64_t identity, const FrameAck& message);

      void handle(std::uint64_t identity, const RequestSnapshot& message);

      void handle(std::uint64_t identity, const SetPaneViewport& message);

      void handle(std::uint64_t identity, const ConfigureFrameInterval& message);

      void handle(std::uint64_t identity, const RequestRuntimeState& message);

      void handle(std::uint64_t identity, const QueryClients& message);

      void handle(std::uint64_t identity, const DetachClient& message);

      void handle(std::uint64_t identity, const RequestClientCommand& message);

      void handle(std::uint64_t identity, const CompleteClientCommand& message);

      void handle(std::uint64_t identity, const RequestPaneFocus& message);

      void handle(std::uint64_t identity, const CompletePaneFocus& message);

      void handle(std::uint64_t identity, const ShowNotification& message);

      void handle(std::uint64_t identity, const UpdateClientLayout& message);

      void handle(std::uint64_t identity, const QueryHistory& message);

      void handle(std::uint64_t identity, const ImportHistory& message);

      void handle(std::uint64_t identity, const DeleteHistory& message);

      void handle(std::uint64_t identity, const PruneHistory& message);

      void handle(std::uint64_t identity, const ReadHistoryOutput& message);

      void handle(std::uint64_t identity, const HistoryStatsQuery& message);

      void handle(std::uint64_t identity, const ConfigureGraphics& message);

      void handle(std::uint64_t identity, const GraphicsCredit& message);

      void handle(std::uint64_t identity, const RequestGraphicsSnapshot& message);

      void handle(std::uint64_t, const RuntimeStop&);

      template <typename Message>
      static void submitBackground(Background& background, const ClientSession<Memory>& client, const Message& message, RequestContext context = {});

      static bool isHistoryRequest(ClientTag tag) noexcept;

      void collectBackground();

      // A completion's words, or a command's spec, for the client that asked.
      void deliverWords(const WordResult& result);

      // A background worker's reply to `client_id`'s request: history failures become limits, the
      // rest goes to the client, which a failed send drops.
      void deliverBackgroundReply(std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload);

      // An opened editor reported to the client that asked, as failed unless it opened beside the
      // pane it was asked from.
      static void deliverEditorReply(const PaneStore<Memory>& panes, ClientSession<Memory>& client, std::span<const Byte> payload);

      std::chrono::nanoseconds publish(Clock::time_point now);

      std::chrono::nanoseconds writeClient(std::uint64_t identity, Clock::time_point now);

      static void updateWriteInterest(Poller& poller, ClientSession<Memory>& client);

      // A due report runs as its client's next request, its payload and the client's frames held apart
      // from the client meanwhile.
      void answerDeferredReports();

      void stop() noexcept;

      static std::string_view runtimePath();

      Memory& memory_;
      Poller& poller_;
      Background& background_;
      ProxyClientConfiguration proxy_;
      LocalListener listener_;
      RuntimeModel<Memory> model_;
      ClientStore<Memory> clients_;
      LimitService<Memory> limits_;
      RuntimeClipboardService<Memory> runtime_clipboard_;
      ClientAdmission<Memory, Poller> admissions_;
      ClientLayouts<Memory> client_layouts_;
      Panes panes_;
      Workspaces workspaces_;
      Worktrees worktrees_;
      ExecutionService<Memory, Poller> executions_;
      ProcessInspector process_inspector_;
      Agents agents_;
      ProcessProbe<ProcessInspector> process_probe_;
      PaneObservationService<Memory, Agents, LimitService<Memory>, ProcessProbe<ProcessInspector>, Background> observations_;
      MediaService<Memory, Poller, LimitService<Memory>, Background> media_;
      DeferredReports<Memory, Agents> deferred_reports_;
      Descents descents_;
      checkpoint::SessionStore<Memory, Agents> session_;
      HostMetricsService<NativeHostMetrics> metrics_;
      WorkspaceGitService<Memory, WorkspaceGitProbe<Memory>> workspace_git_;
      ShellGitService shell_git_;
      WordService words_;
      // This runtime's PATH, read once: nothing in the runtime changes it.
      std::string_view runtime_path_ = runtimePath();
      WorktreeDetectionService<Memory, WorktreeDetectionProbe> worktree_detection_;
      AgentFileService<Memory, Agents> agent_files_;
      DescriptionService<Memory, Agents, Background> descriptions_;
      [[no_unique_address]] diagnostics::RuntimeTelemetry telemetry_;
      static constexpr auto pane_poll_interval = std::chrono::milliseconds{100};
      Clock::time_point next_pane_poll_{};
      // Set when SIGCHLD arrives; true at first so a child that exited before the loop is reaped.
      bool children_exited_ = true;
    };

    template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
      requires BackgroundExecutor<Background, Memory>
    Runtime(Memory& memory, Poller& poller, Background& background, const RuntimeOptions& options, ProxyClientConfiguration proxy = {}) -> Runtime<Memory, Poller, Background>;

    extern template class Runtime<ConcurrentMemory, NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;

  }
}
