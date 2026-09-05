//! Proxy command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;
const values = @import("values.zig");
const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
const parseWaitStatus = values.parseWaitStatus;
const parseTimeoutSeconds = values.parseTimeoutSeconds;
const parseLineCount = values.parseLineCount;
const parseTextSource = values.parseTextSource;

pub const ProxyTrustAction = enum { install, uninstall, status };

pub const LinuxTrustBackend = enum { update_ca_certificates, trust };

pub const ProxyOptions = struct {
    action: ProxyTrustAction,
    ca_dir: ?[*:0]const u8 = null,
    linux_backend: ?LinuxTrustBackend = null,

    pub fn parse(args: []const [*:0]const u8) !ProxyOptions {
        if (args.len < 2 or !std.mem.eql(u8, std.mem.span(args[0]), "trust")) {
            return error.MissingProxyTrustAction;
        }

        const action_text = std.mem.span(args[1]);
        var options: ProxyOptions = .{ .action = if (std.mem.eql(u8, action_text, "install"))
            .install
        else if (std.mem.eql(u8, action_text, "uninstall"))
            .uninstall
        else if (std.mem.eql(u8, action_text, "status"))
            .status
        else
            return error.UnknownProxyTrustAction };
        var index: usize = 2;
        while (index < args.len) {
            const argument = std.mem.span(args[index]);
            if (std.mem.eql(u8, argument, "--ca-dir")) {
                if (options.ca_dir != null or index + 1 >= args.len) {
                    return error.InvalidProxyTrustDirectory;
                }

                options.ca_dir = args[index + 1];
                if (std.mem.span(options.ca_dir.?).len == 0) {
                    return error.InvalidProxyTrustDirectory;
                }
                index += 2;
            } else if (std.mem.eql(u8, argument, "--linux")) {
                if (options.linux_backend != null or index + 1 >= args.len) {
                    return error.InvalidLinuxTrustBackend;
                }

                const backend_name = std.mem.span(args[index + 1]);
                options.linux_backend = if (std.mem.eql(u8, backend_name, "update-ca-certificates"))
                    .update_ca_certificates
                else if (std.mem.eql(u8, backend_name, "trust"))
                    .trust
                else
                    return error.InvalidLinuxTrustBackend;
                index += 2;
            } else {
                return error.UnknownProxyTrustOption;
            }
        }

        return options;
    }
};
