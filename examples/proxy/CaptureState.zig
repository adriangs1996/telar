const CaptureState = @This();

buffer: []u8,
kept: usize = 0,
truncated: bool = false,

fn keep(state: *CaptureState, bytes: []const u8) void {
    if (state.kept >= state.buffer.len) {
        state.truncated = true;
        return;
    }

    const room = state.buffer.len - state.kept;
    const take = @min(room, bytes.len);
    @memcpy(state.buffer[state.kept .. state.kept + take], bytes[0..take]);
    state.kept += take;
    if (take < bytes.len) {
        state.truncated = true;
    }
}
