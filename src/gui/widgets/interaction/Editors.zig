const Geometry = @import("EditorGeometry.zig");
const Id = @import("Id.zig");
const Editors = @This();

pub const capacity = 16;
items: [capacity]Geometry = undefined,
len: usize = 0,

/// Example: `try editors.add(geometry);`
pub fn add(self: *Editors, geometry: Geometry) !void {
    if (self.len == capacity) {
        return error.WidgetEditorCapacityExceeded;
    }

    self.items[self.len] = geometry;
    self.len += 1;
}

/// Example: `const geometry = editors.find(target.id) orelse return;`
pub fn find(self: *const Editors, id: Id) ?Geometry {
    for (self.items[0..self.len]) |item| {
        if (item.id.eql(id)) {
            return item;
        }
    }

    return null;
}
