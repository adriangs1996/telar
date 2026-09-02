//! Decodes and dispatches one client request through application capabilities.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const client_runtime = @import("../client/root.zig");
const launch_cwd = client_runtime.launch_cwd;
const client_request_router = client_runtime.request_router;
const client_session = client_runtime.session;
const delivery_mod = @import("../delivery/root.zig");
const acknowledge_agent_commands = @import("commands/acknowledge_agent.zig");
const acknowledge_agent_controller = @import("../entrypoints/requests/acknowledge_agent.zig");
const query_agents_controller = @import("../entrypoints/requests/query_agents.zig");
const read_pane_controller = @import("../entrypoints/requests/read_pane.zig");
const import_history_controller = @import("../entrypoints/requests/import_history.zig");
const send_pane_text_commands = @import("commands/send_pane_text.zig");
const send_pane_text_controller = @import("../entrypoints/requests/send_pane_text.zig");
const report_agent_session_commands = @import("commands/report_agent_session.zig");
const report_agent_session_controller = @import("../entrypoints/requests/report_agent_session.zig");
const search_pane_commands = @import("commands/search_pane.zig");
const search_pane_controller = @import("../entrypoints/requests/search_pane.zig");
const report_agent_commands = @import("commands/report_agent.zig");
const report_agent_controller = @import("../entrypoints/requests/report_agent.zig");
const pane_observation_events = @import("../entrypoints/events/pane/observation.zig");
const close_tab_commands = @import("commands/close_tab.zig");
const close_tab_controller = @import("../entrypoints/requests/close_tab.zig");
const close_pane_commands = @import("commands/close_pane.zig");
const close_pane_controller = @import("../entrypoints/requests/close_pane.zig");
const copy_selection_commands = @import("commands/copy_selection.zig");
const copy_selection_controller = @import("../entrypoints/requests/copy_selection.zig");
const create_tab_commands = @import("commands/create_tab.zig");
const create_tab_controller = @import("../entrypoints/requests/create_tab.zig");
const create_pane_commands = @import("commands/create_pane.zig");
const create_pane_controller = @import("../entrypoints/requests/create_pane.zig");
const create_workspace_commands = @import("commands/create_workspace.zig");
const create_workspace_controller = @import("../entrypoints/requests/create_workspace.zig");
const detach_pane_commands = @import("commands/detach_pane.zig");
const detach_pane_controller = @import("../entrypoints/requests/detach_pane.zig");
const frame_ack_commands = @import("commands/frame_ack.zig");
const frame_ack_controller = @import("../entrypoints/requests/frame_ack.zig");
const graphics_configuration_commands = @import("commands/graphics_configuration.zig");
const graphics_configuration_controller = @import("../entrypoints/requests/graphics_configuration.zig");
const graphics_credit_commands = @import("commands/graphics_credit.zig");
const graphics_credit_controller = @import("../entrypoints/requests/graphics_credit.zig");
const history_query = @import("queries/history.zig");
const history_query_controller = @import("../entrypoints/requests/history_query.zig");
const move_tab_commands = @import("commands/move_tab.zig");
const move_tab_controller = @import("../entrypoints/requests/move_tab.zig");
const open_pane_commands = @import("commands/open_pane.zig");
const open_pane_controller = @import("../entrypoints/requests/open_pane.zig");
const pane_input_commands = @import("commands/pane_input.zig");
const pane_input_controller = @import("../entrypoints/requests/pane_input.zig");
const pane_resize_commands = @import("commands/pane_resize.zig");
const pane_resize_controller = @import("../entrypoints/requests/pane_resize.zig");
const pane_viewport_commands = @import("commands/pane_viewport.zig");
const pane_viewport_controller = @import("../entrypoints/requests/pane_viewport.zig");
const request_graphics_snapshot_commands = @import("commands/request_graphics_snapshot.zig");
const request_graphics_snapshot_controller = @import("../entrypoints/requests/request_graphics_snapshot.zig");
const request_snapshot_commands = @import("commands/request_snapshot.zig");
const request_snapshot_controller = @import("../entrypoints/requests/request_snapshot.zig");
const runtime_stop_commands = @import("commands/runtime_stop.zig");
const runtime_stop_controller = @import("../entrypoints/requests/runtime_stop.zig");
const runtime_state_controller = @import("../entrypoints/requests/runtime_state.zig");
const rename_workspace_commands = @import("commands/rename_workspace.zig");
const rename_workspace_controller = @import("../entrypoints/requests/rename_workspace.zig");
const show_notification_commands = @import("commands/show_notification.zig");
const show_notification_controller = @import("../entrypoints/requests/show_notification.zig");
const tab_snapshot_query = @import("queries/tab_snapshot.zig");
const tab_snapshot_controller = @import("../entrypoints/requests/tab_snapshot.zig");
const workspace_snapshot_query = @import("queries/workspace_snapshot.zig");
const workspace_snapshot_controller = @import("../entrypoints/requests/workspace_snapshot.zig");
const rename_tab_commands = @import("commands/rename_tab.zig");
const rename_tab_controller = @import("../entrypoints/requests/rename_tab.zig");
const pane_mod = @import("../../pane/root.zig");
const lifecycle = @import("../lifecycle/root.zig");
const shutdown_mod = lifecycle.shutdown_authority;
const observability = @import("../observability/root.zig");
const telemetry_mod = observability.telemetry;
const workspace_mod = @import("../../workspace/root.zig");

