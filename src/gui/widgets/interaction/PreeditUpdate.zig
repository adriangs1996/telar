const Window = @import("telar-window");
const Composition = @FieldType(Window.Input, "composition");
const FieldView = @import("FieldView.zig");

composition: Composition,
current: FieldView,
