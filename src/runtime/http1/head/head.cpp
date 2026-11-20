module telar.runtime.http1.head;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime {

  namespace {

    // The value of the hexadecimal digit 'a'.
    constexpr int first_letter_digit = 10;
    constexpr std::string_view blanks = " \t";

    bool equals(std::string_view actual, std::string_view lower) noexcept {
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

    bool endsWithChunked(std::string_view value) noexcept {
      TextFields tokens{{.text = value, .delimiter = ","}};
      std::string_view last;

      while (const auto token = tokens.next()) {
        last = trimText(*token, blanks);
        if (last.empty()) {
          return false;
        }
      }

      return equals(last, "chunked");
    }

    // The fields that frame a body: Content-Length's value, and whether a Transfer-Encoding ends in chunked.
    struct FramingFields {
      ds::Option<std::size_t> content_length;
      ds::Option<bool> chunked;
    };

    // Folds a Content-Length field's values into `length`; false when one is invalid or disagrees.
    bool readContentLength(std::string_view value, ds::Option<std::size_t>& length) noexcept {
      TextFields lengths{{.text = value, .delimiter = ","}};

      while (const auto part = lengths.next()) {
        const auto parsed = parseHttpNumber<http_decimal>(trimText(*part, blanks));
        if (!parsed || (length && *length != *parsed)) {
          return false;
        }

        length = parsed;
      }

      return true;
    }

    // Reads one field line into `fields`; false when it makes the framing ambiguous or invalid.
    bool readFramingField(std::string_view line, FramingFields& fields) noexcept {
      const auto colon = line.find(':');
      if (colon == std::string_view::npos) {
        return true;
      }

      const auto name = textPrefix(line, colon);
      const auto value = trimText(textAfter(line, colon + 1), blanks);

      // RFC 9112 5.1: whitespace around a field name is rejected, never trimmed into a framing field.
      if (trimText(name, blanks).size() != name.size()) {
        return false;
      }

      if (equals(name, "transfer-encoding")) {
        if (fields.chunked || value.empty()) {
          return false;
        }

        fields.chunked = endsWithChunked(value);
      }

      return !equals(name, "content-length") || readContentLength(value, fields.content_length);
    }

    ds::Option<FramingFields> readFramingFields(std::string_view bytes) noexcept {
      FramingFields fields;
      TextFields lines{{.text = bytes, .delimiter = "\r\n"}};

      lines.next();
      while (const auto line = lines.next()) {
        if (!readFramingField(*line, fields)) {
          return ds::none;
        }
      }

      return fields;
    }

  }

  bool Http1Framing::hasBody() const noexcept {
    return kind == Kind::chunked || kind == Kind::until_close || (kind == Kind::content_length && length != 0);
  }

  template <unsigned Base>
  ds::Option<std::size_t> parseHttpNumber(std::string_view text) noexcept {
    // RFC 9110/9112 lengths are 1*DIGIT and chunk sizes 1*HEXDIG: any sign or separator
    // would let this relay frame a message differently from the peer it forwards to.
    static_assert(Base == http_decimal || Base == http_hexadecimal);

    if (text.empty()) {
      return ds::none;
    }

    std::size_t value = 0;

    for (const char character : text) {
      const char lower = asciiLower(character);
      const auto digit = static_cast<unsigned>(lower >= 'a' && lower <= 'f' ? lower - 'a' + first_letter_digit : lower - '0');
      if (digit >= Base || value > (std::numeric_limits<std::size_t>::max() - digit) / Base) {
        return ds::none;
      }

      value = (value * Base) + digit;
    }

    return value;
  }

  template ds::Option<std::size_t> parseHttpNumber<http_decimal>(std::string_view text) noexcept;
  template ds::Option<std::size_t> parseHttpNumber<http_hexadecimal>(std::string_view text) noexcept;

  ds::Option<std::uint16_t> parseHttpStatus(std::string_view text) noexcept {
    if (text.size() != 3) {
      return ds::none;
    }

    const auto status = parseHttpNumber<http_decimal>(text);

    return status && *status >= HttpStatus::minimum && *status <= HttpStatus::maximum ? ds::Option{static_cast<std::uint16_t>(*status)} : ds::none;
  }

  bool isEventStream(std::string_view content_type) noexcept {
    return asciiEqualIgnoreCase(trimText(textPrefix(content_type, content_type.find(';')), blanks), "text/event-stream");
  }

  ds::Option<Http1Head> Http1Head::analyze(std::string_view bytes, bool response, bool response_to_head) noexcept {
    const auto boundary = bytes.find("\r\n");
    if (boundary == std::string_view::npos) {
      return ds::none;
    }

    const auto start_line = textPrefix(bytes, boundary);
    const auto status = response ? parseStatus(start_line) : ds::Option<std::uint16_t>{0};
    if (!status) {
      return ds::none;
    }

    const bool bodyless = response && bodylessResponse(*status, response_to_head);
    const auto framing = bodyFraming(bytes, response, bodyless);
    if (!framing) {
      return ds::none;
    }

    const auto method_end = start_line.find(' ');

    return Http1Head{
        .framing = *framing,
        .status = *status,
        .head_request = !response && method_end != std::string_view::npos && textPrefix(start_line, method_end) == "HEAD",
        .informational = response && *status >= HttpStatus::minimum && *status < HttpStatus::first_success && *status != HttpStatus::switching_protocols,
        .upgrade = response && *status == HttpStatus::switching_protocols,
        .closes = framing->kind == Http1Framing::Kind::until_close || connectionCloses(bytes),
    };
  }

  ds::Option<Http1Framing> Http1Head::bodyFraming(std::string_view bytes, bool response, bool bodyless) noexcept {
    using Kind = Http1Framing::Kind;

    if (bodyless) {
      return Http1Framing{};
    }

    const auto fields = readFramingFields(bytes);
    if (!fields) {
      return ds::none;
    }

    if (fields->chunked) {
      if (fields->content_length) {
        return ds::none;
      }

      if (*fields->chunked) {
        return Http1Framing{.kind = Kind::chunked};
      }

      return response ? ds::Option{Http1Framing{.kind = Kind::until_close}} : ds::none;
    }

    if (fields->content_length) {
      return Http1Framing{.kind = Kind::content_length, .length = *fields->content_length};
    }

    return Http1Framing{.kind = response ? Kind::until_close : Kind::none};
  }

  bool Http1Head::connectionCloses(std::string_view bytes) noexcept {
    TextFields lines{{.text = bytes, .delimiter = "\r\n"}};

    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon == std::string_view::npos || !equals(trimText(textPrefix(*line, colon), blanks), "connection")) {
        continue;
      }

      TextFields tokens{{.text = textAfter(*line, colon + 1), .delimiter = ","}};

      while (const auto token = tokens.next()) {
        if (equals(trimText(*token, blanks), "close")) {
          return true;
        }
      }
    }

    return false;
  }

  ds::Option<std::uint16_t> Http1Head::parseStatus(std::string_view line) noexcept {
    TextFields parts{{.text = line, .delimiter = " "}};

    parts.next();
    const auto text = parts.next();

    return text ? parseHttpStatus(*text) : ds::none;
  }
}
