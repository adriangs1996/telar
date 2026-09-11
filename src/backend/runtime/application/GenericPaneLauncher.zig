const std = @import("std");
const ServiceType = @import("../../history/Service.zig");
const TableType = @import("telar-core").Table;
const ProxyType = @import("../../proxy/Proxy.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const LaunchTestFault = @import("LaunchTestFault.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;
const LaunchRequest = @import("LaunchRequest.zig");
const PaneType = @import("../../pane/Pane.zig");
const PaneOverrides = @import("PaneOverrides.zig");
const PaneEnvironmentType = @import("../../proxy/PaneEnvironment.zig");
const ChildEnvironmentType = @import("../../pty/ChildEnvironment.zig");
const OwnedCommand = @import("OwnedCommand.zig");
const pane_launcher = @import("pane_launcher.zig");
const model = @import("../../history/model.zig");
const LaunchFailure = @import("LaunchFailure.zig");

pub fn Type(comptime RuntimeEvent: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        gpa: std.mem.Allocator,
        select: *std.Io.Select(RuntimeEvent),
        history_service: *ServiceType,
        inherited_environment: std.process.Environ,
        socket_path: []const u8,
        executable_path: []const u8,
        manifests: *const TableType,
        proxy: ?*ProxyType,
        panes: *PaneStoreType,
        launch_fault: ?*LaunchTestFault,
        terminal_colors: TerminalColorsType = .{},

        /// Executes one pane-launch transaction and returns only after both
        /// runtime observation actors own their work.
        ///
        /// ```zig
        /// const pane = try launcher.launch(.{ .location = location, .size = size, .launch = view, .launch_cwd = cwd, .workspace_path = path });
        /// ```
        pub fn launch(launcher: *Self, request: LaunchRequest) !*PaneType {
            const pane_key = try launcher.panes.allocateKey();
            var pane_overrides: PaneOverrides = .{};
            const identity_overrides = pane_overrides.build(.{
                .key = pane_key,
                .location = request.location,
                .socket_path = launcher.socket_path,
                .executable_path = launcher.executable_path,
            });
            var proxy_environment: ?PaneEnvironmentType = null;
            defer if (proxy_environment) |*owned| owned.deinit();
            var owned_environment: ?ChildEnvironmentType = null;
            defer if (owned_environment) |*owned| owned.deinit();
            var proxy_registered = false;
            errdefer if (proxy_registered) if (launcher.proxy) |proxy|
                proxy.revokePane(pane_key);
            const child_environment = if (launcher.proxy) |proxy| block: {
                proxy_environment = try proxy.registerPane(
                    pane_key,
                    .{
                        .inherited = launcher.inherited_environment,
                        .overrides = identity_overrides,
                    },
                );
                proxy_registered = true;
                break :block proxy_environment.?.environment();
            } else block: {
                owned_environment = try ChildEnvironmentType.initWithOverrides(
                    launcher.gpa,
                    launcher.inherited_environment,
                    .{ .telar_term_program = "telar", .overrides = identity_overrides },
                );
                break :block &owned_environment.?;
            };

            var command = try OwnedCommand.init(.{
                .gpa = launcher.gpa,
                .launch = request.launch,
                .cwd_path = request.launch_cwd,
                .environment = child_environment,
            });
            defer command.deinit();
            const shell = std.mem.span(command.command.file);
            const fresh = try PaneType.create(.{
                .io = launcher.io,
                .gpa = launcher.gpa,
                .history_service = launcher.history_service,
                .graphics_budget = &launcher.panes.graphics_budget,
                .manifests = launcher.manifests,
            }, .{
                .identity = pane_key,
                .location = request.location,
                .command = &command.command,
                .launch_cwd = request.launch_cwd,
                .workspace_path = request.workspace_path,
                .size = request.size,
                .graphics_limits = launcher.panes.graphics_limits,
                .terminal_colors = launcher.terminal_colors,
            });

            fresh.launch_record.capture(request.launch);
            launcher.panes.insert(fresh) catch |err| {
                launcher.recordFailure(fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
                fresh.abortLaunch();
                fresh.destroy();
                return err;
            };
            launcher.injectFault(.pane_registration) catch |err| {
                launcher.abort(fresh, .{ .shell = shell, .phase = .pane_registration, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            // The wait actor owns reaping if output actor scheduling fails.
            const wait_started = fresh.beginExitWait();
            std.debug.assert(wait_started);
            launcher.injectFault(.wait_actor) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };
            launcher.select.concurrent(.pane_exit, pane_launcher.waitPane, .{fresh}) catch |err| {
                fresh.cancelExitWait();
                launcher.abort(fresh, .{ .shell = shell, .phase = .wait_actor, .cause = err });
                launcher.panes.removeAndDestroy(fresh);
                return err;
            };

            const output_started = fresh.beginPtyOutputRead();
            std.debug.assert(output_started);
            launcher.injectFault(.output_actor) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
                return err;
            };
            launcher.select.concurrent(.pane_output, pane_launcher.readPane, .{ launcher.io, fresh }) catch |err| {
                fresh.cancelPtyOutputRead();
                fresh.finishPtyOutput();
                launcher.abort(fresh, .{ .shell = shell, .phase = .output_actor, .cause = err });
                return err;
            };

            fresh.commitLaunch(shell);
            proxy_registered = false;
            return fresh;
        }

        fn injectFault(launcher: *Self, phase: model.LaunchPhase) !void {
            if (launcher.launch_fault) |fault| {
                try fault.inject(phase);
            }
        }

        fn recordFailure(launcher: *Self, pane: *const PaneType, failure: LaunchFailure) void {
            _ = launcher.history_service.recordLaunchAttempt(launcher.io, .{
                .pane_id = pane.id,
                .pane_generation = pane.generation,
                .location = pane.location,
                .workspace_path = pane.workspace_path,
                .shell = failure.shell,
                .started_at_ms = pane.started_at_ms,
                .phase = failure.phase,
                .cause = @errorName(failure.cause),
            });
        }

        fn abort(launcher: *Self, pane: *PaneType, failure: LaunchFailure) void {
            launcher.recordFailure(pane, failure);
            pane.abortLaunch();
        }
    };
}
