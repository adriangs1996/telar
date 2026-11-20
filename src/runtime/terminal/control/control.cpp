module telar.runtime.terminal.control;

import telar.render.document;
import telar.base.ds;

namespace telar::runtime::control {

  namespace {

    constexpr unsigned decimal_base = 10;

    // The parameters of a control sequence as its bytes arrive, one byte at a time.
    struct ParameterScan {
      Parameters result;
      std::uint32_t accumulator = 0;
      unsigned digits = 0;
      bool intermediate_phase = false;

      // False when the parameters already hold as many values as they can.
      bool pushValue() noexcept {
        if (result.count == Parameters::capacity) {
          return false;
        }

        result.values.atMut(result.count++) = static_cast<std::uint16_t>(accumulator);
        return true;
      }

      bool digit(char byte) noexcept {
        if (++digits > Parameters::maximum_digits) {
          return false;
        }

        accumulator = std::min(Parameters::maximum_value, (accumulator * decimal_base) + static_cast<unsigned>(byte - '0'));
        return true;
      }

      bool separator(char byte) noexcept {
        if (!pushValue()) {
          return false;
        }

        result.colon |= byte == ':';
        accumulator = 0;
        digits = 0;
        return true;
      }

      bool intermediate(char byte) noexcept {
        const bool prefix = byte >= '<' && byte <= '?' && !intermediate_phase && digits == 0 && result.count == 0;
        if (!prefix && (byte < ' ' || byte > '/')) {
          return false;
        }

        if (result.intermediate_count == Parameters::intermediate_capacity) {
          return false;
        }

        result.intermediate.atMut(result.intermediate_count++) = byte;
        intermediate_phase |= !prefix;
        return true;
      }

      // False when the byte makes the parameters invalid.
      bool feed(char byte) noexcept {
        if (byte == '\x7f') {
          return true;
        }

        if (!intermediate_phase && byte >= '0' && byte <= '9') {
          return digit(byte);
        }

        if (!intermediate_phase && (byte == ';' || byte == ':')) {
          return separator(byte);
        }

        return intermediate(byte);
      }
    };

  }

  std::string_view Sequence::body() const noexcept {
    const auto prefix = kind == Kind::escape ? 1U : 2U;

    return textView(bytes.subspan(prefix));
  }

  std::string_view takeField(std::string_view& remaining, char separator) noexcept {
    const auto end = remaining.find(separator);
    const auto result = textPrefix(remaining, end);

    remaining = end == std::string_view::npos ? std::string_view{} : textAfter(remaining, end + 1);
    return result;
  }

  ds::Option<Parameters> Parameters::parse(std::string_view body) noexcept {
    if (body.empty()) {
      return ds::none;
    }

    ParameterScan scan;

    scan.result.final = body.back();
    body.remove_suffix(1);
    for (const auto byte : body) {
      if (!scan.feed(byte)) {
        return ds::none;
      }
    }

    if (scan.digits != 0 && !scan.pushValue()) {
      return ds::none;
    }

    return scan.result;
  }

  [[gnu::noinline]] std::size_t completeAsciiApc(std::span<const std::uint8_t> input, std::size_t limit) noexcept {
    if (input.size() < 3 || limit < 3) {
      return 0;
    }

    constexpr std::uint8_t escape = 0x1b;
    constexpr std::uint8_t space = 0x20;
    constexpr std::uint8_t last_ascii = 0x7f;
    const auto body = input.subspan(3, std::min(input.size() - 3, limit - 2));
    // libc++ lowers a find over bytes to memchr.
    const auto terminator = std::ranges::find(body, escape);
    if (terminator == body.end()) {
      return 0;
    }

    const auto count = static_cast<std::size_t>(terminator - body.begin());
    std::uint8_t maximum_offset = 0;

    for (const auto byte : body.first(count)) {
      maximum_offset = std::max(maximum_offset, static_cast<std::uint8_t>(byte - space));
    }

    return maximum_offset <= last_ascii - space ? count + 3 : 0;
  }