const Io = std.Io;
const schema = core.schema;

const Pane = pane_mod.Pane;
const PaneStore = pane_mod.PaneStore;
const WorkspaceRepository = workspace_mod.Repository;
const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const AcknowledgeAgentController = acknowledge_agent_controller.Controller(*acknowledge_agent_commands.AcknowledgeAgentHandler);
const QueryAgentsController = query_agents_controller.Controller(*Delivery);
const SendPaneTextController = send_pane_text_controller.Controller(*send_pane_text_commands.SendPaneTextHandler);
const ReportAgentSessionController = report_agent_session_controller.Controller(*report_agent_session_commands.ReportAgentSessionHandler);
const ReportAgentController = report_agent_controller.Controller(*report_agent_commands.ReportAgentHandler);
const SearchPaneController = search_pane_controller.Controller(*search_pane_commands.SearchPaneHandler);
const CopySelectionController = copy_selection_controller.Controller(*copy_selection_commands.CopySelectionHandler, *Delivery);
const FrameAckController = frame_ack_controller.Controller(*frame_ack_commands.FrameAckHandler);
const GraphicsConfigurationController = graphics_configuration_controller.Controller(*graphics_configuration_commands.ConfigureGraphicsHandler);
const GraphicsCreditController = graphics_credit_controller.Controller(*graphics_credit_commands.ReturnGraphicsCreditHandler);
const PaneInputController = pane_input_controller.Controller(*pane_input_commands.PaneInputHandler);
const PaneResizeController = pane_resize_controller.Controller(*pane_resize_commands.PaneResizeHandler);
const PaneViewportController = pane_viewport_controller.Controller(*pane_viewport_commands.SetPaneViewportHandler);
const RequestGraphicsSnapshotController = request_graphics_snapshot_controller.Controller(*request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler);
const RequestSnapshotController = request_snapshot_controller.Controller(*request_snapshot_commands.RequestCellSnapshotHandler);
const RuntimeStateController = runtime_state_controller.Controller(*Delivery);

const ClientSession = client_session.Session;
const ClientKey = client_session.Key;

/// Declares the pane schedulers that request handlers may invoke after a
/// successful command.
///
/// ```zig
/// const Port = RuntimePort(Application);
/// ```
pub fn RuntimePort(comptime Application: type) type {
    return struct {
        schedule_observation: *const fn (*Application, *Pane) anyerror!void,
        schedule_media: *const fn (*Application, *Pane) anyerror!void,
        schedule_response: *const fn (*Application, *Pane) anyerror!void,
        schedule_input: *const fn (*Application, *Pane) anyerror!void,
    };
}

