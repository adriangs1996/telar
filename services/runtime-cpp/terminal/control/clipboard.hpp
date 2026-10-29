#pragma once

#include "../../text/base64.hpp"
#include "../effects.hpp"
#include "policy.hpp"

namespace telar::runtime::control {

template <Allocator Memory>
class Clipboard {
public:
  explicit Clipboard(Memory &memory, TerminalEffects<Memory> &effects)
      : decoded_(AllocatorRef<std::uint8_t, Memory>{memory}), effects_(effects) {}

  // OSC 52 supports one selection byte. A read has no desktop result until
  // its pane generation and authorized client have completed the request.
  void traditional(std::string_view payload, Access write_access) {
    const auto separator = payload.find(';');
    if (separator == std::string_view::npos || separator > 1) {
      return;
    }
    const char selection = separator == 0 ? 'c' : payload.front();
    if (selection != 'c' && selection != 'p' && selection != 's') {
      return;
    }

    const auto encoded = payload.substr(separator + 1);
    if (encoded == "?") {
      return;
    }
    if (write_access != Access::allow || encoded.size() > maximum_encoded_bytes) {
      return;
    }

    decoded_.resize(std::min(maximum_bytes, encoded.size() / 4 * 3));
    const auto length = base64::decode(encoded, decoded_);
    if (!length) {
      return;
    }
    effects_.clipboard.assign(decoded_.begin(), decoded_.begin() + *length);
    ++effects_.clipboard_revision;
  }

  static constexpr std::size_t maximum_bytes = 1024 * 1024;
  static constexpr std::size_t maximum_encoded_bytes = (maximum_bytes + 2) / 3 * 4;

private:
  Vector<std::uint8_t, Memory> decoded_;
  TerminalEffects<Memory> &effects_;
};

}
