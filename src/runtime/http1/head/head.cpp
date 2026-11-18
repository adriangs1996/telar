module telar.runtime.http1.head;

namespace telar::runtime {

  bool Http1Framing::hasBody() const noexcept {
    return kind == Kind::chunked || kind == Kind::until_close || (kind == Kind::content_length && length != 0);
  }

  template <unsigned Base>
  std::optional<std::size_t> parseHttpNumber(std::string_view text) noexcept {
    // RFC 9110/9112 lengths are 1*DIGIT and chunk sizes 1*HEXDIG: any sign or separator
    // would let this relay frame a message differently from the peer it forwards to.
    static_assert(Base == 10 || Base == 16);

    if (text.empty()) {
      return std::nullopt;
    }

    std::size_t value = 0;

    for (const char character : text) {
      const char lower = asciiLower(character);
      const auto digit = static_cast<unsigned>(lower >= 'a' && lower <= 'f' ? lower - 'a' + 10 : lower - '0');
      if (digit >= Base || value > (std::numeric_limits<std::size_t>::max() - digit) / Base) {
        return std::nullopt;
      }

      value = value * Base + digit;
    }

    return value;
  }

  template std::optional<std::size_t> parseHttpNumber<10>(std::string_view text) noexcept;
  template std::optional<std::size_t> parseHttpNumber<16>(std::string_view text) noexcept;

  std::optional<std::uint16_t> parseHttpStatus(std::string_view text) noexcept {
    if (text.size() != 3) {
      return std::nullopt;
    }

    const auto status = parseHttpNumber<10>(text);

    return status && *status >= 100 && *status <= 599 ? std::optional{static_cast<std::uint16_t>(*status)} : std::nullopt;
  }

  bool isEventStream(std::string_view content_type) noexcept {
    return asciiEqualIgnoreCase(trimText(content_type.substr(0, content_type.find(';')), " \t"), "text/event-stream");
  }

  std::optional<Http1Head> Http1Head::analyze(std::string_view bytes, bool response, bool response_to_head) noexcept {
    const auto boundary = bytes.find("\r\n");
    if (boundary == std::string_view::npos) {
      return std::nullopt;
    }

    const auto start_line = bytes.substr(0, boundary);
    const auto status = response ? parseStatus(start_line) : std::optional<std::uint16_t>{0};
    if (!status) {
      return std::nullopt;
    }

    const bool bodyless = response && bodylessResponse(*status, response_to_head);
    const auto framing = bodyFraming(bytes, response, bodyless);
    if (!framing) {
      return std::nullopt;
    }

    const auto method_end = start_line.find(' ');

    return Http1Head{
        .framing = *framing,
        .status = *status,
        .head_request = !response && method_end != std::string_view::npos && start_line.substr(0, method_end) == "HEAD",
        .informational = response && *status >= 100 && *status < 200 && *status != 101,
        .upgrade = response && *status == 101,
        .closes = framing->kind == Http1Framing::Kind::until_close || connectionCloses(bytes),
    };
  }

  std::optional<Http1Framing> Http1Head::bodyFraming(std::string_view bytes, bool response, bool bodyless) noexcept {
    using Kind = Http1Framing::Kind;

    if (bodyless) {
      return Http1Framing{};
    }

    std::optional<std::size_t> content_length;
    std::optional<std::string_view> transfer_encoding;
    TextFields lines{bytes, "\r\n"};

    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon == std::string_view::npos) {
        continue;
      }

      const auto name = line->substr(0, colon);
      const auto value = trimText(line->substr(colon + 1), " \t");

      // RFC 9112 5.1: whitespace around a field name is rejected, never trimmed into a framing field.
      if (trimText(name, " \t").size() != name.size()) {
        return std::nullopt;
      }

      if (equals(name, "transfer-encoding")) {
        if (transfer_encoding || value.empty()) {
          return std::nullopt;
        }

        transfer_encoding = value;
      }

      if (equals(name, "content-length")) {
        TextFields lengths{value, ","};

        while (const auto part = lengths.next()) {
          const auto length = parseHttpNumber<10>(trimText(*part, " \t"));
          if (!length || (content_length && *content_length != *length)) {
            return std::nullopt;
          }

          content_length = length;
        }
      }
    }

    if (transfer_encoding) {
      if (content_length) {
        return std::nullopt;
      }

      if (endsWithChunked(*transfer_encoding)) {
        return Http1Framing{Kind::chunked};
      }

      return response ? std::optional{Http1Framing{Kind::until_close}} : std::nullopt;
    }

    if (content_length) {
      return Http1Framing{Kind::content_length, *content_length};
    }

    return Http1Framing{response ? Kind::until_close : Kind::none};
  }

  bool Http1Head::connectionCloses(std::string_view bytes) noexcept {
    TextFields lines{bytes, "\r\n"};

    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon == std::string_view::npos || !equals(trimText(line->substr(0, colon), " \t"), "connection")) {
        continue;
      }

      TextFields tokens{line->substr(colon + 1), ","};

      while (const auto token = tokens.next()) {
        if (equals(trimText(*token, " \t"), "close")) {
          return true;
        }
      }
    }

    return false;
  }

  bool Http1Head::endsWithChunked(std::string_view value) noexcept {
    TextFields tokens{value, ","};
    std::string_view last;

    while (const auto token = tokens.next()) {
      last = trimText(*token, " \t");
      if (last.empty()) {
        return false;
      }
    }

    return equals(last, "chunked");
  }

  std::optional<std::uint16_t> Http1Head::parseStatus(std::string_view line) noexcept {
    TextFields parts{line, " "};

    parts.next();
    const auto text = parts.next();

    return text ? parseHttpStatus(*text) : std::nullopt;
  }

  bool Http1Head::equals(std::string_view actual, std::string_view lower) noexcept {
    if (actual.size() != lower.size()) {
      return false;
    }

    for (std::size_t index = 0; index < actual.size(); ++index) {
      if (asciiLower(actual[index]) != lower[index]) {
        return false;
      }
    }

    return true;
  }
}
