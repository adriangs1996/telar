module telar.runtime.terminal.control.glyph;

namespace telar::runtime::control {

  std::optional<std::uint32_t> glyphCodepoint(std::string_view value) noexcept {
    if (value.starts_with('+')) {
      value.remove_prefix(1);
    }

    constexpr std::uint32_t maximum_codepoint = (1u << 21) - 1;
    const auto result = unsignedNumber<std::uint32_t>(value, maximum_codepoint, 16);

    return result ? std::optional{*result} : std::nullopt;
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> glyphOption(tbc::view<std::string_view, tbc::lt::a> options, std::string_view key) noexcept {
    std::optional<std::string_view> result;

    while (!options.empty()) {
      const auto end = options.find(';');
      const auto pair = options.substr(0, end);
      const auto separator = pair.find('=');
      if (separator != std::string_view::npos && pair.substr(0, separator) == key) {
        result = pair.substr(separator + 1);
      }

      if (end == std::string_view::npos) {
        break;
      }

      options.remove_prefix(end + 1);
    }

    return result;
  }

  void glyph(std::string_view request, Reply<ConcurrentMemory>& reply) {
    if (request.empty() || (request.size() > 1 && request[1] != ';')) {
      return;
    }

    const auto options = request.size() > 1 ? request.substr(2) : std::string_view{};

    switch (request.front()) {
    case 's':
      reply.append("\x1b_25a1;s;fmt=\x1b\\");
      break;
    case 'q': {
      const auto encoded = glyphOption(options, "cp");
      const auto codepoint = encoded ? glyphCodepoint(*encoded) : std::nullopt;
      if (codepoint) {
        reply.append("\x1b_25a1;q;cp=");
        reply.hex(*codepoint, 1);
        reply.append(";status=\x1b\\");
      }

      break;
    }
    case 'r': {
      const auto payload_separator = options.rfind(';');
      if (payload_separator == std::string_view::npos) {
        return;
      }

      const auto metadata = options.substr(0, payload_separator);
      if (glyphOption(metadata, "reply") == "0") {
        return;
      }

      const auto encoded = glyphOption(metadata, "cp");
      const auto codepoint = encoded ? glyphCodepoint(*encoded) : std::nullopt;

      reply.append("\x1b_25a1;r;cp=");
      reply.hex(codepoint.value_or(0), 1);
      reply.append(";status=1;reason=unsupported_format\x1b\\");
      break;
    }
    case 'c':
      reply.append("\x1b_25a1;c;status=0\x1b\\");
      break;
    default:
      break;
    }
  }

}
