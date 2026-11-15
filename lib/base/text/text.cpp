module telar.base.text;

import std;
import telar.tbc;
import telar.sys.socket;

namespace telar::runtime {

  std::string asciiLowerCopy(std::string_view text) {
    std::string result{text};

    for (auto& byte : result) {
      byte = asciiLower(byte);
    }

    return result;
  }

  bool constantTimeEqual(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    unsigned difference = 0;

    for (std::size_t index = 0; index < left.size(); ++index) {
      difference |= static_cast<unsigned char>(left[index]) ^ static_cast<unsigned char>(right[index]);
    }

    return difference == 0;
  }

  TextFields::TextFields(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<std::string_view, tbc::lt::b> delimiter) noexcept
      : remaining_(text),
        delimiter_(delimiter) {}

  tbc::view<std::optional<std::string_view>, tbc::lt::a> TextFields::next() noexcept {
    if (finished_) {
      return std::nullopt;
    }

    const auto boundary = remaining_.find(delimiter_);
    const auto field = remaining_.substr(0, boundary);

    if (boundary == std::string_view::npos) {
      finished_ = true;
    } else {
      remaining_.remove_prefix(boundary + delimiter_.size());
    }

    return field;
  }

  tbc::view<std::string_view, tbc::lt::a> trimText(tbc::view<std::string_view, tbc::lt::a> text, std::string_view characters) noexcept {
    const auto start = text.find_first_not_of(characters);
    if (start == std::string_view::npos) {
      return {};
    }

    return text.substr(start, text.find_last_not_of(characters) - start + 1);
  }

  template <Allocator Memory>
  void appendLowerHex(String<Memory>& output, std::span<const std::uint8_t> bytes) {
    const auto start = output.size();

    output.resize(start + 2 * bytes.size());
    static_cast<void>(encodeLowerHex(bytes, std::span{output}.subspan(start)));
  }

