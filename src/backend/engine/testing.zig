//! Shell stand-ins for Pi used by the engine tests. Each one speaks just
//! enough of the RPC contract to drive one outcome of a prompt.

const types = @import("types.zig");

pub const purpose: types.Purpose = .{ .suggestion = .{ .client_id = 7, .client_generation = 2, .request_id = 3 } };

/// Answers every prompt with a settled reply, and every text query with
/// "Improve agent sidebar". It also emits the noise a real Pi produces.
pub const fake_engine =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"type":"prompt"'*) printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"agent_start"}' 'not json' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}' '{"type":"agent_settled"}' ;;
    \\    *get_last_assistant_text*) printf '%s\n' '{"type":"agent_end","messages":[]}' '{"type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"Improve agent sidebar"}}' ;;
    \\  esac
    \\done
;

/// Accepts the prompt and never settles.
pub const silent_engine = "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}'; sleep 5";

/// Settles, then answers the text query with a null text.
pub const empty_reply_engine = "read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}'; read -r line; printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":null}}'; sleep 5";

/// `arguments` must outlive the options, so callers declare the argv in
/// their own frame.
pub fn options(arguments: []const []const u8, timeout_ms: u32, idle_timeout_ms: u32) types.Options {
    return .{
        .arguments = arguments,
        .timeout_ms = timeout_ms,
        .idle_timeout_ms = idle_timeout_ms,
    };
}
