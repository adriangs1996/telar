module telar.runtime.terminal.control;

import telar.render.document;
import telar.base.ds;

namespace telar::runtime::control {

  std::string_view Sequence::body() const noexcept {
    const auto prefix = kind == Kind::escape ? 1u : 2u;

    return {reinterpret_cast<const char*>(bytes.data() + prefix), bytes.size() - prefix};
  }

  std::string_view takeField(std::string_view& remaining, char separator) noexcept {
    const auto end = remaining.find(separator);
    const auto result = remaining.substr(0, end);

    remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
    return result;
  }

  ds::Option<Parameters> Parameters::parse(std::string_view body) noexcept {
    if (body.empty()) {
      return ds::none;
    }

    Parameters result;

    result.final = body.back();
    body.remove_suffix(1);
    bool intermediate_phase = false;
    std::uint32_t accumulator = 0;
    unsigned digits = 0;

    for (const auto byte : body) {
      if (byte == '\x7f') {
        continue;
      }

      if (!intermediate_phase && byte >= '0' && byte <= '9') {
        if (++digits > maximum_digits) {
          return ds::none;
        }

        accumulator = std::min(maximum_value, accumulator * 10 + static_cast<unsigned>(byte - '0'));
        continue;
      }

      if (!intermediate_phase && (byte == ';' || byte == ':')) {
        if (result.count == capacity) {
          return ds::none;
        }

        result.values[result.count++] = static_cast<std::uint16_t>(accumulator);
        result.colon |= byte == ':';
        accumulator = 0;
        digits = 0;
        continue;
      }

      const bool prefix = byte >= '<' && byte <= '?' && !intermediate_phase && digits == 0 && result.count == 0;
      if (prefix || (byte >= ' ' && byte <= '/')) {
        if (result.intermediate_count == intermediate_capacity) {
          return ds::none;
        }

        result.intermediate[result.intermediate_count++] = byte;
        intermediate_phase |= !prefix;
        continue;
      }

      return ds::none;
    }

    if (digits != 0) {
      if (result.count == capacity) {
        return ds::none;
      }

      result.values[result.count++] = static_cast<std::uint16_t>(accumulator);
    }

    return result;
  }

  [[gnu::noinline]] std::size_t completeAsciiApc(std::span<const std::uint8_t> input, std::size_t limit) noexcept {
    if (input.size() < 3 || limit < 3) {
      return 0;
    }

    constexpr std::uint8_t escape = 0x1b;
    constexpr std::uint8_t space = 0x20;
    constexpr std::uint8_t last_ascii = 0x7f;
    const auto body = input.subspan(3, std::min(input.size() - 3, limit - 2));
    const auto* terminator = static_cast<const std::uint8_t*>(std::memchr(body.data(), escape, body.size()));
    if (terminator == nullptr) {
      return 0;
    }

    const auto count = static_cast<std::size_t>(terminator - body.data());
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

      return 0u - *magnitude;
    }

    if (signed_field && *magnitude > std::numeric_limits<std::int32_t>::max()) {
      return ds::none;
    }

