//! `telar proxy --help` and the help of its commands.

const std = @import("std");
const localca = @import("localca");
const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Install or remove the proxy's short-lived system CA, and watch the proxy's status",
    .usage = "telar proxy trust install|uninstall|status [--ca-dir PATH] [--linux BACKEND]\n       telar proxy watch [--count N] [--jsonl] [--socket PATH]",
    .text =
    \\The optional CONNECT proxy relays pane applications' traffic and can intercept TLS
    \\for configured hosts. Capture is separately enabled; exchange-listener plugins can
    \\process captured requests and responses. It does not determine agent status or
    \\create a persistent request archive by itself. Interception is visible while active;
    \\trusting its CA on the system is a separate, explicit, reversible step.
    \\
    ,
    .commands = &.{
        .{
            .name = "trust",
            .summary = "Install, remove or inspect the system trust of telar's proxy CA",
            .usage = "telar proxy trust install|uninstall|status [--ca-dir PATH] [--linux update-ca-certificates|trust]",
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  --ca-dir PATH    The CA directory (default $XDG_DATA_HOME/telar/proxy, else
                \\                   ~/.local/share/telar/proxy), owner-only.
                \\  --linux BACKEND  Required by `install` on Linux: `update-ca-certificates` or
                \\                   `trust`; refused on macOS.
                \\
                \\Effects: `install` creates a system CA valid {d} days, separate from the proxy's
                \\own, prints and runs the platform's trust command (`security add-trusted-cert` on
                \\macOS, `sudo install` and `update-ca-certificates`, or `sudo trust anchor`, on
                \\Linux) and records the fingerprint. `uninstall` runs the reverse and deletes the
                \\record. `status` reads the record. Never contacts the runtime, which rotates the
                \\CA within a day of its expiry. Firefox keeps its own store.
                \\
                \\Results: `telar proxy trust: installed FINGERPRINT`, `already installed`, `removed
                \\FINGERPRINT`, `not installed`, or `absent|installed|stale (DIR)` with the
                \\fingerprint and store. Exit 0; 1 when stale, when a record is invalid or a
                \\command failed.
                \\
            , .{@divExact(localca.ca.system_ca_seconds, 24 * 60 * 60)}),
            .examples = &.{ &.{ "proxy", "trust", "status" }, &.{ "proxy", "trust", "install", "--ca-dir", "/home/dev/.local/share/telar/proxy", "--linux", "trust" } },
        },
        .{
            .name = "watch",
            .summary = "Stream the proxy's status events as JSON lines",
            .usage = "telar proxy watch [--count N] [--jsonl] [--socket PATH]",
            .text =
            \\Effects: `telar runtime watch` filtered to `proxy_status`, `runtime_stopping` and
            \\`resync_required`; observes status, not captured traffic. The proxy configuration
            \\is fixed at runtime start, so after the initial status the stream may stay idle.
            \\Never starts a runtime.
            \\
            \\Results: one JSON object per line. Exit 0 after --count events or when the runtime
            \\stops; 1 after a resync notice.
            \\
            ,
            .examples = &.{&.{ "proxy", "watch", "--count", "1", "--jsonl" }},
        },
    },
};