  ds::Option<std::uint32_t> GraphicsHeader::value(std::uint8_t key, std::string_view text) noexcept {
    if (text.size() == 1 && (text.front() < '0' || text.front() > '9')) {
      return static_cast<std::uint8_t>(text.front());
    }

    const bool negative = text.starts_with('-');
    if (negative || text.starts_with('+')) {
      text.remove_prefix(1);
    }

    const auto magnitude = kittyUnsigned<std::uint32_t>(text);
    if (!magnitude) {
      return ds::none;
    }

    const bool signed_field = key == 'z' || key == 'H' || key == 'V';

    if (negative) {
      if (signed_field ? *magnitude > std::uint32_t{std::numeric_limits<std::int32_t>::max()} + 1 : *magnitude != 0) {
        return ds::none;
      }

      return 0U - *magnitude;
    }

    if (signed_field && *magnitude > std::numeric_limits<std::int32_t>::max()) {
      return ds::none;
    }

    return *magnitude;
  }

  bool graphicsQuery(std::string_view body) noexcept {
    if (!body.starts_with('G')) {
      return false;
    }

    const auto separator = body.find(';');
    const auto header = textPrefix(textAfter(body, 1), separator == std::string_view::npos ? separator : separator - 1);
    bool query = false;

    GraphicsHeader::scan(header, separator != std::string_view::npos, [&](std::uint8_t key, std::string_view text) noexcept {
      if (key == 'a') {
        query = GraphicsHeader::value(key, text) == static_cast<std::uint32_t>('q');
      }

      return true;
    });

    return query;
  }

  bool streamable(Sequence sequence) noexcept {
    const auto body = sequence.body();

    switch (sequence.kind) {
    case Kind::osc: {
      // Documents are buffered whole for the engine; ghostty never sees them.
      const auto number = oscOperation(textPrefix(body, body.find(';')));

      return !number || (!nativeOsc(*number) && *number != ::telar::render::sequence_number);
    }
    case Kind::dcs:
      return !body.ends_with("+q") && !body.ends_with("$q");
    case Kind::apc:
      if (!body.starts_with('G')) {
        // Documents are buffered whole for the engine; ghostty never sees them.
        return !body.starts_with("25a1;");
      }

      return !graphicsQuery(body);
    case Kind::escape:
    case Kind::csi:
      return false;
    }

    // A kind outside the enum is not streamable.
    return false;
  }

  bool query(Sequence sequence) noexcept {
    const auto body = sequence.body();

    if (sequence.kind == Kind::apc) {
      return graphicsQuery(body) || body.starts_with("25a1;");
    }

    if (sequence.kind == Kind::dcs) {
      const auto end = body.find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
      if (end == std::string_view::npos) {
        return false;
      }

      const auto header = Parameters::parse(textPrefix(body, end + 1));

      return header && header->final == 'q' && (header->modifiers() == "+" || header->modifiers() == "$");
    }

    if (sequence.kind == Kind::osc) {
      const auto operation = oscOperation(textPrefix(body, body.find(';')));

      return operation && nativeOsc(*operation);
    }

    if (sequence.kind == Kind::escape) {
      return body == "Z";
    }

    const auto header = Parameters::parse(body);
    if (!header) {
      return false;
    }

    constexpr std::uint16_t first_window_report = 14;
    constexpr std::uint16_t last_window_report = 21;
    const auto modifiers = header->modifiers();

    switch (header->final) {
    case 'c':
      return true;
    case 'n':
      return modifiers.empty() || modifiers == "?";
    case 'q':
      return modifiers == ">";
    case 'p':
      return modifiers == "$" || modifiers == "?$";
    case 'u':
      return modifiers == "?";
    case 't':
      return modifiers.empty() && header->count == 1 && header->values[0] >= first_window_report && header->values[0] <= last_window_report;
    case 'y':
      return modifiers == "*" || modifiers == "#";
    default:
      return false;
    }
  }

  ds::Option<GraphicsQuery> GraphicsQuery::parse(std::string_view header, bool has_payload) noexcept {
    bool query = false;

    return parse(header, has_payload, query);
  }

