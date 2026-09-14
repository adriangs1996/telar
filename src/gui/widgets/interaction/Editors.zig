const Geometry = @import("EditorGeometry.zig");
const Id = @import("Id.zig");
const Editors = @This();

pub const capacity = 16;
items: [capacity]Geometry = undefined,
len: usize = 0,

/// Example: `try editors.add(geometry);`
pub fn add(editors: *Editors, geometry: Geometry) !void {
    if (editors.len == capacity) {
        return error.WidgetEditorCapacityExceeded;
    }

    editors.items[editors.len] = geometry;
    editors.len += 1;
}

/// Example: `const geometry = editors.find(target.id) orelse return;`
pub fn find(editors: *const Editors, id: Id) ?Geometry {
    for (editors.items[0..editors.len]) |item| {
        if (item.id.eql(id)) {
            return item;
        }
    }

    return null;
}
