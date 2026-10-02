//! `telar plugin --help` and the help of its commands.

const std = @import("std");
const core = @import("telar-core");
const FamilyHelp = @import("../FamilyHelp.zig");

/// Every capability a package may declare, by its name in `plugin.json`.
const capability_names = blk: {
    var names: []const u8 = "";
    for (@typeInfo(core.Capability).@"enum".fields, 0..) |field, index| {
        const value: core.Capability = @enumFromInt(field.value);
        names = names ++ (if (index == 0) "" else ", ") ++ value.canonicalName();
    }

    break :blk names;
};

const routed_text =
    \\Effects: forwarded to the window `--client ID` names. Needs a running runtime; never
    \\starts one. Exit 0; 1 when the window refused; 2 unknown client; 3 no answer in time.
;

pub const family: FamilyHelp = .{
    .summary = "Inspect, install and trust plugin packages; list, enable, disable and run them in a window",
    .usage = "telar plugin inspect|install|trust PATH [options] | telar plugin list|get|enable|disable|run ... --client ID",
    .text = std.fmt.comptimePrint(
        \\A plugin is a package (`plugin.json` beside its Lua) a window runs outside the
        \\runtime, in a worker with memory, time, output and process limits. Discovery,
        \\installation, trust and enablement are separate: `inspect` validates and names,
        \\`install` copies into the content-addressed store under $XDG_DATA_HOME/telar/plugins,
        \\`trust` grants capabilities to one exact digest, and the configuration enables it.
        \\Capabilities: {s}. The first three run offline; the rest act through a window.
        \\
    , .{capability_names}),
    .commands = &.{
        .{
            .name = "inspect",
            .summary = "Validate a package and print its immutable identity",
            .usage = "telar plugin inspect PATH",
            .text =
            \\Effects: loads and validates `PATH/plugin.json` and the package; runs no plugin
            \\code, contacts no runtime.
            \\
            \\Results: `id`, `version`, `source`, `revision`, `digest`, `actions` and
            \\`capabilities` lines. Exit 0; 1 with the diagnostic on stderr.
            \\
            ,
            .examples = &.{&.{ "plugin", "inspect", "./plugin" }},
        },
        .{
            .name = "install",
            .summary = "Copy a package into the local content-addressed store",
            .usage = "telar plugin install PATH",
            .text =
            \\Effects: validates the package and copies it to `plugins/<id>/<digest>` under
            \\$XDG_DATA_HOME/telar (else ~/.local/share/telar), owner-only. The same digest
            \\already there is left as is; a different package there is refused.
            \\
            \\Results: `telar plugin installed: DIR`. Exit 0 or 1.
            \\
            ,
            .examples = &.{&.{ "plugin", "install", "./plugin" }},
        },
        .{
            .name = "trust",
            .summary = "Grant declared capabilities to one exact package digest",
            .usage = "telar plugin trust PATH [--capability NAME]...",
            .text =
            \\Arguments:
            \\  --capability NAME  A capability the package declares; repeatable. Without any,
            \\                   every declared capability is granted.
            \\
            \\Effects: adds the digest and capabilities to trust.json under $XDG_CONFIG_HOME/telar
            \\(else ~/.config/telar). A plugin with filesystem, process or network access is
            \\full-trust code: grant what the user decided.
            \\
            \\Results: `telar plugin trust updated`. Exit 0; 1 for an undeclared or repeated
            \\capability or an insecure store.
            \\
            ,
            .examples = &.{&.{ "plugin", "trust", "./plugin", "--capability", "history.read" }},
        },
        .{
            .name = "list",
            .summary = "List a window's configured plugins, loaded or disabled",
            .usage = "telar plugin list --client ID [--json] [--socket PATH]",
            .routed = &.{.plugin_list},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\Results: always JSON, an array of `index`, `path`, `id`, `version`,
                \\`requested_enabled`, `enabled`, assembled under one configuration generation
                \\(a concurrent reload fails the listing instead of mixing generations).
                \\
            , .{routed_text}),
            .examples = &.{&.{ "plugin", "list", "--client", "1" }},
        },
        .{
            .name = "get",
            .summary = "Show one plugin's configuration, identity, capabilities and actions",
            .usage = "telar plugin get ID|PATH --client ID [--json] [--socket PATH]",
            .routed = &.{.plugin_get},
            .text = std.fmt.comptimePrint(
                \\Arguments:
                \\  ID|PATH          A loaded manifest id, or the configured path of a disabled one.
                \\
                \\{s}
                \\
                \\Results: always JSON: `path`, `requested_enabled`, `enabled`, `id`, `version`,
                \\`entry`, `source`, `revision`, `digest`, `capabilities`, `actions`. A disabled
                \\package reports configuration only; inspecting it loads no code.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "plugin", "get", "telar-history", "--client", "1" }},
        },
        .{
            .name = "enable",
            .summary = "Enable a configured plugin for this window's lifetime and reload",
            .usage = "telar plugin enable ID|PATH --client ID [--json] [--socket PATH]",
            .routed = &.{.plugin_enable},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\A window-lifetime override: no Lua source changes and no capability is granted.
                \\`admitted`: the reload runs its validation and trust checks; `plugin list` tells
                \\requested from adopted enablement.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "plugin", "enable", "./plugin", "--client", "1" }},
        },
        .{
            .name = "disable",
            .summary = "Disable a configured plugin for this window's lifetime and reload",
            .usage = "telar plugin disable ID|PATH --client ID [--json] [--socket PATH]",
            .routed = &.{.plugin_disable},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\The next configuration drops the plugin's bindings; enabling it again restores
                \\them from the unchanged source. `admitted`.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "plugin", "disable", "telar-history", "--client", "1", "--json" }},
        },
        .{
            .name = "run",
            .summary = "Run one action of a loaded plugin in its isolated worker",
            .usage = "telar plugin run ID|PATH ACTION --client ID [--json] [--socket PATH]",
            .routed = &.{.plugin_run},
            .text = std.fmt.comptimePrint(
                \\{s}
                \\
                \\`admitted` is not completion: the worker's result still passes the digest-bound
                \\capability checks and reaches the window's notifications. A busy or unavailable
                \\worker refuses.
                \\
            , .{routed_text}),
            .examples = &.{&.{ "plugin", "run", "telar-history", "refresh", "--client", "1" }},
        },
    },
};