/// Builds the request dispatcher for one application type and its pane actor
/// scheduling port.
///
/// ```zig
/// const RequestDispatcher = Dispatcher(Application, runtime_port);
/// ```
pub fn Dispatcher(comptime Application: type, comptime runtime_port: RuntimePort(Application)) type {
    return struct {
        const Self = @This();

        const ClientRequestContext = struct {
            application: *Application,
            session: *ClientSession,
            workspaces: WorkspaceRepository,

            fn init(application: *Application, session: *ClientSession) ClientRequestContext {
                return .{
                    .application = application,
                    .session = session,
                    .workspaces = application.workspaceRepository(),
                };
            }
        };

        const client_request_handlers: client_request_router.Handlers(ClientRequestContext) = .{
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
            .request_workspace_snapshot = routeRequestWorkspaceSnapshot,
            .create_tab = routeCreateTab,
            .rename_tab = routeRenameTab,
            .close_tab = routeCloseTab,
            .move_tab = routeMoveTab,
            .request_graphics_snapshot = routeRequestGraphicsSnapshot,
            .graphics_credit = routeGraphicsCredit,
            .configure_graphics = routeConfigureGraphics,
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
            .search_pane = routeSearchPane,
            .import_history = routeImportHistory,
        };

        const ClientRequestRouter = client_request_router.Router(ClientRequestContext, client_request_handlers);

        fn routeOpenPane(request: *ClientRequestContext, open: schema.OpenPaneView) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var handler: open_pane_commands.OpenPaneHandler = .{
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
            var controller = open_pane_controller.Controller.init(&session.delivery.responses, handler.executor());

            try controller.openPane(open);
        }

        fn routePaneInput(request: *ClientRequestContext, input: schema.PaneInput) !void {
            const application = request.application;
            var handler: pane_input_commands.PaneInputHandler = .{
                .io = application.io,
                .attachments = &request.session.attachments,
                .metrics = &application.metrics,
                .agent_input = if (application.agent_description_options != null) &application.model.agents else null,
                .scheduler = paneInputScheduler(application),
            };
            var controller = PaneInputController.init(&application.metrics, &handler);

            try controller.paneInput(input);
        }

        fn routePaneResize(request: *ClientRequestContext, resize: schema.PaneResize) !void {
            const application = request.application;
            const session = request.session;
            var resize_context: ClientAttachmentContext = .{ .application = application, .session = session };
            var handler: pane_resize_commands.PaneResizeHandler = .{
                .attachments = &session.attachments,
                .geometry = .{
                    .context = &resize_context,
                    .holds = clientHoldsWorkspaceGeometry,
                    .release = releaseClientWorkspaceGeometry,
                },
                .scheduler = paneResizeScheduler(application),
            };
            var controller = PaneResizeController.init(&application.metrics, &handler);

            try controller.paneResize(resize);
        }

        fn routeFrameAck(request: *ClientRequestContext, ack: schema.FrameAck) !void {
            const application = request.application;
            var handler: frame_ack_commands.FrameAckHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = FrameAckController.init(application.io, &application.metrics, &handler);

            try controller.frameAck(ack);
        }

        fn routeRequestSnapshot(request: *ClientRequestContext, snapshot: schema.RequestSnapshot) !void {
            var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = RequestSnapshotController.init(&request.application.metrics, &handler);

            try controller.requestSnapshot(snapshot);
        }

        fn routeDetachPane(request: *ClientRequestContext, detach: schema.DetachPane) !void {
            const application = request.application;
            const session = request.session;
            var detach_context: ClientAttachmentContext = .{ .application = application, .session = session };
            var handler: detach_pane_commands.DetachPaneHandler = .{
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
            var controller = detach_pane_controller.Controller.init(handler.executor(), .{
                .context = &application.metrics,
                .record = recordStaleClientMessage,
            });

            try controller.detachPane(detach);
        }

        fn routeRuntimeStop(request: *ClientRequestContext) !void {
            var handler: runtime_stop_commands.RuntimeStopHandler = .{
                .shutdown = &request.application.shutdown,
                .notifications = runtimeStopNotifications(request.application),
            };
            var controller = runtime_stop_controller.Controller.init(handler.executor());

            controller.runtimeStop(request.session.key);
        }

        fn routeRequestTabSnapshot(request: *ClientRequestContext, snapshot: schema.RequestTabSnapshot) !void {
            var source_context: TabSnapshotSourceContext = .{
                .panes = &request.application.model.panes,
                .workspaces = &request.workspaces,
            };
            var handler: tab_snapshot_query.Handler = .{
                .source = .{
                    .context = &source_context,
                    .contains_tab = tabSnapshotContainsTab,
                    .running_panes = tabSnapshotRunningPanes,
                },
            };
            var controller = tab_snapshot_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.requestTabSnapshot(snapshot);
        }

        fn routeCreatePane(request: *ClientRequestContext, create: schema.CreatePaneView) !void {
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: create_pane_commands.CreatePaneHandler = .{
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
            var controller = create_pane_controller.Controller.init(&session.delivery.responses, handler.executor());

            try controller.createPane(create);
        }

        fn routeClosePane(request: *ClientRequestContext, close: schema.ClosePane) !void {
            request.application.noteSessionChange();
            var handler: close_pane_commands.ClosePaneHandler = .{
                .panes = .{
                    .context = &request.session.attachments,
                    .request_close = requestAttachedPaneClose,
                },
            };
            var controller = close_pane_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.closePane(close);
        }

        fn routeQueryHistory(request: *ClientRequestContext, query: schema.QueryHistory) !void {
            const application = request.application;
            const session = request.session;
            var service_context: HistoryQueryServiceContext = .{
                .io = application.io,
                .service = application.history_service,
            };
            var handler: history_query.Handler = .{
                .service = .{
                    .context = &service_context,
                    .submit_fn = submitHistoryQuery,
                },
            };
            var controller = history_query_controller.Controller.init(
                &session.delivery.responses,
                &application.metrics,
                handler.executor(),
            );

            try controller.queryHistory(.{
                .client = session.key,
                .close_after_reply = session.role == .control,
            }, query);
        }

        fn routeImportHistory(request: *ClientRequestContext, batch: schema.ImportHistoryView) !void {
            var controller = import_history_controller.Controller.init(
                &request.session.delivery.responses,
                request.application.history_service,
            );

            try controller.importHistory(request.application.io, batch);
        }

        fn routeRequestWorkspaceSnapshot(request: *ClientRequestContext, snapshot: schema.RequestWorkspaceSnapshot) !void {
            var handler: workspace_snapshot_query.Handler = .{
                .workspaces = request.workspaces.reader(),
            };
            var controller = workspace_snapshot_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.requestWorkspaceSnapshot(snapshot);
        }

        fn routeCreateTab(request: *ClientRequestContext, create: schema.CreateTabView) !void {
            request.application.noteSessionChange();
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: create_tab_commands.CreateTabHandler = .{
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
            var controller = create_tab_controller.Controller.init(&session.delivery.responses, handler.executor());

            try controller.createTab(create);
        }

        fn routeRenameTab(request: *ClientRequestContext, rename: schema.RenameTab) !void {
            request.application.noteSessionChange();
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: rename_tab_commands.RenameTabHandler = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishTabRenamed,
                },
            };
            var controller = rename_tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.renameTab(rename);
        }

        fn routeCloseTab(request: *ClientRequestContext, close: schema.CloseTab) !void {
            request.application.noteSessionChange();
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: close_tab_commands.CloseTabHandler = .{
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
            var controller = close_tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.closeTab(close);
        }

        fn routeMoveTab(request: *ClientRequestContext, move: schema.MoveTab) !void {
            request.application.noteSessionChange();
            const application = request.application;
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = request.session.key };
            var handler: move_tab_commands.MoveTabHandler = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishTabMoved,
                },
            };
            var controller = move_tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.moveTab(move);
        }

        fn routeRequestGraphicsSnapshot(request: *ClientRequestContext, snapshot: schema.RequestGraphicsSnapshot) !void {
            var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = RequestGraphicsSnapshotController.init(&request.application.metrics, &handler);

            try controller.requestGraphicsSnapshot(snapshot);
        }

        fn routeGraphicsCredit(request: *ClientRequestContext, credit: schema.GraphicsCredit) !void {
            var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = GraphicsCreditController.init(&request.application.metrics, &handler);

            try controller.graphicsCredit(credit);
        }

        fn routeConfigureGraphics(request: *ClientRequestContext, configure: schema.ConfigureGraphics) !void {
            var handler: graphics_configuration_commands.ConfigureGraphicsHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = GraphicsConfigurationController.init(&handler);

            try controller.configureGraphics(configure);
        }

        fn routeRequestRuntimeState(request: *ClientRequestContext, runtime_state: schema.RequestRuntimeState) !void {
            var controller = RuntimeStateController.init(&request.session.delivery);

            try controller.requestRuntimeState(runtime_state.client_identity);
        }

        fn routeUpdateClientLayout(request: *ClientRequestContext, update: schema.ClientLayoutUpdateView) !void {
            request.application.noteSessionChange();
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
        }

        fn routeCreateWorkspace(request: *ClientRequestContext, create: schema.CreateWorkspaceView) !void {
            request.application.noteSessionChange();
            const application = request.application;
            const session = request.session;
            var client_context: ClientLaunchContext = .{ .application = application, .session = session };
            var event_context: WorkspaceEventContext = .{ .application = application, .origin = session.key };
            var handler: create_workspace_commands.CreateWorkspaceHandler = .{
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
            var controller = create_workspace_controller.Controller.init(&session.delivery.responses, handler.executor());

            try controller.createWorkspace(create);
        }

        fn routeRenameWorkspace(request: *ClientRequestContext, rename: schema.RenameWorkspace) !void {
            request.application.noteSessionChange();
            var event_context: WorkspaceEventContext = .{
                .application = request.application,
                .origin = request.session.key,
            };
            var handler: rename_workspace_commands.RenameWorkspaceHandler = .{
                .workspaces = &request.workspaces,
                .events = .{
                    .context = &event_context,
                    .publish = publishWorkspaceRenamed,
                },
            };
            var controller = rename_workspace_controller.Controller.init(&request.session.delivery.responses, handler.executor());

            try controller.renameWorkspace(rename);
        }

        fn routeSetPaneViewport(request: *ClientRequestContext, viewport: schema.SetPaneViewport) !void {
            var handler: pane_viewport_commands.SetPaneViewportHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = PaneViewportController.init(&request.application.metrics, &handler);

            try controller.setPaneViewport(viewport);
        }

        fn routeAcknowledgeAgent(request: *ClientRequestContext, acknowledgement: schema.AcknowledgeAgent) !void {
            var handler: acknowledge_agent_commands.AcknowledgeAgentHandler = .{
                .agents = &request.application.model.agents,
            };
            var controller = AcknowledgeAgentController.init(&request.application.metrics, &handler);
            const now_ms = Io.Timestamp.now(request.application.io, .real).toMilliseconds();

            controller.acknowledgeAgent(acknowledgement, now_ms);
        }

        fn routeQueryAgents(request: *ClientRequestContext, query: schema.QueryAgents) !void {
            var controller = QueryAgentsController.init(&request.session.delivery);

            controller.queryAgents(query);
        }

        fn routeReadPane(request: *ClientRequestContext, read: schema.ReadPane) !void {
            var controller = read_pane_controller.Controller.init(&request.session.delivery.responses);

            try controller.readPane(read);
        }

        fn routeSendPaneText(request: *ClientRequestContext, send: schema.SendPaneText) !void {
            const application = request.application;
            var handler: send_pane_text_commands.SendPaneTextHandler = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .input = .{
                    .io = application.io,
                    .metrics = &application.metrics,
                    .agent_input = if (application.agent_description_options != null) &application.model.agents else null,
                    .scheduler = paneInputScheduler(application),
                },
            };
            var controller = SendPaneTextController.init(&request.session.delivery.responses, &handler);

            try controller.sendPaneText(send);
        }

        fn routeReportAgentSession(request: *ClientRequestContext, report: schema.ReportAgentSession) !void {
            const application = request.application;
            var handler: report_agent_session_commands.ReportAgentSessionHandler = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
            };
            var controller = ReportAgentSessionController.init(&request.session.delivery.responses, &handler);
            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();

            if (try controller.reportAgentSession(report, now_ms) == .recorded) {
                application.noteSessionChange();
            }
        }

        fn routeReportAgent(request: *ClientRequestContext, report: schema.ReportAgent) !void {
            const application = request.application;
            var handler: report_agent_commands.ReportAgentHandler = .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
            };
            var controller = ReportAgentController.init(&request.session.delivery.responses, &handler);
            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();

            const result = try controller.reportAgent(report, now_ms);
            if (result.session_recorded) {
                application.noteSessionChange();
            }
            if (result.outcome != .applied) {
                return;
            }

            const sound = pane_observation_events.soundForTransition(result.previous, result.current) orelse return;
            application.publishAgentSound(.{
                .pane_id = report.pane_id,
                .pane_generation = report.pane_generation,
                .sound = sound,
            });
        }

        fn routeSearchPane(request: *ClientRequestContext, search: schema.SearchPane) !void {
            var handler: search_pane_commands.SearchPaneHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = SearchPaneController.init(&request.session.delivery.responses, &handler);

            try controller.searchPane(search);
        }

        fn routeCopySelection(request: *ClientRequestContext, selection: schema.CopySelection) !void {
            var handler: copy_selection_commands.CopySelectionHandler = .{
                .attachments = &request.session.attachments,
            };
            var controller = CopySelectionController.init(&request.application.metrics, &handler, &request.session.delivery);

            controller.copySelection(selection);
        }

        fn routeShowNotification(request: *ClientRequestContext, notification: schema.ShowNotification) !void {
            var handler: show_notification_commands.ShowNotificationHandler = .{
                .notifications = notificationPublisher(request.application),
            };
            var controller = show_notification_controller.Controller.init(
                &request.session.delivery.responses,
                handler.executor(),
                notificationDelivery(request.application),
            );

            try controller.showNotification(notification);
        }

        fn paneInputScheduler(application: *Application) pane_input_commands.Scheduler {
            return .{
                .context = application,
                .observation = entrypointScheduleObservation,
                .input = entrypointScheduleInput,
            };
        }

        fn paneResizeScheduler(application: *Application) pane_resize_commands.Scheduler {
            return .{
                .context = application,
                .observation = entrypointScheduleObservation,
                .media = entrypointScheduleMedia,
                .response = entrypointScheduleResponse,
            };
        }

        fn entrypointScheduleObservation(context: *anyopaque, pane: *Pane) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_observation(application, pane);
        }

        fn entrypointScheduleMedia(context: *anyopaque, pane: *Pane) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_media(application, pane);
        }

        fn entrypointScheduleResponse(context: *anyopaque, pane: *Pane) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_response(application, pane);
        }

        fn entrypointScheduleInput(context: *anyopaque, pane: *Pane) !void {
            const application: *Application = @ptrCast(@alignCast(context));
            return runtime_port.schedule_input(application, pane);
        }

        const ClientLaunchContext = struct {
            application: *Application,
            session: *ClientSession,
        };

        const ClientAttachmentContext = struct {
            application: *Application,
            session: *ClientSession,
        };

        const WorkspaceEventContext = struct {
            application: *Application,
            origin: ClientKey,
        };

        const TabSnapshotSourceContext = struct {
            panes: *PaneStore,
            workspaces: *WorkspaceRepository,
        };

        const HistoryQueryServiceContext = struct {
            io: Io,
            service: *history.Service,
        };

        fn submitHistoryQuery(context: *anyopaque, query: history.Query) bool {
            const service: *HistoryQueryServiceContext = @ptrCast(@alignCast(context));
            return service.service.query(service.io, query);
        }

        fn tabSnapshotContainsTab(context: *anyopaque, location: schema.TabLocation) bool {
            const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
            return source.workspaces.reader().contains(location);
        }

        fn tabSnapshotRunningPanes(context: *anyopaque, location: schema.TabLocation) u16 {
            const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
            return source.panes.countAt(location);
        }

        fn requestAttachedPaneClose(context: *anyopaque, pane_id: schema.PaneId) ?bool {
            const attachments: *AttachmentStore = @ptrCast(@alignCast(context));
            const attachment = attachments.find(pane_id) orelse return null;
            return attachment.pane.requestClose();
        }

        fn createPaneHasRunning(context: *anyopaque, location: schema.TabLocation) bool {
            const panes: *PaneStore = @ptrCast(@alignCast(context));
            return panes.countAt(location) != 0;
        }

        fn detachClientAttachment(context: *anyopaque, pane_id: schema.PaneId) ?attachment_mod.PaneDetached {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.session.attachments.detach(pane_id);
        }

        fn leaveClientWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.session.attachments.leaveWorkspace(workspace);
        }

        fn clientHoldsWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            return client.application.holdsGeometry(client.session.key, workspace);
        }

        fn releaseClientWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
            const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
            client.application.releaseGeometryFor(client.session.key, workspace);
        }

        fn recordStaleClientMessage(context: *anyopaque) void {
            const metrics: *RuntimeMetrics = @ptrCast(@alignCast(context));
            metrics.stale_client_messages += 1;
        }

        fn findOpenPane(context: *anyopaque, pane_id: schema.PaneId) ?pane_mod.PaneLaunched {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.findRunning(pane_id) orelse return null;

            if (pane.close_requested or pane.exit != null) {
                return null;
            }

            return .{ .key = pane.key(), .location = pane.location };
        }

        fn findFirstOpenPane(context: *anyopaque, location: schema.TabLocation) ?pane_mod.PaneLaunched {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.firstAt(location) orelse return null;
            return .{ .key = pane.key(), .location = pane.location };
        }

        fn prepareOpenPaneLaunch(context: *anyopaque, request: open_pane_commands.PrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return launch_cwd.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .any,
            ) catch error.InvalidLaunchCwd;
        }

        fn launchOpenPane(context: *anyopaque, request: open_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
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

        fn prepareOpenPaneView(context: *anyopaque, request: open_pane_commands.PrepareView) !void {
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

        fn attachOpenPane(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
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

        fn prepareCreateTabLaunch(context: *anyopaque, request: create_tab_commands.PrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

            if (!client.application.holdsGeometry(client.session.key, request.workspace)) {
                return error.GeometryUnavailable;
            }

            return launch_cwd.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .{ .workspace = request.workspace },
            ) catch error.InvalidLaunchCwd;
        }

        fn attachCreatedTab(context: *anyopaque, launched: create_tab_commands.LaunchedPane) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;

            _ = try client.session.attachments.attach(client.application.gpa, pane);
        }

        fn launchCreatedTabPane(context: *anyopaque, request: create_tab_commands.LaunchPane) !create_tab_commands.LaunchedPane {
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

        fn prepareCreateWorkspaceLaunch(context: *anyopaque, request: create_workspace_commands.PrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return launch_cwd.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .any,
            ) catch error.InvalidLaunchCwd;
        }

        fn acquireCreatedWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            return client.application.holdsGeometry(client.session.key, workspace);
        }

        fn releaseCreatedWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            client.application.releaseGeometryFor(client.session.key, workspace);
        }

        fn launchCreatedWorkspacePane(context: *anyopaque, request: create_workspace_commands.LaunchPane) !create_workspace_commands.LaunchedPane {
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

        fn replaceCreatedWorkspaceAttachments(context: *anyopaque, launched: create_workspace_commands.LaunchedPane) !void {
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

        fn prepareCreatePaneLaunch(context: *anyopaque, request: create_pane_commands.PrepareLaunch) ![]const u8 {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

            if (!client.application.holdsGeometry(client.session.key, request.location.workspace)) {
                return error.GeometryUnavailable;
            }

            return launch_cwd.resolveLaunchCwd(
                &client.session.attachments,
                request.launch,
                .{ .tab = request.location },
            ) catch error.InvalidLaunchCwd;
        }

        fn launchCreatedPane(context: *anyopaque, request: create_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
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

        fn attachCreatedPane(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
            const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
            const pane = client.application.model.panes.resolve(launched.key) orelse return error.LaunchedPaneUnavailable;
            _ = try client.session.attachments.attach(client.application.gpa, pane);
        }

        fn publishTabCreated(context: *anyopaque, event: workspace_mod.TabCreated) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishTabRenamed(context: *anyopaque, event: workspace_mod.TabRenamed) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

            publication.application.model.agents.touch();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishTabMoved(context: *anyopaque, event: workspace_mod.TabMoved) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishWorkspaceRenamed(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

            publication.application.model.agents.touch();
            publication.application.notifyWorkspaceChanged(publication.origin, event.location);
        }

        fn publishWorkspaceCreated(context: *anyopaque, event: workspace_mod.WorkspaceCreated) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn publishPaneLaunched(context: *anyopaque, event: pane_mod.PaneLaunched) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
            publication.application.notifyWorkspaceChanged(publication.origin, event.location.workspace);
        }

        fn closeTabPanes(context: *anyopaque, location: schema.TabLocation) void {
            const panes: *PaneStore = @ptrCast(@alignCast(context));
            panes.closeAt(location);
        }

        fn publishTabRemoved(context: *anyopaque, event: workspace_mod.TabRemoved) void {
            const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

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

        fn runtimeStopNotifications(application: *Application) runtime_stop_commands.Notifications {
            return .{ .context = application, .publish_fn = publishRuntimeStop };
        }

        fn publishRuntimeStop(context: *anyopaque, event: shutdown_mod.StopRequested) void {
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

        fn notificationPublisher(application: *Application) show_notification_commands.NotificationPublisher {
            return .{ .context = application, .publish_fn = publishRequestedNotification };
        }

        fn publishRequestedNotification(context: *anyopaque, notification: schema.Notification) u8 {
            const application: *Application = @ptrCast(@alignCast(context));
            return application.publishNotification(notification);
        }

        fn notificationDelivery(application: *Application) show_notification_controller.Delivery {
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
        pub fn dispatch(application: *Application, session: *ClientSession, message: schema.ClientMessage) !void {
            var context = ClientRequestContext.init(application, session);
            const router = ClientRequestRouter.init(&context);

            return router.route(message);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