  ds::Option<GraphicsQuery> GraphicsQuery::parse(std::string_view header, bool has_payload, bool& query) noexcept {
    query = false;
    bool values_valid = true;
    GraphicsQuery result;
    ds::Array<ds::Option<std::uint32_t>, static_cast<std::size_t>(Field::ignored)> values;
    const bool valid = GraphicsHeader::scan(header, has_payload, [&](std::uint8_t key, std::string_view text) noexcept {
      const auto value = GraphicsHeader::value(key, text);

      if (key == 'a') {
        query = value == static_cast<std::uint32_t>('q');
      }

      if (!value) {
        values_valid = false;
        return true;
      }

      const auto field = parameterField(key);
      if (field != Field::ignored) {
        values.atMut(static_cast<std::size_t>(field)) = *value;
      }

      return true;
    });
    if (!valid || !values_valid) {
      return ds::none;
    }

    const auto number = [&](Field field, std::uint32_t fallback = 0) {
      return values[static_cast<std::size_t>(field)].valueOr(fallback);
    };
    if (number(Field::action) != 'q') {
      return ds::none;
    }

    result.image = number(Field::image);
    result.number = number(Field::number);
    result.placement = number(Field::placement);
    result.width = number(Field::width);
    result.height = number(Field::height);
    result.format = number(Field::format, rgba_format);
    if (result.format == 0) {
      result.format = rgba_format;
    }

    result.quiet = number(Field::quiet);
    result.offset = number(Field::offset);
    result.length = number(Field::length);
    const auto medium = number(Field::medium, 'd');
    if (medium > std::numeric_limits<std::uint8_t>::max() || !std::string_view{"dfst"}.contains(static_cast<char>(medium))) {
      return ds::none;
    }

    result.medium = static_cast<char>(medium);
    const auto compression = values[static_cast<std::size_t>(Field::compression)];
    if (compression && *compression != 'z') {
      return ds::none;
    }

    result.compressed = compression.hasValue();
    return result;
  }

  std::span<const std::uint8_t> capability(std::string_view hex) noexcept {
    constexpr std::size_t maximum_name_bytes = 32;
    constexpr int hexadecimal_base = 16;
    constexpr int hexadecimal_letter_value = 10;
    ds::Array<char, maximum_name_bytes> decoded{};
    if (hex.size() % 2 != 0 || hex.size() > decoded.size() * 2) {
      return {};
    }

    const auto digit = [](char value) -> int {
      if (value >= '0' && value <= '9') {
        return value - '0';
      }

      if (value >= 'A' && value <= 'F') {
        return value - 'A' + hexadecimal_letter_value;
      }

      if (value >= 'a' && value <= 'f') {
        return value - 'a' + hexadecimal_letter_value;
      }

      return -1;
    };

    for (std::size_t index = 0; index < hex.size(); index += 2) {
      const auto high = digit(hex[index]);
      const auto low = digit(hex[index + 1]);
      if (high < 0 || low < 0) {
        return {};
      }

      decoded.atMut(index / 2) = static_cast<char>((high * hexadecimal_base) + low);
    }

    const std::string_view name{decoded.data(), hex.size() / 2};
    std::size_t first = 0;
    std::size_t last = capabilities.size();

    while (first != last) {
      const auto middle = first + ((last - first) / 2);
      if (capabilities[middle].name < name) {
        first = middle + 1;
      } else {
        last = middle;
      }
    }

    return first < capabilities.size() && capabilities[first].name == name ? encoded_capabilities[first].view() : std::span<const std::uint8_t>{};
  }

