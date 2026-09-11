const Decoded = @This();

status_code: u16 = 0,
request: bool = false,
inference_method: bool = false,
inference_route: bool = false,
content_type_seen: bool = false,
event_stream: bool = false,
identity_encoding: bool = true,
metadata_valid: bool = true,

pub fn isInference(decoded: Decoded) bool {
    return decoded.request and decoded.inference_method and decoded.inference_route;
}

pub fn hasObservableSseBody(decoded: Decoded) bool {
    return decoded.metadata_valid and decoded.content_type_seen and
        decoded.event_stream and decoded.identity_encoding;
}
