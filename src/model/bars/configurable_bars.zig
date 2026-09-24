//! A configured bar receiving the output of its command.

const BarUpdateCommit = @import("../state/BarUpdateCommit.zig");
const BarUpdateInput = @import("../state/BarUpdateInput.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Commits one current-generation dynamic block without retaining Lua values.
///
/// ```zig
/// _ = try configurable_bars.update(model, input);
/// ```
pub fn update(model: *ClientModel, input: BarUpdateInput) !?BarUpdateCommit {
    if (input.generation != model.configuration_generation) {
        return error.StaleBarUpdate;
    }
    if (try model.bars.update(.{
        .generation = input.generation,
        .position = input.position,
        .content = input.content,
    }) == .unchanged) {
        return null;
    }

    model.bars_revision +%= 1;
    return .{
        .generation = input.generation,
        .position = input.position,
        .bars_revision = model.bars_revision,
    };
}
