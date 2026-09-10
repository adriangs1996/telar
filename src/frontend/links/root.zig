//! Client-owned link extraction, gesture state and host opening adapters.

const cells = @import("telar-client").links.cells;
const file_uri = @import("telar-client").links.file_uri;
const opening = @import("telar-client").links.opening;
const pointer = @import("telar-client").links.pointer;
const target = @import("telar-client").links.target;

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