  template void appendLowerHex<Memory>(String<Memory>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<ConcurrentMemory>(String<ConcurrentMemory>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<SystemAllocator>(String<SystemAllocator>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<BudgetAllocator<SystemAllocator>>(String<BudgetAllocator<SystemAllocator>>& output, std::span<const std::uint8_t> bytes);

  std::string lowerHex(std::span<const std::uint8_t> bytes) {
    std::string text(2 * bytes.size(), '\0');

    static_cast<void>(encodeLowerHex(bytes, text));
    return text;
  }

  bool validIdentifier(std::string_view name) noexcept {
    if (name.empty() || name.front() == '.' || name.back() == '.' || name.contains("..")) {
      return false;
    }

    return std::ranges::all_of(name, [](unsigned char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_';
    });
  }

  namespace {

    constexpr std::int64_t exponent_limit = 1'000'000;
    constexpr auto hex_fallback_coefficient = [] {
      __uint128_t value = 1;

      for (unsigned power = 0; power < 31; ++power) {
        value *= 10;
      }

      return value;
    }();
    constexpr std::string_view decimal_lower = "999999999999999999999999999999999951851751390319103673600551435376817036547458794615295119001530110836029052734375";
    constexpr std::string_view decimal_upper = "100000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125";
    constexpr auto binary_lower = [] {
      std::array<char, 114> digits;

      digits.fill('1');
      return digits;
    }();
    constexpr auto binary_upper = [] {
      std::array<char, 114> digits;

      digits.fill('0');
      digits.front() = '1';
      digits.back() = '1';
      return digits;
    }();

    unsigned digit(char byte) noexcept {
      if (byte >= '0' && byte <= '9') {
        return static_cast<unsigned>(byte - '0');
      }

      if (byte >= 'a' && byte <= 'f') {
        return static_cast<unsigned>(byte - 'a' + 10);
      }

      if (byte >= 'A' && byte <= 'F') {
        return static_cast<unsigned>(byte - 'A' + 10);
      }

      return 16;
    }

    bool readExponent(std::string_view text, std::int64_t& value) noexcept {
      const bool negative = text.starts_with('-');
      if (negative || text.starts_with('+')) {
        text.remove_prefix(1);
      }

      if (text.empty()) {
        return false;
      }

      for (std::size_t index = 0; index < text.size(); ++index) {
        if (text[index] == '_') {
          if (index == 0 || index + 1 == text.size() || digit(text[index - 1]) >= 10 || digit(text[index + 1]) >= 10) {
            return false;
          }

          continue;
        }

        const auto number = digit(text[index]);
        if (number >= 10) {
          return false;
        }

        value = std::min(exponent_limit, value * 10 + number);
      }

      value = negative ? -value : value;
      return true;
    }

    int compare(std::string_view left, std::string_view right) noexcept {
      for (std::size_t index = 0; index < std::max(left.size(), right.size()); ++index) {
        const auto first = index < left.size() ? left[index] : '0';
        const auto second = index < right.size() ? right[index] : '0';
        if (first != second) {
          return first < second ? -1 : 1;
        }
      }

      return 0;
    }

  }

  template <Allocator Memory>
  bool SchemaVersion<Memory>::isOne(Memory& memory, const JsonValue& value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};

    if (value.encoded().starts_with('"')) {
      value.string(text);
    } else {
      text = value.encoded();
    }

    return SchemaVersion{memory}.parse(text);
  }

  template <Allocator Memory>
  SchemaVersion<Memory>::SchemaVersion(Memory& memory)
      : digits_(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  bool SchemaVersion<Memory>::parse(std::string_view text) {
    const bool floating = text.find_first_of(".eE") != std::string_view::npos;

    if (text.starts_with('+')) {
      text.remove_prefix(1);
    }

    if (text.empty() || text.starts_with('-') || text.front() == '_' || text.back() == '_') {
      return false;
    }

    const bool hexadecimal = floating && (text.starts_with("0x") || text.starts_with("0X"));
    if (hexadecimal) {
      text.remove_prefix(2);
    }

    const unsigned base = hexadecimal ? 16 : 10;
    const auto exponent_at = text.find_first_of(hexadecimal ? "pP" : "eE");
    const auto mantissa = text.substr(0, exponent_at);
    if (!readMantissa(mantissa, base, floating)) {
      return false;
    }

    std::int64_t exponent = 0;
    if (exponent_at != std::string_view::npos && (!floating || !readExponent(text.substr(exponent_at + 1), exponent))) {
      return false;
    }

    const auto first = digits_.find_first_not_of('0');
    if (first == String<Memory>::npos) {
      return false;
    }

    exponent += integer_digits_ - static_cast<std::int64_t>(first);
    if (hexadecimal && (digits_.size() - (first / 4) * 4) / 4 > 32) {
      truncateHexFallback();
    }

    const auto significant = std::string_view{digits_}.substr(first);

    if (!floating) {
      return exponent == 1 && compare(significant, "1") == 0;
    }

    // Versions are compared as binary128 values: this is their exact rounding
    // interval around one; double precision would accept different versions.
    const auto lower = hexadecimal ? std::string_view{binary_lower.data(), binary_lower.size()} : decimal_lower;
    const auto upper = hexadecimal ? std::string_view{binary_upper.data(), binary_upper.size()} : decimal_upper;

    if (exponent == 0) {
      return compare(significant, lower) >= 0;
    }

    return exponent == 1 && compare(significant, upper) <= 0;
  }

  template <Allocator Memory>
  void SchemaVersion<Memory>::truncateHexFallback() {
    // The reference's long-hex fallback stops at a decimal coefficient of
    // 10^31, so its discarded tail cannot participate in binary128 rounding.
    __uint128_t coefficient = 0;
    std::size_t consumed = 0;

    while (consumed < digits_.size() && coefficient < hex_fallback_coefficient) {
      for (unsigned bit = 0; bit < 4; ++bit) {
        coefficient = coefficient * 2 + static_cast<unsigned>(digits_[consumed++] - '0');
      }
    }

    digits_.resize(consumed);
  }

  template <Allocator Memory>
  bool SchemaVersion<Memory>::readMantissa(std::string_view text, unsigned base, bool floating) {
    bool point = false;

    for (std::size_t index = 0; index < text.size(); ++index) {
      const char byte = text[index];
      if (byte == '_') {
        if (index == 0 || index + 1 == text.size() || (floating && (digit(text[index - 1]) >= base || digit(text[index + 1]) >= base))) {
          return false;
        }

        continue;
      }

      if (byte == '.' && floating && !point) {
        point = true;
        continue;
      }

      const auto value = digit(byte);
      if (value >= base) {
        return false;
      }

      if (base == 16) {
        for (unsigned shift = 4; shift != 0; --shift) {
          digits_ += static_cast<char>('0' + ((value >> (shift - 1)) & 1));
        }
      } else {
        digits_ += byte;
      }

      if (!point) {
        integer_digits_ += base == 16 ? 4 : 1;
      }
    }

    return !digits_.empty();
  }

  template class SchemaVersion<Memory>;
  template class SchemaVersion<ConcurrentMemory>;
  template class SchemaVersion<BudgetAllocator<SystemAllocator>>;
  template class SchemaVersion<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  bool ProxyHostname::validPattern(std::string_view pattern) noexcept {
    if (pattern.empty() || pattern.size() > maximum_bytes) {
      return false;
    }

    if (pattern.contains(':')) {
      return ipv6(pattern).has_value();
    }

    if (pattern == "*") {
      return true;
    }

    if (pattern.starts_with("*.")) {
      pattern.remove_prefix(2);
    }

    return validLabels(pattern);
  }

  bool ProxyHostname::validTarget(std::string_view hostname) noexcept {
    if (hostname.empty() || hostname.size() > maximum_bytes) {
      return false;
    }

    if (hostname.contains(':')) {
      return ipv6(hostname).has_value();
    }

    if (hostname.ends_with('.')) {
      hostname.remove_suffix(1);
    }

    return validLabels(hostname);
  }

  std::optional<in6_addr> ProxyHostname::ipv6(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      return {};
    }

    std::array<char, INET6_ADDRSTRLEN> text{};

    std::ranges::copy(host, text.begin());
    in6_addr address{};

    return ::inet_pton(AF_INET6, text.data(), &address) == 1 ? std::optional{address} : std::nullopt;
  }

  bool ProxyHostname::validLabels(std::string_view pattern) noexcept {
    std::size_t label_length = 0;
    char previous = '\0';

    for (const char byte : pattern) {
      if (byte == '.') {
        if (label_length == 0 || label_length > maximum_label_bytes || previous == '-') {
          return false;
        }

        label_length = 0;
      } else if (byte == '-') {
        if (label_length == 0) {
          return false;
        }

        ++label_length;
      } else {
        const char lower = asciiLower(byte);
        if ((lower < 'a' || lower > 'z') && (byte < '0' || byte > '9')) {
          return false;
        }

        ++label_length;
      }

      previous = byte;
    }

    return label_length != 0 && label_length <= maximum_label_bytes && previous != '-';
  }

  std::optional<ProxyTarget> ProxyTarget::parse(std::string_view head) noexcept {
    constexpr std::string_view method = "CONNECT ";
    constexpr std::string_view version = " HTTP/1.1";
    const auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      return std::nullopt;
    }

    const auto line = head.substr(0, line_end);
    if (!line.starts_with(method) || !line.ends_with(version) || line.size() <= method.size() + version.size()) {
      return std::nullopt;
    }

    const auto authority = line.substr(method.size(), line.size() - method.size() - version.size());
    const auto colon = authority.rfind(':');
    if (colon == std::string_view::npos || colon == 0 || colon > ProxyHostname::maximum_bytes) {
      return std::nullopt;
    }

    const auto hostname = authority.substr(0, colon);
    if (!ProxyHostname::validTarget(hostname)) {
      return std::nullopt;
    }

    const auto port_text = authority.substr(colon + 1);
    const auto port = parseExact<std::uint16_t>(port_text).value_or(0);
    if (port == 0) {
      return std::nullopt;
    }

    return ProxyTarget{hostname, port};
  }

}

namespace telar::runtime::base64 {

