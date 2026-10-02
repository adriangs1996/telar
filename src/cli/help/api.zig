//! `telar api --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "Print the wire contract this binary speaks, for compatibility checks",
    .usage = "telar api schema [--json]",
    .commands = &.{
        .{
            .name = "schema",
            .summary = "Print the runtime protocol's version, fingerprint, message tags and bounds",
            .usage = "telar api schema [--json]",
            .text =
            \\Effects: none; offline. This describes the IPC between runtime and clients (request
            \\and message tags, agent statuses, bounds such as the most rows a read returns), not
            \\the command line: for that, `telar FAMILY COMMAND --help`. Two telar binaries talk
            \\only when their fingerprints match, which `telar machine check` compares.
            \\
            \\Results: text sections `client requests`, `server messages`, `agent statuses`,
            \\`bounds`; JSON `schema_version`, `fingerprint`, `client_requests`,
            \\`server_messages`, `agent_statuses`, `bounds`. Exit 0.
            \\
            ,
            .examples = &.{&.{ "api", "schema", "--json" }},
        },
    },
};
