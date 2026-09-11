const GenericProxyCaptureRuntimePort = @import("GenericProxyCaptureRuntimePort.zig").Type;
const ProxyCaptureResources = @import("ProxyCaptureResources.zig");
const Half = @import("../../../proxy/capture/Half.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");

/// Binds capture delivery policy to one concrete runtime application.
///
/// ```zig
/// const CaptureAdapter = Adapter(Application, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericProxyCaptureRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: ProxyCaptureResources,

        /// Creates an adapter that borrows runtime-owned pane and proxy stores.
        ///
        /// ```zig
        /// const adapter = CaptureAdapter.init(application, resources);
        /// ```
        pub fn init(context: *Context, resources: ProxyCaptureResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms receive, rejects stale ownership, decodes, and joins one half.
        ///
        /// ```zig
        /// try adapter.handle(result);
        /// ```
        pub fn handle(adapter: *Self, result: anyerror!*Half) !void {
            const half = result catch return;
            errdefer half.deinit();
            try port.rearm_receive(adapter.context);

            const key: PaneKeyType = .{ .id = half.pane.id, .generation = half.pane.generation };
            if (adapter.resources.panes.resolve(key) == null) {
                half.deinit();
                return;
            }

            adapter.resources.proxy_runtime.decodeCapture(half);
            adapter.resources.proxy_runtime.acceptCapture(.{
                .now_ms = port.now_ms(adapter.context),
                .half = half,
            });
        }
    };
}
