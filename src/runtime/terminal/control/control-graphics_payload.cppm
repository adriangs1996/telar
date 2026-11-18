export module telar.runtime.terminal.control:graphics_payload;

import std;
import telar.base.ds;

export namespace telar::runtime::control {

  // Graphics uses the standard alphabet with optional padding and ASCII
  // whitespace. Clipboard decoding remains strict and uses base64::decode.
  ds::Option<std::size_t> decodeGraphicsPayload(std::string_view encoded, std::span<std::uint8_t> output) noexcept;

}