    return magnitude;
  }

  bool graphicsQuery(std::string_view body) noexcept {
    if (!body.starts_with('G')) {
      return false;
    }

    const auto separator = body.find(';');
    const auto header = body.substr(1, separator == std::string_view::npos ? separator : separator - 1);
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
      const auto number = oscOperation(body.substr(0, body.find(';')));

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
    default:
      return false;
    }
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

      const auto header = Parameters::parse(body.substr(0, end + 1));

      return header && header->final == 'q' && (header->modifiers() == "+" || header->modifiers() == "$");
    }

    if (sequence.kind == Kind::osc) {
      const auto operation = oscOperation(body.substr(0, body.find(';')));

      return operation && nativeOsc(*operation);
    }

    if (sequence.kind == Kind::escape) {
      return body == "Z";
    }

    const auto header = Parameters::parse(body);
    if (!header) {
      return false;
    }

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
      return modifiers.empty() && header->count == 1 && header->values[0] >= 14 && header->values[0] <= 21;
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
    std::array<ds::Option<std::uint32_t>, static_cast<std::size_t>(Field::ignored)> values;
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
        values[static_cast<std::size_t>(field)] = *value;
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
    result.format = number(Field::format, 32);
    if (result.format == 0) {
      result.format = 32;
    }

    result.quiet = number(Field::quiet);
    result.offset = number(Field::offset);
    result.length = number(Field::length);
    const auto medium = number(Field::medium, 'd');
    if (medium > std::numeric_limits<std::uint8_t>::max() || std::string_view{"dfst"}.find(static_cast<char>(medium)) == std::string_view::npos) {
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
    std::array<char, 32> decoded;
    if (hex.size() % 2 != 0 || hex.size() > decoded.size() * 2) {
      return {};
    }

    const auto digit = [](char value) -> int {
      if (value >= '0' && value <= '9') {
        return value - '0';
      }

      if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
      }

      if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
      }

      return -1;
    };

    for (std::size_t index = 0; index < hex.size(); index += 2) {
      const auto high = digit(hex[index]);
      const auto low = digit(hex[index + 1]);
      if (high < 0 || low < 0) {
        return {};
      }

      decoded[index / 2] = static_cast<char>(high * 16 + low);
    }

    const std::string_view name{decoded.data(), hex.size() / 2};
    std::size_t first = 0;
    std::size_t last = capabilities.size();

    while (first != last) {
      const auto middle = first + (last - first) / 2;
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

    return std::all_of(value.begin(), value.end(), [](char c) {
      return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
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

    for (const auto c : value) {
      if (c == '.' && !fractional) {
        fractional = true;
        continue;
      }

      if (c < '0' || c > '9') {
        return false;
      }

      digit = true;
      if (fractional) {
        nonzero_fraction |= c != '0';
      } else {
        integral = integral * 10 + static_cast<unsigned>(c - '0');
        if (integral > 1) {
          return false;
        }
      }
    }

    return digit && (!negative || (integral == 0 && !nonzero_fraction)) && (integral == 0 || !nonzero_fraction);
  }

  bool colorValue(std::string_view value) noexcept {
    const auto start = value.find_first_not_of(" \t");
    if (start == std::string_view::npos) {
      return false;
    }

    value = value.substr(start, value.find_last_not_of(" \t") - start + 1);
    if (value.starts_with('#')) {
      value.remove_prefix(1);
      if (value.size() != 3 && value.size() != 6 && value.size() != 9 && value.size() != 12) {
        return false;
      }

      const auto width = value.size() / 3;

      return hexadecimalColorChannel(value.substr(0, width)) && hexadecimalColorChannel(value.substr(width, width)) && hexadecimalColorChannel(value.substr(width * 2));
    }

    if ((value.size() == 3 || value.size() == 6) && hexadecimalColorChannel(value.substr(0, value.size() / 3)) && hexadecimalColorChannel(value.substr(value.size() / 3, value.size() / 3)) && hexadecimalColorChannel(value.substr(value.size() * 2 / 3))) {
      return true;
    }

    if (value.starts_with("rgb:") || value.starts_with("rgbi:")) {
      const bool intensity = value.starts_with("rgbi:");

      value.remove_prefix(intensity ? 5 : 4);
      for (unsigned channel = 0; channel < 3; ++channel) {
        const auto slash = value.find('/');
        if ((slash == std::string_view::npos) != (channel == 2)) {
          return false;
        }

        const auto token = value.substr(0, slash);
        if (!(intensity ? intensityColorChannel(token) : hexadecimalColorChannel(token))) {
          return false;
        }

        if (slash != std::string_view::npos) {
          value.remove_prefix(slash + 1);
        }
      }

      return true;
    }

    std::array<char, 64> lower;
    if (value.size() > lower.size()) {
      return false;
    }

    for (std::size_t i = 0; i < value.size(); ++i) {
      const auto c = value[i];

      lower[i] = c >= 'A' && c <= 'Z' ? static_cast<char>(c + ('a' - 'A')) : c;
    }

    return std::binary_search(named_colors.begin(), named_colors.end(), std::string_view{lower.data(), value.size()});
  }

}
