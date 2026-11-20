module telar.base.text;

import std;
import telar.tbc;
import telar.sys.socket;
import telar.base.ds;

namespace telar::runtime {

  bool constantTimeEqual(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    unsigned difference = 0;

    for (std::size_t index = 0; index < left.size(); ++index) {
      const unsigned first = static_cast<unsigned char>(left[index]);
      const unsigned second = static_cast<unsigned char>(right[index]);

      difference |= first ^ second;
    }

    return difference == 0;
  }

  TextFields::TextFields(TextSplit split) noexcept
      : remaining_(split.text),
        delimiter_(split.delimiter) {}

  tbc::val_a<ds::Option<std::string_view>> TextFields::next() noexcept {
    if (finished_) {
      return ds::none;
    }

    const auto boundary = remaining_.find(delimiter_);
    if (boundary == std::string_view::npos) {
      finished_ = true;
      return remaining_;
    }

    auto field = remaining_;

    field.remove_suffix(field.size() - boundary);
    remaining_.remove_prefix(boundary + delimiter_.size());
    return field;
  }

  tbc::val_a<std::string_view> trimText(tbc::val_a<std::string_view> text, std::string_view characters) noexcept {
    const auto start = text.find_first_not_of(characters);
    if (start == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - 1 - text.find_last_not_of(characters));
    text.remove_prefix(start);
    return text;
  }

  template <Allocator Memory>
  void appendLowerHex(ds::String<Memory>& output, std::span<const std::uint8_t> bytes) {
    const auto start = output.size();

    output.resize(start + (2 * bytes.size()));
    static_cast<void>(encodeLowerHex(bytes, output.viewMut().subspan(start)));
  }

  template void appendLowerHex<Memory>(ds::String<Memory>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<ConcurrentMemory>(ds::String<ConcurrentMemory>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<SystemAllocator>(ds::String<SystemAllocator>& output, std::span<const std::uint8_t> bytes);
  template void appendLowerHex<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& output, std::span<const std::uint8_t> bytes);

  bool validIdentifier(std::string_view name) noexcept {
    if (name.empty() || name.front() == '.' || name.back() == '.' || name.contains("..")) {
      return false;
    }

    return std::ranges::all_of(name, [](unsigned char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_';
    });
  }

  namespace {

    constexpr unsigned decimal_radix = 10;
    constexpr unsigned hex_radix = 16;

    // What digit() returns for a byte that is no digit, which no base it reads reaches.
    constexpr unsigned not_a_digit = hex_radix;

    // A hexadecimal significand of more digits than this takes the reference's long-hex fallback,
    // which stops at a decimal coefficient of 10^31.
    constexpr std::size_t hex_fallback_digits = 32;
    constexpr unsigned hex_fallback_power = 31;

    constexpr std::int64_t exponent_limit = 1'000'000;
    constexpr auto hex_fallback_coefficient = [] {
      __uint128_t value = 1;

      for (unsigned power = 0; power < hex_fallback_power; ++power) {
        value *= decimal_radix;
      }

      return value;
    }();
    constexpr std::string_view decimal_lower = "999999999999999999999999999999999951851751390319103673600551435376817036547458794615295119001530110836029052734375";
    constexpr std::string_view decimal_upper = "100000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125";
    constexpr auto binary_lower = [] {
      ds::Array<char, 114> digits{};

      digits.fill('1');
      return digits;
    }();
    constexpr auto binary_upper = [] {
      ds::Array<char, 114> digits{};

      digits.fill('0');
      digits.atMut(0) = '1';
      digits.atMut(digits.size() - 1) = '1';
      return digits;
    }();

    unsigned digit(char byte) noexcept {
      if (byte >= '0' && byte <= '9') {
        return static_cast<unsigned>(byte - '0');
      }

      if (byte >= 'a' && byte <= 'f') {
        return static_cast<unsigned>(byte - 'a') + decimal_radix;
      }

      if (byte >= 'A' && byte <= 'F') {
        return static_cast<unsigned>(byte - 'A') + decimal_radix;
      }

      return not_a_digit;
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
          if (index == 0 || index + 1 == text.size() || digit(text[index - 1]) >= decimal_radix || digit(text[index + 1]) >= decimal_radix) {
            return false;
          }

          continue;
        }

        const auto number = digit(text[index]);
        if (number >= decimal_radix) {
          return false;
        }

        value = std::min(exponent_limit, (value * decimal_radix) + number);
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
    ds::String<Memory> text{memory};

    if (value.encoded().starts_with('"')) {
      value.string(text);
    } else {
      text.assign(value.encoded());
    }

    return SchemaVersion{memory}.parse(text);
  }

  template <Allocator Memory>
  SchemaVersion<Memory>::SchemaVersion(Memory& memory)
      : digits_(memory) {}

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

    const unsigned base = hexadecimal ? hex_radix : decimal_radix;
    const auto exponent_at = text.find_first_of(hexadecimal ? "pP" : "eE");
    const auto mantissa = text.substr(0, exponent_at);
    if (!readMantissa(mantissa, base, floating)) {
      return false;
    }

    std::int64_t exponent = 0;
    if (exponent_at != std::string_view::npos && (!floating || !readExponent(text.substr(exponent_at + 1), exponent))) {
      return false;
    }

    const auto first = digits_.view().find_first_not_of('0');
    if (first == std::string_view::npos) {
      return false;
    }

    exponent += integer_digits_ - static_cast<std::int64_t>(first);
    if (hexadecimal && (digits_.size() - ((first / 4) * 4)) / 4 > hex_fallback_digits) {
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
        coefficient = (coefficient * 2) + static_cast<unsigned>(digits_[consumed++] - '0');
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

      if (base == hex_radix) {
        for (unsigned shift = 4; shift != 0; --shift) {
          digits_.push(static_cast<char>('0' + ((value >> (shift - 1)) & 1U)));
        }
      } else {
        digits_.push(byte);
      }

      if (!point) {
        integer_digits_ += base == hex_radix ? 4 : 1;
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
      return ipv6(pattern).hasValue();
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
      return ipv6(hostname).hasValue();
    }

    if (hostname.ends_with('.')) {
      hostname.remove_suffix(1);
    }

    return validLabels(hostname);
  }

  ds::Option<in6_addr> ProxyHostname::ipv6(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      return {};
    }

    ds::Array<char, INET6_ADDRSTRLEN> text{};

    std::ranges::copy(host, text.viewMut().begin());
    in6_addr address{};

    return ::inet_pton(AF_INET6, text.data(), &address) == 1 ? ds::Option{address} : ds::none;
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

  ds::Option<ProxyTarget> ProxyTarget::parse(std::string_view head) noexcept {
    constexpr std::string_view method = "CONNECT ";
    constexpr std::string_view version = " HTTP/1.1";
    const auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      return ds::none;
    }

    auto line = head;

    line.remove_suffix(head.size() - line_end);
    if (!line.starts_with(method) || !line.ends_with(version) || line.size() <= method.size() + version.size()) {
      return ds::none;
    }

    auto authority = line;

    authority.remove_prefix(method.size());
    authority.remove_suffix(version.size());
    const auto colon = authority.rfind(':');
    if (colon == std::string_view::npos || colon == 0 || colon > ProxyHostname::maximum_bytes) {
      return ds::none;
    }

    auto hostname = authority;

    hostname.remove_suffix(authority.size() - colon);
    if (!ProxyHostname::validTarget(hostname)) {
      return ds::none;
    }

    auto port_text = authority;

    port_text.remove_prefix(colon + 1);
    const auto port = parseExact<std::uint16_t>(port_text).valueOr(0);
    if (port == 0) {
      return ds::none;
    }

    return ProxyTarget{.hostname = hostname, .port = port};
  }

}

