//! Runtime boundary for owned ProxyTLS capture halves.

const std = @import("std");
const pane_mod = @import("../../../pane/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const proxy_resource = @import("../../resources/proxy.zig");

const Io = std.Io;

pub const Resources = struct {
    panes: *pane_mod.PaneStore,
    proxy_runtime: *proxy_resource.Runtime,
};

/// Defines scheduling and clock operations supplied by runtime composition.
///
/// ```zig
/// const port: RuntimePort(Application) = .{ .rearm_receive = rearm, .now_ms = now };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
    };
}

/// Binds capture delivery policy to one concrete runtime application.
///
/// ```zig
/// const CaptureAdapter = Adapter(Application, port);
/// ```
pub fn Adapter(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Creates an adapter that borrows runtime-owned pane and proxy stores.
        ///
        /// ```zig
        /// const adapter = CaptureAdapter.init(application, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms receive, rejects stale ownership, decodes, and joins one half.
        ///
        /// ```zig
        /// try adapter.handle(result);
        /// ```
        pub fn handle(adapter: *Self, result: anyerror!*proxy_mod.CaptureHalf) !void {
            const half = result catch return;
            errdefer half.deinit();
            try port.rearm_receive(adapter.context);

            const key: pane_mod.PaneKey = .{ .id = half.pane.id, .generation = half.pane.generation };
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

test {
    std.testing.refAllDecls(@This());
}
