const Message = @This();

status_code: u16 = 0,
head_request: bool = false,
informational: bool = false,
upgrade: bool = false,
closes: bool = false,