  template <Padding Rule>
  std::optional<std::size_t> decode(std::string_view encoded, std::span<std::uint8_t> destination) noexcept {
    const auto remainder = encoded.size() % 4;
    if (remainder != 0 && (Rule != Padding::optional || remainder == 1)) {
      return std::nullopt;
    }

    std::size_t written = 0;
    const auto complete = encoded.size() - remainder;

    for (std::size_t offset = 0; offset < complete; offset += 4) {
      const auto first = alphabet.find(encoded[offset]);
      const auto second = alphabet.find(encoded[offset + 1]);
      const auto third = alphabet.find(encoded[offset + 2]);
      const auto fourth = alphabet.find(encoded[offset + 3]);
      const bool padding = encoded[offset + 3] == '=';
      const bool double_padding = encoded[offset + 2] == '=';
      const auto count = double_padding ? 1 : padding ? 2
                                                      : 3;
      if (first == std::string_view::npos || second == std::string_view::npos ||
          (!double_padding && third == std::string_view::npos) || (!padding && fourth == std::string_view::npos) ||
          (double_padding && (!padding || (Rule == Padding::canonical && (second & 15) != 0))) ||
          (Rule == Padding::canonical && padding && !double_padding && (third & 3) != 0) ||
          (padding && offset + 4 != encoded.size()) || static_cast<std::size_t>(count) > destination.size() - written) {
        return std::nullopt;
      }

      destination[written++] = static_cast<std::uint8_t>((first << 2) | (second >> 4));
      if (count > 1) {
        destination[written++] = static_cast<std::uint8_t>((second << 4) | (third >> 2));
      }

      if (count > 2) {
        destination[written++] = static_cast<std::uint8_t>((third << 6) | fourth);
      }
    }

    if (remainder != 0) {
      const auto first = alphabet.find(encoded[complete]);
      const auto second = alphabet.find(encoded[complete + 1]);
      const auto third = remainder == 3 ? alphabet.find(encoded[complete + 2]) : 0;
      if (first == std::string_view::npos || second == std::string_view::npos || third == std::string_view::npos || remainder - 1 > destination.size() - written) {
        return std::nullopt;
      }

      destination[written++] = static_cast<std::uint8_t>((first << 2) | (second >> 4));
      if (remainder == 3) {
        destination[written++] = static_cast<std::uint8_t>((second << 4) | (third >> 2));
      }
    }

    return written;
  }

  template std::optional<std::size_t> decode<Padding::canonical>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;
  template std::optional<std::size_t> decode<Padding::required>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;
  template std::optional<std::size_t> decode<Padding::optional>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;

}
