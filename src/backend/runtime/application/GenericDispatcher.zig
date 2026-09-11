const GenericRuntimePort = @import("GenericRuntimePort.zig").Type;
const Session = @import("../client/Session.zig");
const Repository = @import("../../workspace/Repository.zig");
const GenericHandlers = @import("../client/GenericHandlers.zig").Type;
const GenericRouter = @import("../client/GenericRouter.zig").Type;
const OpenPaneViewType = @import("telar-core").OpenPaneView;
const OpenPaneHandlerType = @import("commands/OpenPaneHandler.zig");
const OpenPaneController = @import("../entrypoints/requests/OpenPaneController.zig");
const PaneInputType = @import("telar-core").PaneInput;
const PaneInputHandlerType = @import("commands/PaneInputHandler.zig");
const request_dispatch = @import("request_dispatch.zig");
const RequestPaneFocusType = @import("telar-core").RequestPaneFocus;
const CompletePaneFocusType = @import("telar-core").CompletePaneFocus;
const PaneIdType = @import("telar-core").PaneId;
const PaneFocusController = @import("../entrypoints/requests/PaneFocusController.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const PaneResizeHandlerType = @import("commands/PaneResizeHandler.zig");
const FrameAckType = @import("telar-core").FrameAck;
const FrameAckHandlerType = @import("commands/FrameAckHandler.zig");
const RequestSnapshotType = @import("telar-core").RequestSnapshot;
const RequestCellSnapshotHandlerType = @import("commands/RequestCellSnapshotHandler.zig");
const DetachPaneType = @import("telar-core").DetachPane;
const DetachPaneHandlerType = @import("commands/DetachPaneHandler.zig");
const DetachPaneController = @import("../entrypoints/requests/DetachPaneController.zig");
const RuntimeStopHandlerType = @import("commands/RuntimeStopHandler.zig");
const RuntimeStopController = @import("../entrypoints/requests/RuntimeStopController.zig");
const RequestTabSnapshotType = @import("telar-core").RequestTabSnapshot;
const TabSnapshotHandler = @import("queries/TabSnapshotHandler.zig");
const TabSnapshotController = @import("../entrypoints/requests/TabSnapshotController.zig");
const CreatePaneViewType = @import("telar-core").CreatePaneView;
const CreatePaneHandlerType = @import("commands/CreatePaneHandler.zig");
const CreatePaneController = @import("../entrypoints/requests/CreatePaneController.zig");
const ClosePaneType = @import("telar-core").ClosePane;
const ClosePaneHandlerType = @import("commands/ClosePaneHandler.zig");
const ClosePaneController = @import("../entrypoints/requests/ClosePaneController.zig");
const QueryHistoryType = @import("telar-core").QueryHistory;
const HistoryHandler = @import("queries/HistoryHandler.zig");
const HistoryQueryController = @import("../entrypoints/requests/HistoryQueryController.zig");
const SuggestCommandType = @import("telar-core").SuggestCommand;
const max_pane_text_bytes_module = @import("telar-core").max_pane_text_bytes;
const suggestion = @import("suggestion.zig");
const types = @import("../../engine/types.zig");
const raw_module = @import("telar-core").raw;
const PromptType = @import("../../engine/Prompt.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const RequestIdType = @import("telar-core").RequestId;
const SuggestionStatusType = @import("telar-core").SuggestionStatus;
const DeleteHistoryType = @import("telar-core").DeleteHistory;
const PruneHistoryController = @import("../entrypoints/requests/PruneHistoryController.zig");
const PruneHistoryType = @import("telar-core").PruneHistory;
const ReadHistoryOutputType = @import("telar-core").ReadHistoryOutput;
const HistoryOutputController = @import("../entrypoints/requests/HistoryOutputController.zig");
const HistoryStatsQueryType = @import("telar-core").HistoryStatsQuery;
const ImportHistoryViewType = @import("telar-core").ImportHistoryView;
const ImportHistoryController = @import("../entrypoints/requests/ImportHistoryController.zig");
const RequestWorkspaceSnapshotType = @import("telar-core").RequestWorkspaceSnapshot;
const WorkspaceSnapshotHandler = @import("queries/WorkspaceSnapshotHandler.zig");
const WorkspaceSnapshotController = @import("../entrypoints/requests/WorkspaceSnapshotController.zig");
const CreateTabViewType = @import("telar-core").CreateTabView;
const CreateTabHandlerType = @import("commands/CreateTabHandler.zig");
const CreateTabController = @import("../entrypoints/requests/CreateTabController.zig");
const RenameTabType = @import("telar-core").RenameTab;
const RenameTabHandlerType = @import("commands/RenameTabHandler.zig");
const RenameTabController = @import("../entrypoints/requests/RenameTabController.zig");
const CloseTabType = @import("telar-core").CloseTab;
const CloseTabHandlerType = @import("commands/CloseTabHandler.zig");
const CloseTabController = @import("../entrypoints/requests/CloseTabController.zig");
const MoveTabType = @import("telar-core").MoveTab;
const MoveTabHandlerType = @import("commands/MoveTabHandler.zig");
const MoveTabController = @import("../entrypoints/requests/MoveTabController.zig");
const RequestGraphicsSnapshotType = @import("telar-core").RequestGraphicsSnapshot;
const RequestGraphicsSnapshotHandlerType = @import("commands/RequestGraphicsSnapshotHandler.zig");
const GraphicsCreditType = @import("telar-core").GraphicsCredit;
const ReturnGraphicsCreditHandlerType = @import("commands/ReturnGraphicsCreditHandler.zig");
const ConfigureGraphicsType = @import("telar-core").ConfigureGraphics;
const ConfigureGraphicsHandlerType = @import("commands/ConfigureGraphicsHandler.zig");
const TerminalColors = @import("telar-core").TerminalColors;
const GenericHandler = @import("commands/GenericHandler.zig").Type;
const GenericTerminalColorsController = @import("../entrypoints/requests/GenericTerminalColorsController.zig").Type;
const RequestRuntimeStateType = @import("telar-core").RequestRuntimeState;
const ClientLayoutUpdateViewType = @import("telar-core").ClientLayoutUpdateView;
const CreateWorkspaceViewType = @import("telar-core").CreateWorkspaceView;
const CreateWorkspaceHandlerType = @import("commands/CreateWorkspaceHandler.zig");
const CreateWorkspaceController = @import("../entrypoints/requests/CreateWorkspaceController.zig");
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const RenameWorkspaceHandlerType = @import("commands/RenameWorkspaceHandler.zig");
const RenameWorkspaceController = @import("../entrypoints/requests/RenameWorkspaceController.zig");
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const SetPaneViewportHandlerType = @import("commands/SetPaneViewportHandler.zig");
const AcknowledgeAgentType = @import("telar-core").AcknowledgeAgent;
const AcknowledgeAgentHandlerType = @import("commands/AcknowledgeAgentHandler.zig");
const std = @import("std");
const QueryAgentsType = @import("telar-core").QueryAgents;
const ReadPaneType = @import("telar-core").ReadPane;
const ReadPaneController = @import("../entrypoints/requests/ReadPaneController.zig");
const SendPaneTextType = @import("telar-core").SendPaneText;
const SendPaneTextHandlerType = @import("commands/SendPaneTextHandler.zig");
const ReportAgentSessionType = @import("telar-core").ReportAgentSession;
const ReportAgentSessionHandlerType = @import("commands/ReportAgentSessionHandler.zig");
const ReportAgentType = @import("telar-core").ReportAgent;
const ReportAgentHandlerType = @import("commands/ReportAgentHandler.zig");
const sound_module = @import("../../agent/sound.zig");
const ReportAgentCommandType = @import("telar-core").ReportAgentCommand;
const ReportAgentCommandHandlerType = @import("commands/ReportAgentCommandHandler.zig");
const ReportAgentTitleType = @import("telar-core").ReportAgentTitle;
const ReportAgentTitleHandlerType = @import("commands/ReportAgentTitleHandler.zig");
const SearchPaneType = @import("telar-core").SearchPane;
const pane_search = @import("pane_search.zig");
const CopySelectionType = @import("telar-core").CopySelection;
const CopySelectionHandlerType = @import("commands/CopySelectionHandler.zig");
const ShowNotificationType = @import("telar-core").ShowNotification;
const ShowNotificationHandlerType = @import("commands/ShowNotificationHandler.zig");
const ShowNotificationController = @import("../entrypoints/requests/ShowNotificationController.zig");
const PaneInputScheduler = @import("commands/PaneInputScheduler.zig");
const PaneResizeScheduler = @import("commands/PaneResizeScheduler.zig");
const PaneType = @import("../../pane/Pane.zig");
const ClientKeyType = @import("../../history/ClientKey.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const ServiceType = @import("../../history/Service.zig");
const QueryType = @import("../../history/Query.zig");
const TabLocationType = @import("telar-core").TabLocation;
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const PaneDetachedType = @import("../attachment/PaneDetached.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const PaneLaunchedType = @import("../../pane/PaneLaunched.zig");
const OpenPanePrepareLaunch = @import("commands/OpenPanePrepareLaunch.zig");
const launch_cwd_module = @import("../client/launch_cwd.zig");
const OpenPaneLaunchPane = @import("commands/OpenPaneLaunchPane.zig");
const PrepareViewType = @import("commands/PrepareView.zig");
const open_pane_commands = @import("commands/open_pane.zig");
const CreateTabPrepareLaunch = @import("commands/CreateTabPrepareLaunch.zig");
const CreateTabLaunchedPane = @import("commands/CreateTabLaunchedPane.zig");
const CreateTabLaunchPane = @import("commands/CreateTabLaunchPane.zig");
const CreateWorkspacePrepareLaunch = @import("commands/CreateWorkspacePrepareLaunch.zig");
const CreateWorkspaceLaunchPane = @import("commands/CreateWorkspaceLaunchPane.zig");
const CreateWorkspaceLaunchedPane = @import("commands/CreateWorkspaceLaunchedPane.zig");
const CreatePanePrepareLaunch = @import("commands/CreatePanePrepareLaunch.zig");
const CreatePaneLaunchPane = @import("commands/CreatePaneLaunchPane.zig");
const TabCreatedType = @import("../../workspace/TabCreated.zig");
const TabRenamedType = @import("../../workspace/TabRenamed.zig");
const TabMovedType = @import("../../workspace/TabMoved.zig");
const WorkspaceRenamedType = @import("../../workspace/WorkspaceRenamed.zig");
const WorkspaceCreatedType = @import("../../workspace/WorkspaceCreated.zig");
const TabRemovedType = @import("../../workspace/TabRemoved.zig");
const NotificationsType = @import("commands/Notifications.zig");
const StopRequestedType = @import("../lifecycle/StopRequested.zig");
const NotificationPublisherType = @import("commands/NotificationPublisher.zig");
const NotificationType = @import("telar-core").Notification;
const DeliveryType = @import("../entrypoints/requests/Delivery.zig");
const ClientMessageType = @import("telar-core").ClientMessage;

/// Builds the request dispatcher for one application type and its pane actor
/// scheduling port.
///
/// ```zig
/// const RequestDispatcher = Dispatcher(Application, runtime_port);
/// ```
pub fn Type(comptime Application: type, comptime runtime_port: GenericRuntimePort(Application)) type {
    return struct {
        const Self = @This();

        const ClientRequestContext = struct {
            application: *Application,
            session: *Session,
            workspaces: Repository,

            fn init(application: *Application, session: *Session) ClientRequestContext {
                return .{
                    .application = application,
                    .session = session,
                    .workspaces = application.workspaceRepository(),
                };
            }
        };

        const client_request_handlers: GenericHandlers(ClientRequestContext) = .{
            .open_pane = routeOpenPane,
            .pane_input = routePaneInput,
            .pane_resize = routePaneResize,
            .frame_ack = routeFrameAck,
            .request_snapshot = routeRequestSnapshot,
            .detach_pane = routeDetachPane,
            .runtime_stop = routeRuntimeStop,
            .request_tab_snapshot = routeRequestTabSnapshot,
            .create_pane = routeCreatePane,
            .close_pane = routeClosePane,
            .query_history = routeQueryHistory,
            .suggest_command = routeSuggestCommand,
            .request_workspace_snapshot = routeRequestWorkspaceSnapshot,
            .create_tab = routeCreateTab,
            .rename_tab = routeRenameTab,
            .close_tab = routeCloseTab,
            .move_tab = routeMoveTab,
            .request_graphics_snapshot = routeRequestGraphicsSnapshot,
            .graphics_credit = routeGraphicsCredit,
            .configure_graphics = routeConfigureGraphics,
            .configure_terminal_colors = routeConfigureTerminalColors,
            .request_runtime_state = routeRequestRuntimeState,
            .create_workspace = routeCreateWorkspace,
            .rename_workspace = routeRenameWorkspace,
            .set_pane_viewport = routeSetPaneViewport,
            .copy_selection = routeCopySelection,
            .show_notification = routeShowNotification,
            .update_client_layout = routeUpdateClientLayout,
            .acknowledge_agent = routeAcknowledgeAgent,
            .query_agents = routeQueryAgents,
            .read_pane = routeReadPane,
            .send_pane_text = routeSendPaneText,
            .report_agent_session = routeReportAgentSession,
            .report_agent = routeReportAgent,
            .report_agent_command = routeReportAgentCommand,
            .report_agent_title = routeReportAgentTitle,
            .search_pane = routeSearchPane,
            .import_history = routeImportHistory,
            .delete_history = routeDeleteHistory,
            .prune_history = routePruneHistory,
            .read_history_output = routeReadHistoryOutput,
            .history_stats = routeHistoryStats,
            .request_pane_focus = routeRequestPaneFocus,
            .complete_pane_focus = routeCompletePaneFocus,
        };

        const ClientRequestRouter = GenericRouter(ClientRequestContext, client_request_handlers);

        fn routeOpenPane(request: *ClientRequestContext, open: OpenPaneViewType) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var handler: OpenPaneHandlerType = .{
                .workspaces = &request.workspaces,
                .panes = .{
                    .context = &client_context,
                    .find = findOpenPane,
                    .first = findFirstOpenPane,
                    .launch = launchOpenPane,
                    .prepare_view = prepareOpenPaneView,
                    .attach = attachOpenPane,
                },
                .authority = .{
                    .context = &client_context,
                    .prepare = prepareOpenPaneLaunch,
                },
                .geometry = .{
                    .context = &client_context,
                    .acquire = acquireCreatedWorkspaceGeometry,
                    .release = releaseCreatedWorkspaceGeometry,
                },
                .events = .{
                    .context = &client_context,
                    .publish = publishOpenPaneEvent,
                },
            };
            var controller = OpenPaneController.init(&session.delivery.responses, handler.executor());

            try controller.openPane(open);
        }

        fn routePaneInput(request: *ClientRequestContext, input: PaneInputType) !void {
            const application = request.application;
            var handler: PaneInputHandlerType = .{
                .io = application.io,
                .attachments = &request.session.attachments,
                .metrics = &application.metrics,
                .agent_input = if (application.agent_description_options != null) &application.model.agents else null,
                .scheduler = paneInputScheduler(application),
            };
            var controller = request_dispatch.PaneInputController.init(&application.metrics, &handler);

            if (try controller.paneInput(input) == .handled) {
                notePaneInput(application, request.session, input.pane_id);
            }
        }

        fn routeRequestPaneFocus(request: *ClientRequestContext, focus: RequestPaneFocusType) !void {
            var controller = paneFocusController(request.application);
            try controller.requestFocus(request.session, focus);
        }

        fn routeCompletePaneFocus(request: *ClientRequestContext, completion: CompletePaneFocusType) !void {
            var controller = paneFocusController(request.application);
            try controller.completeFocus(request.session, completion);
        }

        fn notePaneInput(application: *Application, session: *Session, pane_id: PaneIdType) void {
            var controller = paneFocusController(application);
            controller.notePaneInput(session, pane_id);
        }

        fn paneFocusController(application: *Application) PaneFocusController {
            return .{
                .panes = &application.model.panes,
                .clients = application.clients,
                .metrics = &application.metrics,
                .input_sequence = &application.input_sequence,
                .delivery = .{ .context = application, .pump = pumpFocusClient },
            };
        }

        fn pumpFocusClient(context: *anyopaque, session: *Session) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            try application.pump(session);
        }

        fn routePaneResize(request: *ClientRequestContext, resize: PaneResizeType) !void {
            const application = request.application;
            const session = request.session;
            var resize_context: ClientAttachmentContext = .{ .application = application, .session = session };
            var handler: PaneResizeHandlerType = .{
                .attachments = &session.attachments,
                .geometry = .{
                    .context = &resize_context,
                    .holds = clientHoldsWorkspaceGeometry,
                    .release = releaseClientWorkspaceGeometry,
                },
                .scheduler = paneResizeScheduler(application),
            };
            var controller = request_dispatch.PaneResizeController.init(&application.metrics, &handler);

            try controller.paneResize(resize);
        }

        fn routeFrameAck(request: *ClientRequestContext, ack: FrameAckType) !void {
            const application = request.application;
            var handler: FrameAckHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.FrameAckController.init(application.io, &application.metrics, &handler);

            try controller.frameAck(ack);
        }

        fn routeRequestSnapshot(request: *ClientRequestContext, snapshot: RequestSnapshotType) !void {
            var handler: RequestCellSnapshotHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.RequestSnapshotController.init(&request.application.metrics, &handler);

            try controller.requestSnapshot(snapshot);
        }

        fn routeDetachPane(request: *ClientRequestContext, detach: DetachPaneType) !void {
            const application = request.application;
            const session = request.session;
            var detach_context: ClientAttachmentContext = .{ .application = application, .session = session };
            var handler: DetachPaneHandlerType = .{
                .attachments = .{
                    .context = &detach_context,
                    .detach = detachClientAttachment,
                    .leave_workspace = leaveClientWorkspace,
                },
                .geometry = .{
                    .context = &detach_context,
                    .release = releaseClientWorkspaceGeometry,
                },
            };
            var controller = DetachPaneController.init(handler.executor(), .{
                .context = &application.metrics,
                .record = recordStaleClientMessage,
            });

            try controller.detachPane(detach);
        }

        fn routeRuntimeStop(request: *ClientRequestContext) !void {
            var handler: RuntimeStopHandlerType = .{
                .shutdown = &request.application.shutdown,
                .notifications = runtimeStopNotifications(request.application),
            };
            var controller = RuntimeStopController.init(handler.executor());

            controller.runtimeStop(request.session.key);
        }

        fn routeRequestTabSnapshot(request: *ClientRequestContext, snapshot: RequestTabSnapshotType) !void {
            var source_context: TabSnapshotSourceContext = .{
                .panes = &request.application.model.panes,
                .workspaces = &request.workspaces,
            };
            var handler: TabSnapshotHandler = .{
                .source = .{
                    .context = &source_context,
                    .contains_tab = tabSnapshotContainsTab,
                    .running_panes = tabSnapshotRunningPanes,
                },
            };
            var controller = TabSnapshotController.init(&request.session.delivery.responses, handler.executor());

            try controller.requestTabSnapshot(snapshot);
        }

        fn routeCreatePane(request: *ClientRequestContext, create: CreatePaneViewType) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: CreatePaneHandlerType = .{
                .workspaces = request.workspaces.reader(),
                .panes = .{
                    .context = &application.model.panes,
                    .has_running = createPaneHasRunning,
                },
                .authority = .{
                    .context = &client_context,
                    .prepare = prepareCreatePaneLaunch,
                },
                .launcher = .{
                    .context = application,
                    .launch = launchCreatedPane,
                },
                .attachment = .{
                    .context = &client_context,
                    .attach = attachCreatedPane,
                },
                .events = .{
                    .context = &event_context,
                    .publish = publishPaneLaunched,
                },
            };
            var controller = CreatePaneController.init(&session.delivery.responses, handler.executor());

            try controller.createPane(create);
        }

        fn routeClosePane(request: *ClientRequestContext, close: ClosePaneType) !void {
            var handler: ClosePaneHandlerType = .{
                .panes = .{
                    .context = &request.session.attachments,
                    .request_close = requestAttachedPaneClose,
                },
            };
            var controller = ClosePaneController.init(&request.session.delivery.responses, handler.executor());

            try controller.closePane(close);
        }

        fn routeQueryHistory(request: *ClientRequestContext, query: QueryHistoryType) !void {
            const application = request.application;
            const session = request.session;
            var service_context: HistoryQueryServiceContext = .{
                .io = application.io,
                .service = application.history_service,
            };
            var handler: HistoryHandler = .{
                .service = .{
                    .context = &service_context,
                    .submit_fn = submitHistoryQuery,
                },
            };
            var controller = HistoryQueryController.init(
                &session.delivery.responses,
                &application.metrics,
                handler.executor(),
            );

            try controller.queryHistory(.{
                .client = session.key,
                .close_after_reply = session.role == .control,
            }, query);
        }

        /// Builds the engine prompt from the pane's cwd and visible screen
        /// and queues it; the reply reaches this client through
        /// `AgentEvents.handleEngineResponse`. Every failure answers with a
        /// `command_suggestion` status instead of a request failure, so the
        /// palette never consumes a continuation.
        fn routeSuggestCommand(request: *ClientRequestContext, command: SuggestCommandType) !void {
            const application = request.application;
            const session = request.session;
            const service = application.engine_service orelse {
                return queueSuggestionStatus(&session.delivery.responses, command.request_id, .unavailable);
            };
            const pane = application.model.panes.resolveControl(.{ .id = command.pane_id, .generation = 0 }) orelse {
                return queueSuggestionStatus(&session.delivery.responses, command.request_id, .failed);
            };

            var screen_storage: [max_pane_text_bytes_module]u8 = undefined;
            const dump = pane.dumpText(.{ .rows = suggestion.context_rows, .source = .screen }, &screen_storage);
            var prompt_buffer: [types.max_prompt_bytes]u8 = undefined;
            const prompt = suggestion.buildPrompt(.{
                .cwd = pane.cwd.slice(),
                .screen = screen_storage[0..dump.len],
                .request = command.text,
            }, &prompt_buffer);
            const purpose: types.Purpose = .{ .suggestion = .{
                .client_id = session.key.id,
                .client_generation = session.key.generation,
                .request_id = raw_module(command.request_id),
            } };
            const queued = PromptType.init(purpose, prompt) catch null;
            if (queued == null or !service.submit(application.io, .{ .prompt = queued.? })) {
                return queueSuggestionStatus(&session.delivery.responses, command.request_id, .failed);
            }
        }

        fn queueSuggestionStatus(responses: *ResponseQueueType, request_id: RequestIdType, status: SuggestionStatusType) !void {
            try responses.push(.{ .command_suggestion = .{ .request_id = request_id, .status = status } });
        }

        fn routeDeleteHistory(request: *ClientRequestContext, delete: DeleteHistoryType) !void {
            var controller = PruneHistoryController.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.deleteHistory(.{
                .io = request.application.io,
                .origin = .{
                    .client = request.session.key,
                    .close_after_reply = request.session.role == .control,
                },
                .request = delete,
            });
        }

        fn routePruneHistory(request: *ClientRequestContext, prune: PruneHistoryType) !void {
            var controller = PruneHistoryController.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.pruneHistory(.{
                .io = request.application.io,
                .origin = .{
                    .client = request.session.key,
                    .close_after_reply = request.session.role == .control,
                },
                .request = prune,
            });
        }

        fn routeReadHistoryOutput(request: *ClientRequestContext, read: ReadHistoryOutputType) !void {
            var controller = HistoryOutputController.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.readHistoryOutput(.{
                .io = request.application.io,
                .origin = .{
                    .client = request.session.key,
                    .close_after_reply = request.session.role == .control,
                },
                .request = read,
            });
        }

        fn routeHistoryStats(request: *ClientRequestContext, query: HistoryStatsQueryType) !void {
            var controller = HistoryOutputController.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.historyStats(.{
                .io = request.application.io,
                .origin = .{
                    .client = request.session.key,
                    .close_after_reply = request.session.role == .control,
                },
                .request = query,
            });
        }

        fn routeImportHistory(request: *ClientRequestContext, batch: ImportHistoryViewType) !void {
            var controller = ImportHistoryController.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.importHistory(request.application.io, batch);
        }

        fn routeRequestWorkspaceSnapshot(request: *ClientRequestContext, snapshot: RequestWorkspaceSnapshotType) !void {
            var handler: WorkspaceSnapshotHandler = .{
                .workspaces = request.workspaces.reader(),
            };
            var controller = WorkspaceSnapshotController.init(&request.session.delivery.responses, handler.executor());

            try controller.requestWorkspaceSnapshot(snapshot);
        }

        fn routeCreateTab(request: *ClientRequestContext, create: CreateTabViewType) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: CreateTabHandlerType = .{
                .workspaces = &request.workspaces,
                .authority = .{
                    .context = &client_context,
                    .prepare = prepareCreateTabLaunch,
                },
                .launcher = .{
                    .context = application,
                    .launch = launchCreatedTabPane,
                },
                .attachment = .{
                    .context = &client_context,
                    .attach = attachCreatedTab,
                },
                .events = .{
                    .context = &event_context,
                    .publish = publishTabCreated,
                },
            };
            var controller = CreateTabController.init(&session.delivery.responses, handler.executor());

            try controller.createTab(create);
        }

        fn routeRenameTab(request: *ClientRequestContext, rename: RenameTabType) !void {
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: RenameTabHandlerType = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishTabRenamed,
                },
            };
            var controller = RenameTabController.init(&request.session.delivery.responses, handler.executor());

            try controller.renameTab(rename);
        }

        fn routeCloseTab(request: *ClientRequestContext, close: CloseTabType) !void {
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: CloseTabHandlerType = .{
                .workspaces = &request.workspaces,
                .panes = .{
                    .context = &application.model.panes,
                    .close_all = closeTabPanes,
                },
                .events = .{
                    .context = &event_context,
                    .publish = publishTabRemoved,
                },
            };
            var controller = CloseTabController.init(&request.session.delivery.responses, handler.executor());

            try controller.closeTab(close);
        }

        fn routeMoveTab(request: *ClientRequestContext, move: MoveTabType) !void {
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: MoveTabHandlerType = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishTabMoved,
                },
            };
            var controller = MoveTabController.init(&request.session.delivery.responses, handler.executor());

            try controller.moveTab(move);
        }

        fn routeRequestGraphicsSnapshot(request: *ClientRequestContext, snapshot: RequestGraphicsSnapshotType) !void {
            var handler: RequestGraphicsSnapshotHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.RequestGraphicsSnapshotController.init(&request.application.metrics, &handler);

            try controller.requestGraphicsSnapshot(snapshot);
        }

        fn routeGraphicsCredit(request: *ClientRequestContext, credit: GraphicsCreditType) !void {
            var handler: ReturnGraphicsCreditHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.GraphicsCreditController.init(&request.application.metrics, &handler);

            try controller.graphicsCredit(credit);
        }

        fn routeConfigureGraphics(request: *ClientRequestContext, configure: ConfigureGraphicsType) !void {
            var handler: ConfigureGraphicsHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.GraphicsConfigurationController.init(&handler);

            try controller.configureGraphics(configure);
        }

        fn routeConfigureTerminalColors(request: *ClientRequestContext, colors: TerminalColors) !void {
            var handler: GenericHandler(Application) = .{
                .application = request.application,
                .session = request.session,
            };
            var controller: GenericTerminalColorsController(@TypeOf(&handler)) = .{ .executor = &handler };
            controller.configureTerminalColors(colors);
        }

        fn routeRequestRuntimeState(request: *ClientRequestContext, runtime_state: RequestRuntimeStateType) !void {
            var controller = request_dispatch.RuntimeStateController.init(&request.session.delivery);

            try controller.requestRuntimeState(runtime_state.client_identity);
        }

        fn routeUpdateClientLayout(request: *ClientRequestContext, update: ClientLayoutUpdateViewType) !void {
            const identity = request.session.delivery.client_identity;
            if (identity == .invalid) {
                return error.ClientLayoutNotSubscribed;
            }

            try request.application.model.client_layouts.replace(.{
                .identity = identity,
                .layout = update,
                .sources = .{
                    .panes = &request.application.model.panes,
                    .workspaces = request.workspaces.reader(),
                },
            });
            request.application.noteSessionChange();
        }

        fn routeCreateWorkspace(request: *ClientRequestContext, create: CreateWorkspaceViewType) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: CreateWorkspaceHandlerType = .{
                .workspaces = &request.workspaces,
                .authority = .{
                    .context = &client_context,
                    .prepare = prepareCreateWorkspaceLaunch,
                },
                .geometry = .{
                    .context = &client_context,
                    .acquire = acquireCreatedWorkspaceGeometry,
                    .release = releaseCreatedWorkspaceGeometry,
                },
                .launcher = .{
                    .context = application,
                    .launch = launchCreatedWorkspacePane,
                },
                .attachment = .{
                    .context = &client_context,
                    .replace = replaceCreatedWorkspaceAttachments,
                },
                .events = .{
                    .context = &event_context,
                    .publish = publishWorkspaceCreated,
                },
            };
            var controller = CreateWorkspaceController.init(&session.delivery.responses, handler.executor());

            try controller.createWorkspace(create);
        }

        fn routeRenameWorkspace(request: *ClientRequestContext, rename: RenameWorkspaceType) !void {
            var event_context: WorkspaceEventContext = .{
                .application = request.application,
                .origin = request.session.key,
            };
            var handler: RenameWorkspaceHandlerType = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishWorkspaceRenamed,
                },
            };
            var controller = RenameWorkspaceController.init(&request.session.delivery.responses, handler.executor());

            try controller.renameWorkspace(rename);
        }

        fn routeSetPaneViewport(request: *ClientRequestContext, viewport: SetPaneViewportType) !void {
            var handler: SetPaneViewportHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.PaneViewportController.init(&request.application.metrics, &handler);

            try controller.setPaneViewport(viewport);
        }

        fn routeAcknowledgeAgent(request: *ClientRequestContext, acknowledgement: AcknowledgeAgentType) !void {
            var handler: AcknowledgeAgentHandlerType = .{
                .agents = &request.application.model.agents,
            };
            var controller = request_dispatch.AcknowledgeAgentController.init(&request.application.metrics, &handler);
            const now_ms = std.Io.Timestamp.now(request.application.io, .real).toMilliseconds();

            controller.acknowledgeAgent(acknowledgement, now_ms);
        }

        fn routeQueryAgents(request: *ClientRequestContext, query: QueryAgentsType) !void {
            var controller = request_dispatch.QueryAgentsController.init(&request.session.delivery);

            controller.queryAgents(query);
        }

        fn routeReadPane(request: *ClientRequestContext, read: ReadPaneType) !void {
            var controller = ReadPaneController.init(&request.session.delivery.responses);

            try controller.readPane(read);
        }

        fn routeSendPaneText(request: *ClientRequestContext, send: SendPaneTextType) !void {
            const application = request.application;
            var handler: SendPaneTextHandlerType = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .input = .{
                    .io = application.io,
                    .metrics = &application.metrics,
                    .agent_input = if (application.agent_description_options != null) &application.model.agents else null,
                    .scheduler = paneInputScheduler(application),
                },
            };
            var controller = request_dispatch.SendPaneTextController.init(&request.session.delivery.responses, &handler);

            try controller.sendPaneText(send);
        }

        fn routeReportAgentSession(request: *ClientRequestContext, report: ReportAgentSessionType) !void {
            const application = request.application;
            var handler: ReportAgentSessionHandlerType = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
            };
            var controller = request_dispatch.ReportAgentSessionController.init(&request.session.delivery.responses, &handler);
            const now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds();

            if (try controller.reportAgentSession(report, now_ms) == .recorded) {
                application.noteSessionChange();
            }
        }

        fn routeReportAgent(request: *ClientRequestContext, report: ReportAgentType) !void {
            const application = request.application;
            var handler: ReportAgentHandlerType = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
            };
            var controller = request_dispatch.ReportAgentController.init(&request.session.delivery.responses, &handler);
            const now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds();

            const result = try controller.reportAgent(report, .{
                .real_ms = now_ms,
                .awake_ns = @intCast(std.Io.Timestamp.now(application.io, .awake).toNanoseconds()),
            });
            if (result.session_recorded) {
                application.noteSessionChange();
            }
            if (result.outcome != .applied) {
                return;
            }

            const sound = sound_module.soundForTransition(result.previous, result.current) orelse return;
            application.publishAgentSound(.{
                .pane_id = report.pane_id,
                .pane_generation = report.pane_generation,
                .sound = sound,
            });
        }

        fn routeReportAgentCommand(request: *ClientRequestContext, report: ReportAgentCommandType) !void {
            const application = request.application;
            var handler: ReportAgentCommandHandlerType = .{
                .panes = &application.model.panes,
            };
            var controller = request_dispatch.ReportAgentCommandController.init(&request.session.delivery.responses, &handler);
            const now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds();

            try controller.reportAgentCommand(report, now_ms);
        }

        fn routeReportAgentTitle(request: *ClientRequestContext, report: ReportAgentTitleType) !void {
            const application = request.application;
            var handler: ReportAgentTitleHandlerType = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
            };
            var controller = request_dispatch.ReportAgentTitleController.init(&request.session.delivery.responses, &handler);

            if (try controller.reportAgentTitle(report) == .recorded) {
                application.noteSessionChange();
            }
        }

        fn routeSearchPane(request: *ClientRequestContext, search: SearchPaneType) !void {
            try pane_search.start(request.application, request.session, search);
        }

        fn routeCopySelection(request: *ClientRequestContext, selection: CopySelectionType) !void {
            var handler: CopySelectionHandlerType = .{
                .attachments = &request.session.attachments,
            };
            var controller = request_dispatch.CopySelectionController.init(&request.application.metrics, &handler, &request.session.delivery);

            controller.copySelection(selection);
        }

        fn routeShowNotification(request: *ClientRequestContext, notification: ShowNotificationType) !void {
            var handler: ShowNotificationHandlerType = .{
                .notifications = notificationPublisher(request.application),
            };
            var controller = ShowNotificationController.init(
                &request.session.delivery.responses,
                handler.executor(),
                notificationDelivery(request.application),
            );

            try controller.showNotification(notification);
        }

        fn paneInputScheduler(application: *Application) PaneInputScheduler {
            return .{
                .context = application,
                .observation = entrypointScheduleObservation,
                .input = entrypointScheduleInput,
            };
        }

        fn paneResizeScheduler(application: *Application) PaneResizeScheduler {
            return .{
                .context = application,
                .observation = entrypointScheduleObservation,
                .media = entrypointScheduleMedia,
                .response = entrypointScheduleResponse,
            };
        }

        fn entrypointScheduleObservation(context: *anyopaque, pane: *PaneType) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_observation(application, pane);
        }

        fn entrypointScheduleMedia(context: *anyopaque, pane: *PaneType) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_media(application, pane);
        }

        fn entrypointScheduleResponse(context: *anyopaque, pane: *PaneType) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_response(application, pane);
        }

        fn entrypointScheduleInput(context: *anyopaque, pane: *PaneType) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_input(application, pane);
        }

        const ClientLaunchContext = struct {
            application: *Application,
            session: *Session,
        };

        const ClientAttachmentContext = struct {
            application: *Application,
            session: *Session,
        };

        const WorkspaceEventContext = struct {
            application: *Application,
            origin: ClientKeyType,
        };

        const TabSnapshotSourceContext = struct {
            panes: *PaneStoreType,
            workspaces: *Repository,
        };

        const HistoryQueryServiceContext = struct {
            io: std.Io,
            service: *ServiceType,
        };

        fn submitHistoryQuery(context: *anyopaque, query: QueryType) bool {
            const service: *HistoryQueryServiceContext = @ptrCast(@alignCast(context));
            return service.service.query(service.io, query);
        }

        fn tabSnapshotContainsTab(context: *anyopaque, location: TabLocationType) bool {
            const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
            return source.workspaces.reader().contains(location);
        }

        fn tabSnapshotRunningPanes(context: *anyopaque, location: TabLocationType) u16 {
            const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
            return source.panes.countAt(location);
        }

        fn requestAttachedPaneClose(context: *anyopaque, pane_id: PaneIdType) ?bool {
            const attachments: *AttachmentStoreType = @ptrCast(@alignCast(context));
            const attachment = attachments.find(pane_id) orelse return null;
            return attachment.pane.requestClose();
        }

        fn createPaneHasRunning(context: *anyopaque, location: TabLocationType) bool {
            const panes: *PaneStoreType = @ptrCast(@alignCast(context));
            return panes.countAt(location) != 0;
        }

        fn detachClientAttachment(context: *anyopaque, pane_id: PaneIdType) ?PaneDetachedType {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.session.attachments.detach(pane_id);
        }

        fn leaveClientWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) bool {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.session.attachments.leaveWorkspace(workspace);
        }

        fn clientHoldsWorkspaceGeometry(context: *anyopaque, workspace: WorkspaceLocationType) bool {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.application.holdsGeometry(client.session.key, workspace);
        }

        fn releaseClientWorkspaceGeometry(context: *anyopaque, workspace: WorkspaceLocationType) void {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            client.application.releaseGeometryFor(client.session.key, workspace);
        }

        fn recordStaleClientMessage(context: *anyopaque) void {
            const metrics: *RuntimeMetricsType = @ptrCast(@alignCast(context));
            metrics.stale_client_messages += 1;
        }

        fn findOpenPane(context: *anyopaque, pane_id: PaneIdType) ?PaneLaunchedType {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.findRunning(pane_id) orelse return null;

            if (pane.close_requested or pane.exit != null) {
                return null;
            }

            return .{ .key = pane.key(), .location = pane.location };
        }

        fn findFirstOpenPane(context: *anyopaque, location: TabLocationType) ?PaneLaunchedType {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.firstAt(location) orelse return null;
            return .{ .key = pane.key(), .location = pane.location };
        }

        fn prepareOpenPaneLaunch(context: *anyopaque, request: OpenPanePrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return launch_cwd_module.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .any,
            ) catch error.InvalidLaunchCwd;
        }

        fn launchOpenPane(context: *anyopaque, request: OpenPaneLaunchPane) !PaneLaunchedType {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = try client.application.launchPane(.{
                .location = request.location,
                .size = request.size,
                .launch = request.launch,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
            });

            return .{ .key = pane.key(), .location = pane.location };
        }

        fn prepareOpenPaneView(context: *anyopaque, request: PrepareViewType) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.resolve(request.pane.key) orelse return error.PaneUnavailable;
            const resize_result = if (pane.ingest_pending)
                pane.requestResize(request.size)
            else
                pane.resize(request.size);
            resize_result catch return error.PaneResizeFailed;

            try runtime_port.schedule_observation(client.application, pane);
            try runtime_port.schedule_media(client.application, pane);
        }

        fn attachOpenPane(context: *anyopaque, launched: PaneLaunchedType) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.resolve(launched.key) orelse return error.PaneUnavailable;
            const attachment = try client.session.attachments.attach(client.application.gpa, pane);
            _ = try attachment.resizeIfNeeded();
        }

        fn publishOpenPaneEvent(context: *anyopaque, event: open_pane_commands.RuntimeEvent) void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const workspace = switch (event) {
                .workspace_created => |created| created.location.workspace,
                .pane_launched => |launched| launched.location.workspace,
            };
            client.application.notifyWorkspaceChanged(client.session.key, workspace);
        }

        fn prepareCreateTabLaunch(context: *anyopaque, request: CreateTabPrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

            if (!client.application.holdsGeometry(client.session.key, request.workspace)) {
                return error.GeometryUnavailable;
            }

            return launch_cwd_module.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .{ .workspace = request.workspace },
            ) catch error.InvalidLaunchCwd;
        }

        fn attachCreatedTab(context: *anyopaque, launched: CreateTabLaunchedPane) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;

            _ = try client.session.attachments.attach(client.application.gpa, pane);
        }

        fn launchCreatedTabPane(context: *anyopaque, request: CreateTabLaunchPane) !CreateTabLaunchedPane {
            const application: *Application = @ptrCast(@alignCast(context));
            const pane = try application.launchPane(.{
                .location = request.location,
                .size = request.size,
                .launch = request.launch,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
            });

            return .{ .id = pane.id };
        }

        fn prepareCreateWorkspaceLaunch(context: *anyopaque, request: CreateWorkspacePrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return launch_cwd_module.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .any,
            ) catch error.InvalidLaunchCwd;
        }

        fn acquireCreatedWorkspaceGeometry(context: *anyopaque, workspace: WorkspaceLocationType) bool {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return client.application.holdsGeometry(client.session.key, workspace);
        }

        fn releaseCreatedWorkspaceGeometry(context: *anyopaque, workspace: WorkspaceLocationType) void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            client.application.releaseGeometryFor(client.session.key, workspace);
        }

        fn launchCreatedWorkspacePane(context: *anyopaque, request: CreateWorkspaceLaunchPane) !CreateWorkspaceLaunchedPane {
            const application: *Application = @ptrCast(@alignCast(context));
            const pane = try application.launchPane(.{
                .location = request.location,
                .size = request.size,
                .launch = request.launch,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
            });

            return .{ .id = pane.id };
        }

        fn replaceCreatedWorkspaceAttachments(context: *anyopaque, launched: CreateWorkspaceLaunchedPane) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;
            const previous_workspace = client.session.attachments.currentWorkspace();

            client.session.attachments.clearAttachments();
            if (previous_workspace) |previous| {
                client.application.releaseGeometryFor(client.session.key, previous);
            }

            const attachment = try client.session.attachments.attach(client.application.gpa, pane);
            _ = try attachment.resizeIfNeeded();
        }

        fn prepareCreatePaneLaunch(context: *anyopaque, request: CreatePanePrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

            if (!client.application.holdsGeometry(client.session.key, request.location.workspace)) {
                return error.GeometryUnavailable;
            }

            return launch_cwd_module.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .{ .tab = request.location },
            ) catch error.InvalidLaunchCwd;
        }

        fn launchCreatedPane(context: *anyopaque, request: CreatePaneLaunchPane) !PaneLaunchedType {
            const application: *Application = @ptrCast(@alignCast(context));
            const pane = try application.launchPane(.{
                .location = request.location,
                .size = request.size,
                .launch = request.launch,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
            });

            return .{ .key = pane.key(), .location = pane.location };
        }

        fn attachCreatedPane(context: *anyopaque, launched: PaneLaunchedType) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.resolve(launched.key) orelse return error.LaunchedPaneUnavailable;
            _ = try client.session.attachments.attach(client.application.gpa, pane);
        }

        fn publishTabCreated(context: *anyopaque, event: TabCreatedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishTabRenamed(context: *anyopaque, event: TabRenamedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();

            publication.application.model.agents.touch();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishTabMoved(context: *anyopaque, event: TabMovedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishWorkspaceRenamed(context: *anyopaque, event: WorkspaceRenamedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();

            publication.application.model.agents.touch();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location);
        }

        fn publishWorkspaceCreated(context: *anyopaque, event: WorkspaceCreatedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishPaneLaunched(context: *anyopaque, event: PaneLaunchedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn closeTabPanes(context: *anyopaque, location: TabLocationType) void {
            const panes: *PaneStoreType = @ptrCast(@alignCast(context));
            panes.closeAt(location);
        }

        fn publishTabRemoved(context: *anyopaque, event: TabRemovedType) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.noteSessionChange();

            if (event.workspace_removed) {
                publication.application.notifyWorkspaceClosed(.{
                    .origin = publication.origin,
                    .workspace = event.location.workspace,
                    .previous_workspace = event.previous_workspace,
                });
            } else {
                publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
            }
        }

        fn runtimeStopNotifications(application: *Application) NotificationsType {
            return .{ .context = application, .publish_fn = publishRuntimeStop };
        }

        fn publishRuntimeStop(context: *anyopaque, event: StopRequestedType) void {
            const application: *Application = @ptrCast(@alignCast(context));
            std.debug.assert(application.shutdown.isRequested());
            std.debug.assert(std.meta.eql(application.shutdown.initiator.?, event.initiator));

            for (&application.clients.items) |*slot| {
                const session = slot.* orelse continue;

                if (session.active()) {
                    session.delivery.requestStop();
                }
            }
        }

        fn notificationPublisher(application: *Application) NotificationPublisherType {
            return .{ .context = application, .publish_fn = publishRequestedNotification };
        }

        fn publishRequestedNotification(context: *anyopaque, notification: NotificationType) u8 {
            const application: *Application = @ptrCast(@alignCast(context));
            return application.publishNotification(notification);
        }

        fn notificationDelivery(application: *Application) DeliveryType {
            return .{ .context = application, .pump_all_fn = pumpNotificationClients };
        }

        fn pumpNotificationClients(context: *anyopaque) void {
            const application: *Application = @ptrCast(@alignCast(context));
            application.pumpAll();
        }

        /// Applies one decoded client message inside a request-scoped context.
        ///
        /// ```zig
        /// try RequestDispatcher.dispatch(&application, session, message);
        /// ```
        pub fn dispatch(application: *Application, session: *Session, message: ClientMessageType) !void {
            var context = ClientRequestContext.init(application, session);
            const router = ClientRequestRouter.init(&context);

            return router.route(message);
        }
    };
}