  bool hexadecimalColorChannel(std::string_view value) noexcept {
    if (value.empty() || value.size() > 4) {
      return false;
    }

    return std::ranges::all_of(value, [](char digit) {
      return (digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f') || (digit >= 'A' && digit <= 'F');
    });
  }

  bool intensityColorChannel(std::string_view value) noexcept {
    const bool negative = value.starts_with('-');
    if (negative || value.starts_with('+')) {
      value.remove_prefix(1);
    }

    unsigned integral = 0;
    bool fractional = false;
    bool nonzero_fraction = false;
    bool digit = false;

    for (const auto character : value) {
      if (character == '.' && !fractional) {
        fractional = true;
        continue;
      }

      if (character < '0' || character > '9') {
        return false;
      }

      digit = true;
      if (fractional) {
        nonzero_fraction |= character != '0';
      } else {
        integral = (integral * decimal_base) + static_cast<unsigned>(character - '0');
        if (integral > 1) {
          return false;
        }
      }
    }

    return digit && (!negative || (integral == 0 && !nonzero_fraction)) && (integral == 0 || !nonzero_fraction);
  }

  namespace {

    constexpr std::size_t color_channels = 3;
    constexpr std::string_view rgb_prefix = "rgb:";
    constexpr std::string_view rgb_intensity_prefix = "rgbi:";

    // Three hexadecimal channels of equal width, as #rgb and its longer forms spell them.
    bool hexadecimalChannels(std::string_view value) noexcept {
      const auto width = value.size() / color_channels;

      return hexadecimalColorChannel(textPrefix(value, width)) && hexadecimalColorChannel(textPrefix(textAfter(value, width), width)) && hexadecimalColorChannel(textAfter(value, width * 2));
    }

    // #rgb, #rrggbb, #rrrgggbbb or #rrrrggggbbbb, without its #.
    bool hashColor(std::string_view value) noexcept {
      constexpr std::size_t maximum_channel_digits = 4;
      const auto width = value.size() / color_channels;
      if (value.size() % color_channels != 0 || width == 0 || width > maximum_channel_digits) {
        return false;
      }

      return hexadecimalChannels(value);
    }

    // rgb:r/g/b with hexadecimal channels, or rgbi:r/g/b with intensities.
    bool rgbColor(std::string_view value) noexcept {
      const bool intensity = value.starts_with(rgb_intensity_prefix);

      value.remove_prefix(intensity ? rgb_intensity_prefix.size() : rgb_prefix.size());
      for (unsigned channel = 0; channel < color_channels; ++channel) {
        const auto slash = value.find('/');
        if ((slash == std::string_view::npos) != (channel == color_channels - 1)) {
          return false;
        }

        const auto token = textPrefix(value, slash);
        if (!(intensity ? intensityColorChannel(token) : hexadecimalColorChannel(token))) {
          return false;
        }

        if (slash != std::string_view::npos) {
          value.remove_prefix(slash + 1);
        }
      }

      return true;
    }

    // One of X11's color names, whatever its case.
    bool namedColor(std::string_view value) noexcept {
      constexpr std::size_t maximum_name_bytes = 64;
      ds::Array<char, maximum_name_bytes> lower{};
      if (value.size() > lower.size()) {
        return false;
      }

      for (std::size_t index = 0; index < value.size(); ++index) {
        const auto character = value[index];

        lower.atMut(index) = character >= 'A' && character <= 'Z' ? static_cast<char>(character + ('a' - 'A')) : character;
      }

      return std::ranges::binary_search(named_colors, std::string_view{lower.data(), value.size()});
    }

  }

  bool colorValue(std::string_view value) noexcept {
    constexpr std::size_t short_hexadecimal_color = 3;
    constexpr std::size_t long_hexadecimal_color = 6;
    const auto start = value.find_first_not_of(" \t");
    if (start == std::string_view::npos) {
      return false;
    }

    value = textPrefix(textAfter(value, start), value.find_last_not_of(" \t") - start + 1);
    if (value.starts_with('#')) {
      return hashColor(textAfter(value, 1));
    }

    if ((value.size() == short_hexadecimal_color || value.size() == long_hexadecimal_color) && hexadecimalChannels(value)) {
      return true;
    }

    if (value.starts_with(rgb_prefix) || value.starts_with(rgb_intensity_prefix)) {
      return rgbColor(value);
    }

    return namedColor(value);
  }

}
