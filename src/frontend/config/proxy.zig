//! Compiler for `config.runtime.proxy`.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, runtime: *config_model.RuntimeSnapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.proxy must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "enabled", "ca_dir", "intercept_hosts" },
        .path = "config.runtime.proxy",
    }, diagnostic);

    _ = lua.lua_getfield(state, absolute, "enabled");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
            value.pop(state, 1);
            diagnostic.set("config.runtime.proxy.enabled must be a boolean", .{});
            return error.InvalidConfig;
        }

        runtime.proxy_enabled = lua.lua_toboolean(state, -1) != 0;
    }
    value.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "ca_dir");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        const path = value.string(state, -1) orelse {
            value.pop(state, 1);
            diagnostic.set("config.runtime.proxy.ca_dir must be a string", .{});
            return error.InvalidConfig;
        };
        if (path.len == 0 or path.len > config_model.max_proxy_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
            value.pop(state, 1);
            diagnostic.set("config.runtime.proxy.ca_dir is invalid", .{});
            return error.InvalidConfig;
        }

        @memcpy(runtime.proxy_ca_dir_bytes[0..path.len], path);
        runtime.proxy_ca_dir_len = @intCast(path.len);
    }
    value.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "intercept_hosts");
    defer value.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.proxy.intercept_hosts must be an array", .{});
        return error.InvalidConfig;
    }

    const hosts = lua.lua_absindex(state, -1);
    const count = lua.lua_rawlen(state, hosts);
    if (count > config_model.max_proxy_intercept_hosts) {
        diagnostic.set(
            "config.runtime.proxy.intercept_hosts exceeds {d} entries",
            .{config_model.max_proxy_intercept_hosts},
        );
        return error.InvalidConfig;
    }

    try value.ensureArrayOnly(state, .{
        .index = hosts,
        .count = count,
        .path = "config.runtime.proxy.intercept_hosts",
    }, diagnostic);

    runtime.proxy_intercept_hosts = .{};
    for (0..count) |host_index| {
        _ = lua.lua_geti(state, hosts, @intCast(host_index + 1));
        defer value.pop(state, 1);
        const host = value.string(state, -1) orelse {
            diagnostic.set(
                "config.runtime.proxy.intercept_hosts[{d}] must be a hostname",
                .{host_index + 1},
            );
            return error.InvalidConfig;
        };
        if (!validHostname(host)) {
            diagnostic.set(
                "config.runtime.proxy.intercept_hosts[{d}] is not a valid hostname",
                .{host_index + 1},
            );
            return error.InvalidConfig;
        }

        runtime.proxy_intercept_hosts.append(host) catch {
            diagnostic.set(
                "config.runtime.proxy.intercept_hosts exceeds its {d}-byte budget",
                .{config_model.max_proxy_intercept_bytes},
            );
            return error.InvalidConfig;
        };
    }
    runtime.proxy_intercept_hosts.sortAndDeduplicate();
}

fn validHostname(host: []const u8) bool {
    if (host.len == 0 or host.len > config_model.max_proxy_intercept_host_bytes) {
        return false;
    }

    var label_len: usize = 0;
    for (host) |byte| switch (byte) {
        '.' => {
            if (label_len == 0 or label_len > 63) {
                return false;
            }

            label_len = 0;
        },
        '-' => {
            if (label_len == 0) {
                return false;
            }

            label_len += 1;
        },
        else => {
            if (!std.ascii.isAlphanumeric(byte)) {
                return false;
            }

            label_len += 1;
        },
    };

    if (label_len == 0 or label_len > 63 or host[host.len - 1] == '-') {
        return false;
    }

    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label[label.len - 1] == '-') {
            return false;
        }
    }

    return true;
}

test "host validation requires exact DNS labels" {
    try std.testing.expect(validHostname("api.anthropic.com"));
    try std.testing.expect(!validHostname(""));
    try std.testing.expect(!validHostname(".api.openai.com"));
    try std.testing.expect(!validHostname("api..openai.com"));
    try std.testing.expect(!validHostname("-api.openai.com"));
    try std.testing.expect(!validHostname("api-.openai.com"));
    try std.testing.expect(!validHostname("api_openai.com"));
    try std.testing.expect(!validHostname("api.openai.com/path"));
    try std.testing.expect(!validHostname("*.openai.com"));
    try std.testing.expect(!validHostname("openai.com:443"));
    try std.testing.expect(!validHostname("a" ** 64 ++ ".com"));
    try std.testing.expectEqual(core.proxy.max_hostname_bytes, config_model.max_proxy_intercept_host_bytes);
}