namespace telar::runtime::base64 {

  namespace {

    constexpr std::size_t group_characters = 4;
    constexpr std::size_t sextet_bits = 6;

    // The bits canonical text leaves clear in the last character before its padding: four past a
    // single byte, two past a pair.
    constexpr std::size_t single_byte_spare = 0x0f;
    constexpr std::size_t byte_pair_spare = 0x03;

  }

  Sextets sextetsOf(std::span<const char> group) noexcept {
    const auto rank = [group](std::size_t index) {
      return index < group.size() ? alphabet.find(group[index]) : std::size_t{0};
    };

    return {.first = rank(0), .second = rank(1), .third = rank(2), .fourth = rank(3)};
  }

  template <Padding Rule>
  ds::Option<std::size_t> groupBytes(std::span<const char> group, const Sextets& sextets, bool last) noexcept {
    const bool padding = group[3] == '=';
    const bool double_padding = group[2] == '=';

    if (sextets.first == std::string_view::npos || sextets.second == std::string_view::npos || (padding && !last)) {
      return ds::none;
    }

    if (double_padding) {
      if (!padding || (Rule == Padding::canonical && (sextets.second & single_byte_spare) != 0)) {
        return ds::none;
      }

      return std::size_t{1};
    }

    if (sextets.third == std::string_view::npos) {
      return ds::none;
    }

    if (padding) {
      if (Rule == Padding::canonical && (sextets.third & byte_pair_spare) != 0) {
        return ds::none;
      }

      return std::size_t{2};
    }

    if (sextets.fourth == std::string_view::npos) {
      return ds::none;
    }

    return std::size_t{3};
  }

  std::size_t writeBytes(std::span<std::uint8_t> destination, const Sextets& sextets, std::size_t count) noexcept {
    destination[0] = static_cast<std::uint8_t>((sextets.first << 2U) | (sextets.second >> 4U));
    if (count > 1) {
      destination[1] = static_cast<std::uint8_t>((sextets.second << 4U) | (sextets.third >> 2U));
    }

    if (count > 2) {
      destination[2] = static_cast<std::uint8_t>((sextets.third << sextet_bits) | sextets.fourth);
    }

    return count;
  }

  template <Padding Rule>
  ds::Option<std::size_t> decode(std::string_view encoded, std::span<std::uint8_t> destination) noexcept {
    const auto remainder = encoded.size() % group_characters;
    if (remainder != 0 && (Rule != Padding::optional || remainder == 1)) {
      return ds::none;
    }

    const std::span<const char> characters{encoded};
    const auto complete = characters.size() - remainder;
    std::size_t written = 0;

    for (std::size_t offset = 0; offset < complete; offset += group_characters) {
      const auto group = characters.subspan(offset, group_characters);
      const auto sextets = sextetsOf(group);
      const auto count = groupBytes<Rule>(group, sextets, offset + group_characters == characters.size());
      if (!count || *count > destination.size() - written) {
        return ds::none;
      }

      written += writeBytes(destination.subspan(written), sextets, *count);
    }

    // A short last group, which only optional padding leaves: its bytes are those its characters fill.
    if (remainder != 0) {
      const auto sextets = sextetsOf(characters.subspan(complete));
      if (sextets.first == std::string_view::npos || sextets.second == std::string_view::npos || sextets.third == std::string_view::npos || remainder - 1 > destination.size() - written) {
        return ds::none;
      }

      written += writeBytes(destination.subspan(written), sextets, remainder - 1);
    }

    return written;
  }

  template ds::Option<std::size_t> decode<Padding::canonical>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;
  template ds::Option<std::size_t> decode<Padding::required>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;
  template ds::Option<std::size_t> decode<Padding::optional>(std::string_view encoded, std::span<std::uint8_t> destination) noexcept;

}
