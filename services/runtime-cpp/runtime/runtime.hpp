#pragma once

#include "../diagnostics/runtime_telemetry.hpp"
#include "../diagnostics/trace.hpp"

#include "../editors/kind.hpp"
#include "../exchange_capture/joiner.hpp"
#include "../exchange_capture/source.hpp"
#include "../model/client_layouts.hpp"
#include "../persistence/clone_session.hpp"
#include "../persistence/session_store.hpp"
#include "../platform/host_metrics.hpp"
#include "../platform/local_listener.hpp"
#include "../suggestions/prompt.hpp"
#include "agent_file_service.hpp"
#include "agent_service.hpp"
#include "background_executor.hpp"
#include "client_admission.hpp"
#include "client_control.hpp"
#include "deferred_reports.hpp"
#include "delivery/client_delivery.hpp"
#include "delivery/state_projection.hpp"
#include "descent_service.hpp"
#include "description_service.hpp"
#include "execution_service.hpp"
#include "limit_service.hpp"
#include "media_service.hpp"
#include "metrics_service.hpp"
#include "observation_service.hpp"
#include "options.hpp"
#include "plugin_delivery.hpp"
#include "request_dispatch.hpp"
#include "response_projection.hpp"
#include "workspace_git_service.hpp"
#include "workspace_service.hpp"
#include "worktree_detection_service.hpp"
#include "worktree_service.hpp"
#include <csignal>
#include <sys/wait.h>

namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
class Runtime {
public:
  explicit Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {})
      : memory_(memory),
        poller_(poller),
        background_(background),
        proxy_(proxy),
        listener_(options.socket),
        model_(memory, options.graphics),
        client_control_(model_),
        limits_(model_),
        admissions_(model_, poller_, limits_),
        client_layouts_(memory, model_),
        panes_(memory, model_, poller, PaneLaunchOptions{listener_.path(), proxy}, background),
        workspaces_(memory, model_, panes_),
        worktrees_(memory, model_, workspaces_, limits_),
        executions_(memory, model_, poller_),
        process_inspector_(model_.manifests),
        agents_(memory, model_, panes_, client_layouts_),
        process_probe_(process_inspector_),
        observations_(model_, agents_, limits_, process_probe_, background_),
        media_(model_, panes_, poller_, limits_),
        deferred_reports_(model_, agents_),
        descents_(model_, process_inspector_),
        session_(memory, model_, panes_, client_layouts_, agents_),
        metrics_(host_metrics_),
        workspace_git_probe_(memory),
        workspace_git_(model_, limits_, workspace_git_probe_),
        worktree_detection_(model_, worktree_detector_),
        agent_files_(memory, agents_),
        descriptions_(memory, agents_, background_, options.descriptions),
        telemetry_(options.socket, proxy.status()) {
    model_.executable_path = options.executable;
    model_.capture_output = options.capture_output;
    model_.manifests = *options.manifests;
    if (options.fresh && !options.session.path.empty()) {
      checkpoint::FileStore<Memory>::setAside(memory, options.session.path);
    }
    if (options.fresh) {
      String<Memory> origin{options.socket, AllocatorRef<char, Memory>{memory}};
      origin += ".desktop-clone.json";
      checkpoint::FileStore<Memory>::setAside(memory, origin);
    }
    checkpoint::prepareClone(memory, options.clone, options.session.path, options.socket);
    session_.configure(options.session);
    poller_.watch(listener_.descriptor(), eventToken(EventSource::listener, 0));
    for (const int descriptor : background_.descriptors()) {
      poller_.watch(descriptor, eventToken(EventSource::worker, 0));
    }
    if (session_.descriptor() >= 0) {
      poller_.watch(session_.descriptor(), eventToken(EventSource::worker, 0));
    }
    poller_.watch(observations_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(media_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(descents_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(metrics_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(workspace_git_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(worktree_detection_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(agent_files_.descriptor(), eventToken(EventSource::worker, 0));
    if (descriptions_.descriptor() >= 0) {
      poller_.watch(descriptions_.descriptor(), eventToken(EventSource::worker, 0));
    }
  }

  void run() {
    IgnoreCaptureEvents captures;
    run(captures);
  }

  template <CaptureEventSource Captures>
  void run(Captures &captures) {
    plugins::IgnoreEvents plugins;
    run(captures, plugins);
  }

  template <CaptureEventSource Captures, plugins::EventSource Plugins>
  void run(Captures &captures, Plugins &plugins) {
    TELAR_TRACE("runtime.run");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::interactive});
    PluginDelivery delivery{client_control_, limits_};
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
      delivery.collect(plugins);
      const auto now = Clock::now();
      auto timeout = publish(now);
      TELAR_DIAGNOSTIC(model_.metrics.system = metrics_.diagnostics());
      TELAR_DIAGNOSTIC(timeout = std::min(timeout, telemetry_.tick(model_, memory_, captures, background_, Clock::now())));

      for (const auto &event : poller_.wait(timeout)) {
        if (event.kind == EventKind::signal) {
          if (event.descriptor == SIGCHLD) {
            continue;
          }

          model_.stopping = true;
          break;
        }

        switch (eventSource(event.token)) {
        case EventSource::listener:
          accept();
          break;
        case EventSource::client:
          clientEvent(event);
          break;
        case EventSource::handshake:
          admissions_.event(event, [this](FileDescriptor descriptor) { admitClient(std::move(descriptor)); });
          break;
        case EventSource::pane:
          paneEvent(event);
          break;
        case EventSource::execution_output:
        case EventSource::execution_error:
        case EventSource::execution_input:
          executions_.event(event);
          break;
        case EventSource::worker:
          collectBackground();
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

  void accept() {
    constexpr unsigned accept_batch = 16;
    for (unsigned index = 0; index < accept_batch; ++index) {
      auto descriptor = listener_.accept();
      if (!descriptor) {
        return;
      }

      try {
        admissions_.begin(std::move(descriptor));
      } catch (const std::exception &) {
        return;
      }
    }
  }

  void admitClient(FileDescriptor descriptor) {
    const auto identity = model_.clients.nextId();
    auto client = makeOwned<ClientSession<Memory>>(memory_, memory_, identity, std::move(descriptor));
    client->connection.negotiated = true;
    client->peer_identity = process_inspector_.peer(client->connection.descriptor());
    auto &retained = *client;
    retained.event_identity = model_.clients.insert(identity, std::move(client));
    try {
      if (retained.event_identity > maximum_event_identity) {
        throw std::bad_alloc{};
      }
      poller_.watch(retained.connection.descriptor(), eventToken(EventSource::client, retained.event_identity));
    } catch (...) {
      dropClient(identity);
      throw;
    }
  }

  void dropClient(std::uint64_t identity) noexcept {
    auto *client = model_.clients.find(identity);
    if (client == nullptr) {
      return;
    }

    try {
      executions_.disconnect(identity);
    } catch (...) {
    }

    background_.cancel(identity);
    deferred_reports_.cancel(*client);
    client->connection.closing = true;
    panes_.detachAll(*client);
    workspaces_.releaseHeldTabs(*client);
    releaseAllGeometry(model_, identity);
    client_control_.abandon(identity);
    poller_.remove(client->connection.descriptor());
    model_.clients.erase(identity);
  }

  void clientEvent(const Event &event) {
    auto *client = model_.clients.findHandle(eventIdentity(event.token));
    if (client == nullptr || client->connection.descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_client_messages));
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        if (client->connection.read_paused) {
          return;
        }

        if (!client->connection.read()) {
          dropClient(client->id);
          return;
        }

        receive(*client);
      } else {
        writeClient(*client, Clock::now());
      }

      updateWriteInterest(*client);
    } catch (const std::exception &) {
      dropClient(client->id);
    }
  }

  void paneEvent(const Event &event) {
    TELAR_TRACE("runtime.paneEvent");
    auto *pane = model_.panes.findHandle(eventIdentity(event.token));
    if (pane == nullptr || pane->process->descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        const auto mode = model_.panes.size() == 1 ? Pane<Memory>::ReadMode::burst : Pane<Memory>::ReadMode::once;
        if (!pane->read(mode)) {
          poller_.remove(pane->process->descriptor());
        }
      }

      panes_.flushInput(*pane);
      observations_.observe(*pane);
      media_.updateReadInterest(*pane);
    } catch (const std::exception &) {
      pane->requestClose();
      pane->output_closed = true;
      poller_.remove(pane->process->descriptor());
    }
  }

  void receive(ClientSession<Memory> &client) {
    client.connection.buffered_requests = client.connection.dispatch([&](std::span<const Byte> payload, DecodeStorage &storage) {
      if (client.connection.closing) {
        return;
      }

      dispatch(client, payload, storage);
    });
  }

  template <typename Message>
  void request(ClientSession<Memory> &client, std::span<const Byte> payload, DecodeStorage &storage) {
    const auto message = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{model_.metrics.decode});
      return Codec::decode<Message>(payload, storage);
    }();
    if (client.role == ClientRole::undecided) {
      if constexpr (std::same_as<Message, RequestRuntimeState>) {
        client.role = message.interactive ? ClientRole::interactive : ClientRole::control;
      } else {
        client.role = classifyRequest(static_cast<ClientTag>(payload.front()));
      }
    }

    std::uint64_t request_id = 0;
    if constexpr (requires { message.request_id; }) {
      request_id = message.request_id;
    }

    try {
      if (const auto reporter = reporterOf(model_.manifests, message)) {
        const auto decision = deferred_reports_.evaluate(client, *reporter, payload);
        if (decision == ReportDecision::rejected) {
          client.connection.send(RequestFailed{.request_id = request_id, .code = FailureCode::foreign_process, .message = "The report belongs to another agent"});
          return;
        }
        if (decision == ReportDecision::deferred) {
          try {
            observations_.observe(*model_.panes.find(reporter->pane));
          } catch (...) {
            deferred_reports_.cancel(client);
            client.deferred_report.payload.clear();
            throw;
          }
          return;
        }
      }

      handle(client, message);
    } catch (const RequestError &error) {
      if (error.code() == FailureCode::resource_limit) {
        limits_.report(LimitReach{.name = "runtime.request_capacity",
                                  .route = "request"});
      }
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = error.code(),
                                           .message = error.what()});
    } catch (const SystemError &error) {
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::spawn_failed,
                                           .message = error.what()});
    } catch (const std::bad_alloc &) {
      limits_.report(LimitReach{.name = "runtime.memory",
                                .route = "request"});
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::resource_limit,
                                           .message = "Runtime memory or capacity limit reached"});
    }
  }

  void dispatch(ClientSession<Memory> &client, std::span<const Byte> payload, DecodeStorage &storage) {
    TELAR_TRACE("runtime.dispatch");
    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_messages));
    const bool recognized = dispatchRequest(static_cast<ClientTag>(payload.front()), [&]<typename Message> {
      request<Message>(client, payload, storage);
    });

    if (!recognized) {
      throw EncodingError{"Unknown request tag"};
    }
  }

  void handle(ClientSession<Memory> &client, const ReportLimit &message) {
    limits_.receive(client, message);
  }

  void handle(ClientSession<Memory> &client, const QueryLimits &message) {
    limits_.query(client, message);
  }

  void handle(ClientSession<Memory> &client, const LaunchTab &message) {
    workspaces_.launchTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const RegisterWorktree &message) {
    worktrees_.registerEntry(client, message);
  }

  void handle(ClientSession<Memory> &client, const LaunchWorktree &message) {
    worktrees_.launch(client, message);
  }

  void handle(ClientSession<Memory> &client, const ForgetWorktree &message) {
    worktrees_.forget(client, message);
  }

  void handle(ClientSession<Memory> &client, const ExecutionRequest &message) {
    executions_.request(client, message);
  }

  void handle(ClientSession<Memory> &client, const VerifyPaneDescent &message) {
    descents_.verify(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReportAgent &message) {
    agents_.report(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReportAgentTitle &message) {
    agents_.reportTitle(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReportAgentSession &message) {
    agents_.reportSession(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReportAgentProgress &message) {
    if (!agents_.reportProgress(client, message)) {
      limits_.report(LimitReach{.name = "agents.max_tasks", .noun = "tasks", .value = AgentProgress::task_capacity, .requested = AgentProgress::task_capacity + 1, .route = "agents"});
    }
  }

  void handle(ClientSession<Memory> &client, const InterruptAgent &message) {
    agents_.interrupt(client, message);
  }

  void handle(ClientSession<Memory> &, const AcknowledgeAgent &message) {
    agents_.acknowledge(message);
  }

  void handle(ClientSession<Memory> &client, const QueryAgents &) {
    client.agent_snapshot_requested = true;
  }

  void handle(ClientSession<Memory> &client, const ReportAgentCommand &message) {
    const auto &pane = agents_.validateCommand(client, message);
    const auto *workspace = model_.workspaces.find(pane.location.workspace.id);
    background_.submit(client.id, message, RequestContext{.location = pane.location, .history_session = pane.history_session, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .received_at_ms = client.deferred_report.reportTime().milliseconds});
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  void handle(ClientSession<Memory> &client, const FindPaths &message) {
    if (!background_.tryPaths(client.id, message, client.connection)) {
      submitBackground(client, message);
    }
  }

  void handle(ClientSession<Memory> &client, const OpenEditor &message) {
    const auto *source = model_.panes.find(message.pane_id);
    if (source == nullptr || (message.pane_generation != 0 && source->generation != message.pane_generation)) {
      throw RequestError{FailureCode::pane_not_found, "Could not request editor reuse"};
    }

    if (source->exit_status || source->close_requested) {
      throw RequestError{FailureCode::pane_exited, "Could not request editor reuse"};
    }

    if (background_.editorBusy()) {
      throw RequestError{FailureCode::resource_limit, "Could not request editor reuse"};
    }

    RequestContext context;
    const auto editor = identifyEditor(message.editor);
    if (editor != EditorKind::unsupported) {
      for (const auto *pane : model_.panes.items()) {
        if (pane == nullptr || pane->exit_status || pane->close_requested || pane->location.workspace.id != source->location.workspace.id || pane->location.tab_id != source->location.tab_id || identifyEditor(pane->process_cache.identified.name.view()) != editor) {
          continue;
        }

        const auto group = ::tcgetpgrp(pane->process->descriptor());
        const auto identity = group > 0 ? process_inspector_.identity(group) : std::nullopt;
        if (identity && context.editor_candidate_count < context.editor_candidates.size()) {
          context.editor_candidates[context.editor_candidate_count++] = {pane->id, pane->generation, *identity};
        }
      }
    }

    submitBackground(client, message, context);
    client.editor_source = source->id;
    client.editor_generation = source->generation;
  }

  void handle(ClientSession<Memory> &client, const SuggestCommand &message) {
    if (!background_.suggestionsAvailable()) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::unavailable});
      return;
    }

    auto *pane = model_.panes.find(message.pane_id);
    if (pane == nullptr) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
      return;
    }

    try {
      TextReader reader{memory_, pane->terminal, 4096};
      reader.read(PaneTextSource::screen, 24);
      const auto prompt = suggestionPrompt(memory_, pane->cwd, reader.text(), message.text);
      submitBackground(client, message, RequestContext{.prompt = prompt});
    } catch (const RequestError &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    } catch (const std::bad_alloc &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    }
  }

  void handle(ClientSession<Memory> &client, const OpenPane &message) {
    workspaces_.open(client, message);
  }

  void handle(ClientSession<Memory> &client, const CreatePane &message) {
    workspaces_.createPane(client, message);
  }

  void handle(ClientSession<Memory> &client, const ClosePane &message) {
    workspaces_.closePane(client, message);
  }

  void handle(ClientSession<Memory> &client, const CreateWorkspace &message) {
    workspaces_.createWorkspace(client, message);
  }

  void handle(ClientSession<Memory> &client, const RenameWorkspace &message) {
    workspaces_.renameWorkspace(client, message);
  }

  void handle(ClientSession<Memory> &client, const CreateTab &message) {
    workspaces_.createTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const RenameTab &message) {
    workspaces_.renameTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const CloseTab &message) {
    workspaces_.closeTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const HoldTab &message) {
    workspaces_.holdTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const MoveTab &message) {
    workspaces_.moveTab(client, message);
  }

  void handle(ClientSession<Memory> &client, const RequestTabSnapshot &message) {
    workspaces_.tabSnapshot(client, message);
  }

  void handle(ClientSession<Memory> &client, const RequestWorkspaceSnapshot &message) {
    workspaces_.workspaceSnapshot(client, message);
  }

  void handle(ClientSession<Memory> &client, const PaneInput &message) {
    panes_.input(client, message, [this](const Pane<Memory> &pane, std::span<const Byte> bytes) { agents_.observeInput(pane, bytes); });
  }

  void handle(ClientSession<Memory> &client, const PaneResize &message) {
    panes_.resize(client, message);
  }

  void handle(ClientSession<Memory> &client, const ConfigureTerminalColors &message) {
    panes_.configureColors(client, message);
  }

  void handle(ClientSession<Memory> &client, const SearchPane &message) {
    panes_.search(client, message);
  }

  void handle(ClientSession<Memory> &client, const CopySelection &message) {
    panes_.copySelection(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReadPane &message) {
    panes_.readText(client, message);
  }

  void handle(ClientSession<Memory> &client, const SendPaneText &message) {
    agents_.sendText(client, message);
  }

  void handle(ClientSession<Memory> &client, const DetachPane &message) {
    panes_.detach(client, message.pane_id);
  }

  void handle(ClientSession<Memory> &client, const FrameAck &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->frames.acknowledge(message.frame_id);
    }
  }

  void handle(ClientSession<Memory> &client, const RequestSnapshot &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->frames.requestSnapshot();
    }
  }

  void handle(ClientSession<Memory> &client, const SetPaneViewport &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->viewport = message.offset;
      attachment->frames.requestSnapshot();
    }
  }

  void handle(ClientSession<Memory> &client, const ConfigureFrameInterval &message) {
    client.frame_interval = std::chrono::nanoseconds{message.interval_ns};
  }

  void handle(ClientSession<Memory> &client, const RequestRuntimeState &message) {
    if (client.identity != 0 && client.identity != message.client_identity) {
      throw EncodingError{"Subscribed client identity cannot change"};
    }
    if (client.subscribed) {
      return;
    }

    client.identity = message.client_identity;
    client.interactive = message.interactive;
    client.subscribed = true;
    client.workspace_revision = 0;
    client.agent_snapshot_requested = true;
  }

  void handle(ClientSession<Memory> &client, const QueryClients &message) {
    client_control_.list(client, message);
  }

  void handle(ClientSession<Memory> &client, const DetachClient &message) {
    client_control_.detach(client, message);
  }

  void handle(ClientSession<Memory> &client, const RequestClientCommand &message) {
    client_control_.requestCommand(client, message);
  }

  void handle(ClientSession<Memory> &client, const CompleteClientCommand &message) {
    client_control_.completeCommand(client, message);
  }

  void handle(ClientSession<Memory> &client, const RequestPaneFocus &message) {
    client_control_.requestFocus(client, message);
  }

  void handle(ClientSession<Memory> &client, const CompletePaneFocus &message) {
    client_control_.completeFocus(client, message);
  }

  void handle(ClientSession<Memory> &client, const ShowNotification &message) {
    client_control_.notify(client, message);
  }

  void handle(ClientSession<Memory> &client, const UpdateClientLayout &message) {
    client_layouts_.retain(client.identity, message);
  }

  void handle(ClientSession<Memory> &client, const QueryHistory &message) {
    submitBackground(client, message, RequestContext{.persistent_client = client.role == ClientRole::interactive});
  }

  void handle(ClientSession<Memory> &client, const ImportHistory &message) {
    submitBackground(client, message);
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  void handle(ClientSession<Memory> &client, const DeleteHistory &message) {
    submitBackground(client, message);
  }

  void handle(ClientSession<Memory> &client, const PruneHistory &message) {
    submitBackground(client, message);
  }

  void handle(ClientSession<Memory> &client, const ReadHistoryOutput &message) {
    submitBackground(client, message);
  }

  void handle(ClientSession<Memory> &client, const HistoryStatsQuery &message) {
    submitBackground(client, message);
  }

  template <typename Message>
  void submitBackground(ClientSession<Memory> &client, const Message &message, RequestContext context = {}) {
    if constexpr (std::same_as<Message, OpenEditor>) {
      if (client.editor_source != 0) {
        throw RequestError{FailureCode::resource_limit, "An editor request is already pending"};
      }
    }

    background_.submit(client.id, message, context);
  }

  void collectBackground() {
    TELAR_TRACE("runtime.collectBackground");
    session_.collect();
    observations_.collect();
    media_.collect();
    descents_.collect();
    answerDeferredReports();
    metrics_.collect();
    workspace_git_.collect(Clock::now());
    worktree_detection_.collect();
    agent_files_.collect();
    descriptions_.collect();
    if (const auto failures = background_.takeHistoryFailures()) {
      limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed events", .requested = failures, .route = "history"});
    }
    background_.collectWorktrees([&](const WorktreeProbeResult &result) { worktrees_.observed(result); });
    background_.collect([&](std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) {
      if (request_tag == ClientTag::import_history) {
        return;
      }

      if (request_tag == ClientTag::report_agent_command) {
        if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
          limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed commands", .route = "history"});
        }
        return;
      }

      auto *client = model_.clients.find(client_id);
      if (client == nullptr || client->connection.closing) {
        return;
      }

      try {
        if (payload.front() == static_cast<Byte>(ServerTag::editor_opened)) {
          std::array<Byte, 256> scratch;
          DecodeStorage storage{scratch};
          auto reply = Codec::decode<EditorOpened>(payload, storage);
          const auto *source = model_.panes.find(client->editor_source);
          const auto *target = model_.panes.find(reply.pane_id);
          if (source == nullptr || source->generation != client->editor_generation || source->exit_status || source->close_requested ||
              (reply.outcome == EditorOutcome::opened && (target == nullptr || target->generation != reply.pane_generation || target->exit_status || target->close_requested || target->location.workspace.id != source->location.workspace.id || target->location.tab_id != source->location.tab_id))) {
            reply.outcome = EditorOutcome::failed;
          }
          client->editor_source = 0;
          client->connection.send(reply);
        } else {
          const auto tag = static_cast<ServerTag>(payload.front());
          if (tag == ServerTag::history_results || tag == ServerTag::history_output || tag == ServerTag::history_stats_result || tag == ServerTag::command_suggestion) {
            client->connection.trySendPayload(payload);
          } else {
            client->connection.sendPayload(payload);
          }

          if (client->role == ClientRole::control && isHistoryRequest(request_tag)) {
            client->connection.closing = true;
          }
          if (request_tag == ClientTag::open_editor) {
            client->editor_source = 0;
          }
        }
        updateWriteInterest(*client);
      } catch (...) {
        dropClient(client_id);
      }
    });
  }

  void handle(ClientSession<Memory> &client, const ConfigureGraphics &message) {
    client.shared_graphics = message.shared;
    for (auto &attachment : client.attachments) {
      attachment->graphics.configure(message.shared);
    }
  }

  static bool isHistoryRequest(ClientTag tag) noexcept {
    switch (tag) {
    case ClientTag::query_history:
    case ClientTag::import_history:
    case ClientTag::delete_history:
    case ClientTag::prune_history:
    case ClientTag::read_history_output:
    case ClientTag::history_stats:
      return true;
    default:
      return false;
    }
  }

  void handle(ClientSession<Memory> &client, const GraphicsCredit &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->graphics.returnCredit(message.bytes);
    }
  }

  void handle(ClientSession<Memory> &client, const RequestGraphicsSnapshot &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->graphics.requestSnapshot();
    }
  }

  void handle(ClientSession<Memory> &, const RuntimeStop &) {
    model_.stopping = true;
  }

  std::chrono::nanoseconds publish(Clock::time_point now) {
    TELAR_TRACE("runtime.publish");
    admissions_.expire(now);
    media_.collect();
    std::chrono::nanoseconds timeout = std::chrono::milliseconds{100};
    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr && !pane->exit_status) {
        pane->exit_status = pane->process->reap();
      }

      if (pane != nullptr && pane->exit_status && pane->output_closed && !pane->exit_observed) {
        pane->observer->shellExit(*pane->exitCode());
        pane->exit_observed = true;
      }
    }

    if (executions_.refresh()) {
      timeout = std::min(timeout, std::chrono::nanoseconds{std::chrono::milliseconds{10}});
    }

    try {
      observations_.refresh();
      answerDeferredReports();
      agents_.refresh();
      agent_files_.tick(now);
      descriptions_.tick();
      worktree_detection_.tick();
    } catch (const std::bad_alloc &) {
    } catch (const RequestError &) {
    }

    worktrees_.refresh();
    worktrees_.observe(background_);
    workspaces_.collectExited();
    timeout = std::min(timeout, session_.tick(now));
    timeout = std::min(timeout, metrics_.tick(now));
    timeout = std::min(timeout, workspace_git_.tick(now));

    for (auto *client : model_.clients.items()) {
      if (client == nullptr) {
        continue;
      }

      if (client->connection.closing && !client->connection.hasOutput()) {
        dropClient(client->id);
        continue;
      }

      try {
        if (client->connection.closing) {
          client->connection.write(ResponseProjection{memory_, model_});
          updateWriteInterest(*client);
          continue;
        }

        if (client->connection.buffered_requests && !client->connection.read_paused) {
          receive(*client);
          timeout = std::chrono::nanoseconds::zero();
        }

        if (panes_.advanceSearch(*client)) {
          timeout = std::chrono::nanoseconds::zero();
        }

        timeout = std::min(timeout, writeClient(*client, now));
        updateWriteInterest(*client);
      } catch (const std::exception &) {
        dropClient(client->id);
      }
    }

    media_.start();
    return timeout;
  }

  std::chrono::nanoseconds writeClient(ClientSession<Memory> &client, Clock::time_point now) {
    StateProjection state{workspaces_, agents_, metrics_, client_layouts_, proxy_};
    ClientDelivery delivery{memory_, model_};
    const auto result = delivery.write(client, state, now);
    if (result.detach_pane) {
      panes_.release(client, *result.detach_pane);
    }
    return result.timeout;
  }

  void updateWriteInterest(ClientSession<Memory> &client) {
    const bool enabled = client.connection.hasOutput();
    if (enabled != client.connection.write_interest) {
      poller_.writeInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), enabled);
      client.connection.write_interest = enabled;
    }

    const bool readable = !client.connection.read_paused;
    if (readable != client.connection.read_interest) {
      poller_.readInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), readable);
      client.connection.read_interest = readable;
    }
  }

  void answerDeferredReports() {
    deferred_reports_.answerDue(ObservationTime::now(), [this](ClientSession<Memory> &client, std::span<const Byte> payload) {
      client.connection.replay(payload, [&](std::span<const Byte> bytes, DecodeStorage &storage) { dispatch(client, bytes, storage); });
      updateWriteInterest(client);
    });
  }

  void stop() noexcept {
    admissions_.clear();
    session_.finish();
    for (auto *client : model_.clients.items()) {
      if (client == nullptr) {
        continue;
      }

      try {
        client->connection.send(RuntimeStopping{});
        client->connection.write(ResponseProjection{memory_, model_});
      } catch (...) {
      }

      dropClient(client->id);
    }

    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        pane->process->signal(SIGTERM);
        pane->observer->finishSession();
      }
    }

    observations_.finish();
    media_.finish();
  }

  Memory &memory_;
  Poller &poller_;
  Background &background_;
  ProxyClientConfiguration proxy_;
  LocalListener listener_;
  RuntimeModel<Memory> model_;
  ClientControl<Memory> client_control_;
  LimitService<Memory> limits_;
  ClientAdmission<Memory, Poller> admissions_;
  ClientLayouts<Memory> client_layouts_;
  PaneService<Memory, Poller, Background> panes_;
  WorkspaceService<Memory, Poller, Background> workspaces_;
  WorktreeService<Memory, Poller, Background> worktrees_;
  ExecutionService<Memory, Poller> executions_;
  ProcessInspector process_inspector_;
  AgentService<Memory, Poller, Background> agents_;
  ProcessProbe<ProcessInspector> process_probe_;
  PaneObservationService<Memory, decltype(agents_), decltype(limits_), decltype(process_probe_), Background> observations_;
  MediaService<Memory, Poller, decltype(limits_), Background> media_;
  DeferredReports<Memory, decltype(agents_)> deferred_reports_;
  DescentService<Memory, ProcessInspector> descents_;
  checkpoint::SessionStore<Memory, Poller, decltype(agents_), Background> session_;
  NativeHostMetrics host_metrics_;
  HostMetricsService<NativeHostMetrics> metrics_;
  WorkspaceGitProbe<Memory> workspace_git_probe_;
  WorkspaceGitService<Memory, decltype(workspace_git_probe_)> workspace_git_;
  WorktreeDetectionProbe worktree_detector_;
  WorktreeDetectionService<Memory, WorktreeDetectionProbe> worktree_detection_;
  AgentFileService<Memory, decltype(agents_)> agent_files_;
  DescriptionService<Memory, decltype(agents_), Background> descriptions_;
  [[no_unique_address]] diagnostics::RuntimeTelemetry telemetry_;
};

template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {}) -> Runtime<Memory, Poller, Background>;

}
