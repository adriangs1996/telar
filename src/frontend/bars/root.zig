//! Configurable, bounded top and bottom bar capability.

const model = @import("model.zig");

pub const command = @import("command.zig");
pub const max_segments = model.max_segments;
pub const max_text_bytes = model.max_text_bytes;
pub const max_command_args = model.max_command_args;
pub const max_command_bytes = model.max_command_bytes;
pub const min_interval_ms = model.min_interval_ms;
pub const max_interval_ms = model.max_interval_ms;
pub const min_command_timeout_ms = model.min_command_timeout_ms;
pub const max_command_timeout_ms = model.max_command_timeout_ms;
pub const Position = model.Position;
pub const Alignment = model.Alignment;
pub const PaletteColor = model.PaletteColor;
pub const Color = model.Color;
pub const Style = model.Style;
pub const Segment = model.Segment;
pub const Content = model.Content;
pub const CallbackRef = model.CallbackRef;
pub const Dynamic = model.Dynamic;
pub const Command = model.Command;
pub const Source = model.Source;
pub const Configuration = model.Configuration;
pub const Slot = model.Slot;
pub const Layout = model.Layout;
pub const Change = model.Change;
pub const Update = model.Update;
pub const State = model.State;

test {
    _ = command;
}
