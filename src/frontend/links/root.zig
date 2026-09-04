//! Client-owned link extraction, gesture state and host opening adapters.

const cells = @import("cells.zig");
const file_uri = @import("file_uri.zig");
const opening = @import("opening.zig");
const pointer = @import("pointer.zig");
const target = @import("target.zig");

pub const Target = target.Target;
pub const Position = cells.Position;
pub const extract = cells.extract;
pub const FilePath = file_uri.FilePath;
pub const Opening = opening.Opening;
pub const OpeningRequest = opening.Request;
pub const Pointer = pointer.Pointer;
pub const PointerCommand = pointer.Command;
pub const PointerKind = pointer.Kind;
pub const PointerOutcome = pointer.Outcome;
pub const host = @import("host.zig");

test {
    _ = cells;
    _ = file_uri;
    _ = opening;
    _ = pointer;
    _ = target;
    _ = host;
}
