const LocalTime = @This();

/// The Unix epoch, reported when the clock or the time zone is unreadable.
pub const epoch: LocalTime = .{
    .year = 1970,
    .month = 1,
    .day = 1,
    .hour = 0,
    .minute = 0,
    .second = 0,
    .weekday = 4,
};

year: u16,
month: u8,
day: u8,
hour: u8,
minute: u8,
second: u8,
weekday: u8,
