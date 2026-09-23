const Decoded = @This();

status_code: u16 = 0,
request: bool = false,
inference_method: bool = false,
inference_route: bool = false,
content_type_seen: bool = false,
event_stream: bool = false,
identity_encoding: bool = true,
metadata_valid: bool = true,

pub fn isInference(self: Decoded) bool {
    return self.request and self.inference_method and self.inference_route;
}

pub fn hasObservableSseBody(self: Decoded) bool {
    return self.metadata_valid and self.content_type_seen and
        self.event_stream and self.identity_encoding;
}
