const GenericHandlers = @import("GenericHandlers.zig").Type;
const source_namespace = @import("request_router.zig");
/// Creates an exhaustive router whose callbacks are resolved at compile time.
///
/// ```zig
/// const RequestRouter = Router(Context, handlers);
/// ```
pub fn Type(comptime Context: type, comptime handlers: GenericHandlers(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,

        /// Binds one request-scoped runtime context to the exhaustive router.
        ///
        /// ```zig
        /// const router = RequestRouter.init(&context);
        /// ```
        pub fn init(context: *Context) Self {
            return .{ .context = context };
        }

        /// Delegates exactly one decoded message without implementing its use
        /// case. Handler errors cross the router unchanged.
        ///
        /// ```zig
        /// try router.route(message);
        /// ```
        pub fn route(router: Self, message: source_namespace.schema.ClientMessage) !void {
            return switch (message) {
                .open_pane => |request| handlers.open_pane(router.context, request),
                .pane_input => |request| handlers.pane_input(router.context, request),
                .pane_resize => |request| handlers.pane_resize(router.context, request),
                .frame_ack => |request| handlers.frame_ack(router.context, request),
                .request_snapshot => |request| handlers.request_snapshot(router.context, request),
                .detach_pane => |request| handlers.detach_pane(router.context, request),
                .runtime_stop => handlers.runtime_stop(router.context),
                .request_tab_snapshot => |request| handlers.request_tab_snapshot(router.context, request),
                .create_pane => |request| handlers.create_pane(router.context, request),
                .close_pane => |request| handlers.close_pane(router.context, request),
                .query_history => |request| handlers.query_history(router.context, request),
                .suggest_command => |request| handlers.suggest_command(router.context, request),
                .request_workspace_snapshot => |request| handlers.request_workspace_snapshot(router.context, request),
                .create_tab => |request| handlers.create_tab(router.context, request),
                .rename_tab => |request| handlers.rename_tab(router.context, request),
                .close_tab => |request| handlers.close_tab(router.context, request),
                .move_tab => |request| handlers.move_tab(router.context, request),
                .request_graphics_snapshot => |request| handlers.request_graphics_snapshot(router.context, request),
                .graphics_credit => |request| handlers.graphics_credit(router.context, request),
                .configure_graphics => |request| handlers.configure_graphics(router.context, request),
                .configure_terminal_colors => |request| handlers.configure_terminal_colors(router.context, request),
                .request_runtime_state => |request| handlers.request_runtime_state(router.context, request),
                .create_workspace => |request| handlers.create_workspace(router.context, request),
                .rename_workspace => |request| handlers.rename_workspace(router.context, request),
                .set_pane_viewport => |request| handlers.set_pane_viewport(router.context, request),
                .copy_selection => |request| handlers.copy_selection(router.context, request),
                .show_notification => |request| handlers.show_notification(router.context, request),
                .update_client_layout => |request| handlers.update_client_layout(router.context, request),
                .acknowledge_agent => |request| handlers.acknowledge_agent(router.context, request),
                .query_agents => |request| handlers.query_agents(router.context, request),
                .read_pane => |request| handlers.read_pane(router.context, request),
                .send_pane_text => |request| handlers.send_pane_text(router.context, request),
                .report_agent_session => |request| handlers.report_agent_session(router.context, request),
                .report_agent => |request| handlers.report_agent(router.context, request),
                .report_agent_command => |request| handlers.report_agent_command(router.context, request),
                .report_agent_title => |request| handlers.report_agent_title(router.context, request),
                .search_pane => |request| handlers.search_pane(router.context, request),
                .import_history => |request| handlers.import_history(router.context, request),
                .delete_history => |request| handlers.delete_history(router.context, request),
                .prune_history => |request| handlers.prune_history(router.context, request),
                .read_history_output => |request| handlers.read_history_output(router.context, request),
                .history_stats => |request| handlers.history_stats(router.context, request),
                .request_pane_focus => |request| handlers.request_pane_focus(router.context, request),
                .complete_pane_focus => |request| handlers.complete_pane_focus(router.context, request),
            };
        }
    };
}
