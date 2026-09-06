//! Interactive client launch grammar, including the command delimiter.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;

pub const RunOptions = struct {
    command: pty.Command,
    command_set: bool = false,
    theme: frontend.theme.Theme = frontend.theme.default_theme,
    theme_set: bool = false,
    sidebar_rendering: frontend.kitty.SidebarRendering = .automatic,
    sidebar_renderer_set: bool = false,
    config: ?[*:0]const u8 = null,
    no_config: bool = false,
    profile: ?[*:0]const u8 = null,
    /// SSH destination whose runtime this client attaches to.
    remote: ?[*:0]const u8 = null,
    /// Start a runtime that sets the previous session aside instead of
    /// restoring it. Refused when a runtime is already running.
    fresh: bool = false,
    /// Example: `const options = try RunOptions.parse(args, environ);`.
    pub fn parse(args: []const [*:0]const u8, environ: std.process.Environ) !RunOptions {
        var options: RunOptions = .{ .command = undefined };
        var theme_set = false;
        var sidebar_renderer_set = false;
        var delimiter_seen = false;
        var command_start: usize = 0;
        while (command_start < args.len) {
            const arg = std.mem.span(args[command_start]);
            if (std.mem.eql(u8, arg, "--")) {
                delimiter_seen = true;
                command_start += 1;
                break;
            }
            if (std.mem.eql(u8, arg, "--theme")) {
                if (theme_set) {
                    return error.DuplicateThemeOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingThemeName;
                }

                options.theme = frontend.theme.fromName(std.mem.span(args[command_start + 1])) orelse
                    return error.UnknownTheme;
                theme_set = true;
                options.theme_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--theme=")) {
                if (theme_set) {
                    return error.DuplicateThemeOption;
                }

                options.theme = frontend.theme.fromName(arg["--theme=".len..]) orelse
                    return error.UnknownTheme;
                theme_set = true;
                options.theme_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--sidebar-renderer")) {
                if (sidebar_renderer_set) {
                    return error.DuplicateSidebarRendererOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingSidebarRenderer;
                }

                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    std.mem.span(args[command_start + 1]),
                );
                sidebar_renderer_set = true;
                options.sidebar_renderer_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--sidebar-renderer=")) {
                if (sidebar_renderer_set) {
                    return error.DuplicateSidebarRendererOption;
                }

                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    arg["--sidebar-renderer=".len..],
                );
                sidebar_renderer_set = true;
                options.sidebar_renderer_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--remote")) {
                if (options.remote != null) {
                    return error.DuplicateRemoteOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingRemoteDestination;
                }

                options.remote = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--remote=")) {
                if (options.remote != null) {
                    return error.DuplicateRemoteOption;
                }
                if (arg["--remote=".len..].len == 0) {
                    return error.MissingRemoteDestination;
                }

                options.remote = args[command_start] + "--remote=".len;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingConfigPath;
                }

                options.config = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--config=")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }
                if (arg["--config=".len..].len == 0) {
                    return error.MissingConfigPath;
                }

                options.config = args[command_start] + "--config=".len;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }

                options.no_config = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--fresh")) {
                if (options.fresh) {
                    return error.DuplicateFreshOption;
                }

                options.fresh = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--profile")) {
                if (options.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingProfileName;
                }

                options.profile = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--profile=")) {
                if (options.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (arg["--profile=".len..].len == 0) {
                    return error.MissingProfileName;
                }

                options.profile = args[command_start] + "--profile=".len;
                command_start += 1;
                continue;
            }
            break;
        }
        if (command_start == args.len) {
            if (delimiter_seen) {
                return error.MissingCommand;
            }

            options.command = try defaultShell(environ);
        } else {
            options.command = try pty.Command.fromArgv(args[command_start..]);
            options.command_set = true;
        }

        if (options.no_config and options.profile != null) {
            return error.ProfileWithoutConfig;
        }
        if (options.fresh and options.remote != null) {
            return error.FreshWithRemote;
        }

        return options;
    }
};

fn defaultShell(environ: std.process.Environ) !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return pty.Command.fromArgv(&.{fallback});
    if (configured.len == 0) {
        return pty.Command.fromArgv(&.{fallback});
    }

    return pty.Command.fromArgv(&.{configured.ptr});
}
