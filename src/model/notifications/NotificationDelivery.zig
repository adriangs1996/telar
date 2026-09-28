const std = @import("std");

pub const NotificationDelivery = enum {
    telar,
    system,

    pub fn parse(text: []const u8) ?NotificationDelivery {
        inline for (@typeInfo(NotificationDelivery).@"enum".fields) |field| {
            if (std.mem.eql(
                u8,
                text,
                field.name,
            )) {
                return @field(NotificationDelivery, field.name);
            }
        }
        return null;
    }
};
