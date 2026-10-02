//! What `telar FAMILY NAME --help` prints for one command: its usage line,
//! what it changes and what it answers. The examples are command lines the
//! parser must accept, so the help never drifts from the grammar.

const core = @import("telar-core");
const CommandHelp = @This();

/// The word after the family, as typed: `send-keys`, not `send_keys`.
name: []const u8,
/// One line for the family's listing.
summary: []const u8,
/// The complete syntax, starting with `telar FAMILY NAME`.
usage: []const u8,
/// Arguments, effects and results, as paragraphs.
text: []const u8,
/// The UI actions this command routes to an attached client, when it does.
routed: []const core.ClientAction = &.{},
/// Plumbing telar runs for itself: its help prints on request but the
/// family's listing leaves it out.
hidden: bool = false,
/// Command lines, without the leading `telar`, that the parser accepts.
examples: []const []const [*:0]const u8,
