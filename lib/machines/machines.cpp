module telar.machines;

import telar.tbc;
import std;
import telar.sys.posix;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime::machines {

  template <std::size_t MaximumExponent>
  BinaryFraction<MaximumExponent>::BinaryFraction(std::size_t exponent, NumberRadix radix) {
    if (exponent == 0 || exponent > MaximumExponent) {
      throw std::out_of_range{"Binary fraction exponent exceeds capacity"};
    }

    if (radix == NumberRadix::hexadecimal) {
      length_ = (exponent + hexadecimal_bits - 1) / hexadecimal_bits;
      const auto trailing_bits = exponent % hexadecimal_bits;

      digits_.atMut(length_ - 1) = static_cast<std::uint8_t>(trailing_bits == 0 ? 1 : 1U << (hexadecimal_bits - trailing_bits));

      return;
    }

    if (radix != NumberRadix::decimal) {
      throw std::invalid_argument{"Unsupported binary fraction radix"};
    }

    length_ = exponent;
    deriveDecimal(exponent);
  }

  template <std::size_t MaximumExponent>
  unsigned BinaryFraction<MaximumExponent>::digit(std::size_t position) const noexcept {
    return position < length_ ? digits_[position] : 0;
  }

  template <std::size_t MaximumExponent>
  unsigned BinaryFraction<MaximumExponent>::complementDigit(std::size_t position, NumberRadix radix) const noexcept {
    if (position >= length_) {
      return 0;
    }

    return static_cast<unsigned>(radix) - digit(position) - static_cast<unsigned>(position + 1 < length_);
  }

  template <std::size_t MaximumExponent>
  std::size_t BinaryFraction<MaximumExponent>::size() const noexcept {
    return length_;
  }

  template <std::size_t MaximumExponent>
  void BinaryFraction<MaximumExponent>::deriveDecimal(std::size_t exponent) {
    ds::Array<std::uint32_t, limb_capacity> limbs{};

    limbs.atMut(0) = 1;
    std::size_t count = 1;

    for (std::size_t power = 0; power < exponent; ++power) {
      std::uint64_t carry = 0;

      for (auto& limb : limbs.viewMut().first(count)) {
        const auto product = (static_cast<std::uint64_t>(limb) * half_decimal_radix) + carry;

        limb = static_cast<std::uint32_t>(product % decimal_limb_base);
        carry = product / decimal_limb_base;
      }

      if (carry != 0) {
        limbs.atMut(count++) = static_cast<std::uint32_t>(carry);
      }
    }

    auto position = exponent;

    for (auto limb : std::span{limbs}.first(count)) {
      for (unsigned digit = 0; digit < decimal_limb_digits && position != 0; ++digit) {
        digits_.atMut(--position) = static_cast<std::uint8_t>(limb % decimal_radix);
        limb /= decimal_radix;
      }
    }
  }

  template class BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>;
  template class BinaryFraction<JsonUnsignedInteger::zero_half_exponent>;

  MachineFailure::MachineFailure(MachineError code)
      : std::runtime_error(name(code)),
        code_(code) {}

  MachineError MachineFailure::code() const noexcept {
    return code_;
  }

  namespace {

    // MachineError's names, in its order.
    constexpr ds::Array machine_error_names{
        "InvalidMachineId",
        "InvalidMachineLabel",
        "InvalidRemoteDestination",
        "InvalidMachineColor",
        "InvalidRemoteTelarPath",
        "InvalidMachineProfiles",
        "IncompatibleMachineProfiles",
        "TooManyMachines",
        "DuplicateMachineId",
        "DuplicateMachineLabel",
        "DuplicateMachineDestination",
        "UnknownMachine",
        "RemoteDiscoveryUnreadable",
        "GatewayKeyRejected",
        "GatewayPairingRefused",
        "RemoteTelarMissing",
        "RemoteTelarIncompatible",
        "RemoteRuntimeIncompatible",
        "RemoteEndpointUnavailable",
        "IncompatibleSchema",
        "RuntimeAlreadyRunning",
        "InvalidRuntimeDirectory",
    };

  }

  const char* MachineFailure::name(MachineError code) {
    return machine_error_names.at(static_cast<std::size_t>(code));
  }

  ds::Option<MachineError> MachineFailure::named(std::string_view text) noexcept {
    for (std::size_t code = 0; code < machine_error_names.size(); ++code) {
      if (text == machine_error_names[code]) {
        return static_cast<MachineError>(code);
      }
    }

    return ds::none;
  }

  ds::Option<std::string_view> MachineFailure::description(MachineError code) noexcept {
    switch (code) {
    case MachineError::unknown_machine:
      return "no saved machine has that label; see `telar machine list`";
    case MachineError::duplicate_label:
      return "that label is already taken, by a saved machine or by this machine";
    case MachineError::duplicate_destination:
      return "two saved machines cannot share one address";
    case MachineError::too_many:
      return "machines.json already holds the most machines it can";
    case MachineError::invalid_label:
      return "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit";
    case MachineError::invalid_color:
      return "colors are #RRGGBB or a theme role such as red or accent";
    case MachineError::invalid_destination:
      return "a machine is named by the address `telar server pair` prints there, telar://HOST:PORT#KEY";
    case MachineError::invalid_program:
      return "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'";
    case MachineError::invalid_profiles:
      return "machines.json is not a file this telar can read";
    case MachineError::incompatible_profiles:
      return "machines.json was written by a newer telar; update this one to read it";
    case MachineError::invalid_id:
      return "machines.json holds an id that is not m- and 12 hexadecimal digits; remove that machine and add it again";
    case MachineError::duplicate_id:
      return "two machines in machines.json share one id; remove one of them and add it again";
    case MachineError::discovery_unreadable:
      return "telar there answered with something this telar cannot read; install this build there with `telar machine setup`, and keep the shell startup files there quiet";
    case MachineError::host_key_rejected:
      return "the gateway at that address holds another key than the address names; confirm it is the machine you paired, then pair again with an address `telar server pair` prints there";
    case MachineError::authentication_failed:
      return "that machine's gateway does not admit this one; run `telar server pair` there, then `telar machine setup ADDRESS --label LABEL` here";
    case MachineError::remote_program_missing:
      return "the gateway there finds no telar to run; keep telar, telar-runtime, telar-config-check and telar-gateway in one directory there, or run `telar machine setup`";
    case MachineError::remote_program_incompatible:
      return "the telar there is another build; `telar machine setup` installs this one";
    case MachineError::remote_runtime_incompatible:
      return "the runtime there runs another telar build; `telar machine setup` stops it, once you agree, and starts this one";
    case MachineError::endpoint_unavailable:
      return "the runtime there did not answer; check that its gateway runs (`telar server enable` there) and that its port is reachable from here";
    case MachineError::incompatible_schema:
      return "the runtime there speaks another wire schema; `telar machine setup` installs this build there";
    case MachineError::invalid_runtime_directory:
      return "this user's runtime directory is not one telar can use: it must be a private directory of this user";
    case MachineError::runtime_already_running:
      break;
    }

    return ds::none;
  }

  template <std::size_t MaximumPathBytes>
  MachineDiscovery<MaximumPathBytes> MachineDiscovery<MaximumPathBytes>::parse(std::string_view output) {
    if (output.size() > max_output_bytes) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    MachineDiscovery result;
    const ds::Array paths{&result.home_, &result.shell_, &result.endpoint_};

    for (auto* const path : paths) {
      const auto end = output.find('\n');
      if (end == std::string_view::npos) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }

      const auto text = output.substr(0, end);

      validatePath(text, path == &result.endpoint_);
      path->assign(text);
      output.remove_prefix(end + 1);
    }

    if (output.size() != result.schema_.size()) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    for (const auto character : output) {
      if (!asciiAlphanumeric(character)) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }

    std::ranges::copy(output, result.schema_.viewMut().begin());

    return result;
  }

  template <std::size_t MaximumPathBytes>
  std::string_view MachineDiscovery<MaximumPathBytes>::home() const noexcept {
    return home_.view();
  }

  template <std::size_t MaximumPathBytes>
  std::string_view MachineDiscovery<MaximumPathBytes>::shell() const noexcept {
    return shell_.view();
  }

  template <std::size_t MaximumPathBytes>
  std::string_view MachineDiscovery<MaximumPathBytes>::endpoint() const noexcept {
    return endpoint_.view();
  }

  template <std::size_t MaximumPathBytes>
  const SchemaId& MachineDiscovery<MaximumPathBytes>::schema() const noexcept {
    return schema_;
  }

  template <std::size_t MaximumPathBytes>
  bool MachineDiscovery<MaximumPathBytes>::compatible(const SchemaId& expected) const noexcept {
    return schema_ == expected;
  }

  template <std::size_t MaximumPathBytes>
  bool MachineDiscovery<MaximumPathBytes>::asciiAlphanumeric(char character) noexcept {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9');
  }

  template <std::size_t MaximumPathBytes>
  void MachineDiscovery<MaximumPathBytes>::validatePath(std::string_view path, bool socket_path) {
    if (path.empty() || path.size() > MaximumPathBytes || path.front() != '/') {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_character = 0x7f;

    for (const auto character : path) {
      const auto byte = static_cast<unsigned char>(character);
      if (byte < first_printable || byte == delete_character || (socket_path && character == ':')) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }
  }

  template class MachineDiscovery<PATH_MAX>;

  void MachineFieldRules::label(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::label_bytes || !alphanumeric(text.front()) || !std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '.' || byte == '_' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_label};
    }
  }

  void MachineFieldRules::destination(std::string_view text) {
    if (text.empty() || text.front() == '-' || std::ranges::any_of(text, [](unsigned char byte) {
          return byte <= ' ' || byte == delete_byte;
        })) {
      throw MachineFailure{MachineError::invalid_destination};
    }
  }

  void MachineFieldRules::profileDestination(std::string_view text) {
    if (text.size() > MachineLimits::destination_bytes || inspectUtf8(text) != Utf8Validation::valid) {
      throw MachineFailure{MachineError::invalid_destination};
    }

    destination(text);
  }

  void MachineFieldRules::color(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::color_bytes) {
      throw MachineFailure{MachineError::invalid_color};
    }

    if (text.front() == '#') {
      constexpr std::size_t rgb_text_bytes = std::string_view{"#RRGGBB"}.size();
      if (text.size() != rgb_text_bytes || !std::ranges::all_of(text.substr(1), [](char byte) {
            return decimal(byte) || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
          })) {
        throw MachineFailure{MachineError::invalid_color};
      }

      return;
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return (byte >= 'a' && byte <= 'z') || decimal(byte) || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_color};
    }
  }

  void MachineFieldRules::program(std::string_view text) {
    if (text.size() < minimum_program_bytes || text.size() > MachineLimits::program_bytes || text.front() != '/' || text.back() == '/' || text.contains("/../") || text.ends_with("/..")) {
      throw MachineFailure{MachineError::invalid_program};
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '/' || byte == '.' || byte == '_' || byte == '+' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_program};
    }
  }

  bool MachineFieldRules::decimal(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  bool MachineFieldRules::alphanumeric(char byte) noexcept {
    return decimal(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }

  bool MachineAddress::hexadecimal(std::string_view digits, std::size_t count) noexcept {
    return digits.size() == count && std::ranges::all_of(digits, [](char byte) {
      return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
    });
  }

  bool MachineAddress::valid(std::string_view text) noexcept {
    if (!text.starts_with(scheme)) {
      return false;
    }

    text.remove_prefix(scheme.size());
    const auto fragment = text.find('#');
    if (fragment == std::string_view::npos || fragment == 0) {
      return false;
    }

    // The host is a name or an address, an IPv6 one in brackets, and may be followed by a port.
    const auto authority = textPrefix(text, fragment);
    const bool addressed = std::ranges::all_of(authority, [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_' || byte == ':' || byte == '[' || byte == ']';
    });

    const auto keys = textAfter(text, fragment + 1);
    const auto separator = keys.find('.');

    return addressed && authority.front() != ':' && hexadecimal(textPrefix(keys, separator), key_digits) && (separator == std::string_view::npos || hexadecimal(textAfter(keys, separator + 1), code_digits));
  }

  bool MachineAddress::pairing(std::string_view text) noexcept {
    return valid(text) && textAfter(text, text.find('#')).contains('.');
  }

  std::string_view MachineAddress::saved(std::string_view text) noexcept {
    return pairing(text) ? textPrefix(text, text.rfind('.')) : text;
  }

  MachineId MachineId::fromRaw(std::uint64_t value) {
    if (value == 0 || value > maximum_value) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineId identity;

    identity.value_ = value;

    return identity;
  }

  MachineId MachineId::parse(std::string_view text) {
    if (text.size() != text_bytes || !text.starts_with(prefix)) {
      throw MachineFailure{MachineError::invalid_id};
    }

    std::uint64_t value = 0;

    for (const char digit : text.substr(prefix.size())) {
      const auto index = digits.find(digit);
      if (index == std::string_view::npos) {
        throw MachineFailure{MachineError::invalid_id};
      }

      value = (value << bits_per_digit) | index;
    }

    return fromRaw(value);
  }

  MachineId MachineId::draw(void* random, void (*fill)(void*, std::span<std::uint8_t>)) {
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned entropy_bits = sizeof(std::uint64_t) * bits_per_byte;

    for (;;) {
      ds::Array<std::uint8_t, sizeof(std::uint64_t)> bytes{};

      fill(random, bytes.viewMut());
      std::uint64_t value = 0;

      for (std::size_t index = 0; index < bytes.size(); ++index) {
        value |= static_cast<std::uint64_t>(bytes[index]) << (index * bits_per_byte);
      }

      value >>= entropy_bits - value_bits;
      if (value != 0) {
        return fromRaw(value);
      }
    }
  }

  BoundedText<MachineId::text_bytes> MachineId::format() const {
    BoundedText<text_bytes> text;

    text.append(prefix);
    for (std::size_t position = hex_digits; position != 0; --position) {
      const auto shift = (position - 1) * bits_per_digit;

      text.append(digits.substr((value_ >> shift) & digit_mask, 1));
    }

    return text;
  }

  std::uint64_t MachineId::value() const noexcept {
    return value_;
  }

  template <Allocator Memory>
  RadixNumber<Memory>::RadixNumber(Memory& memory, std::string_view text, bool floating_syntax)
      : digits_(memory) {
    if (text.starts_with('+') || text.starts_with('-')) {
      negative_ = text.front() == '-';
      text.remove_prefix(1);
    }

    if (text.empty()) {
      invalid();
    }

    if (floating_syntax && (text.starts_with("0x") || text.starts_with("0X"))) {
      radix_ = hexadecimal_radix;
      text.remove_prefix(hexadecimal_prefix_bytes);
    }

    const auto marker = floating_syntax ? text.find_first_of(radix_ == hexadecimal_radix ? "pP" : "eE") : std::string_view::npos;
    const auto mantissa = text.substr(0, marker);

    readMantissa(mantissa, floating_syntax);
    if (marker != std::string_view::npos) {
      applyExponent(exponent(text.substr(marker + 1), text.size()));
    }

    normalize();
  }

  template <Allocator Memory>
  bool RadixNumber<Memory>::negative() const noexcept {
    return negative_;
  }

  template <Allocator Memory>
  NumberRadix RadixNumber<Memory>::radix() const noexcept {
    return static_cast<NumberRadix>(radix_);
  }

  template <Allocator Memory>
  bool RadixNumber<Memory>::zero() const noexcept {
    return digits_.empty();
  }

  template <Allocator Memory>
  bool RadixNumber<Memory>::integral() const noexcept {
    return point_ >= static_cast<std::ptrdiff_t>(digits_.size());
  }

  template <Allocator Memory>
  std::size_t RadixNumber<Memory>::fractionLeadingZeros() const noexcept {
    return point_ < 0 ? static_cast<std::size_t>(-point_) : 0;
  }

  template <Allocator Memory>
  std::uint32_t RadixNumber<Memory>::integerPart(std::uint32_t maximum) const {
    std::uint32_t value = 0;

    for (std::ptrdiff_t position = 0; position < point_; ++position) {
      const auto digit = digitAt(position);
      if (digit > maximum || value > (maximum - digit) / radix_) {
        invalid();
      }

      value = (value * radix_) + digit;
    }

    return value;
  }

  template <Allocator Memory>
  template <typename Fraction>
  int RadixNumber<Memory>::compareFraction(const Fraction& threshold, bool complement) const noexcept {
    const auto extent = std::max(static_cast<std::ptrdiff_t>(threshold.size()), static_cast<std::ptrdiff_t>(digits_.size()) - point_);

    for (std::ptrdiff_t position = 0; position < extent; ++position) {
      const auto actual = digitAt(point_ + position);
      const auto expected = complement ? threshold.complementDigit(static_cast<std::size_t>(position), radix()) : threshold.digit(static_cast<std::size_t>(position));
      if (actual != expected) {
        return actual < expected ? -1 : 1;
      }
    }

    return 0;
  }

  template <Allocator Memory>
  void RadixNumber<Memory>::invalid() {
    throw std::invalid_argument{"Invalid numeric text"};
  }

  template <Allocator Memory>
  unsigned RadixNumber<Memory>::digitAt(std::ptrdiff_t position) const noexcept {
    return position < 0 || position >= static_cast<std::ptrdiff_t>(digits_.size()) ? 0 : static_cast<unsigned>(digit_symbols.find(digits_[static_cast<std::size_t>(position)]));
  }

  template <Allocator Memory>
  bool RadixNumber<Memory>::validDigit(char byte, unsigned radix) noexcept {
    return digit_symbols.find(runtime::asciiLower(byte)) < radix;
  }

  template <Allocator Memory>
  void RadixNumber<Memory>::readMantissa(std::string_view text, bool floating_syntax) {
    bool point_seen = false;

    for (std::size_t position = 0; position < text.size(); ++position) {
      const auto byte = text[position];
      if (byte == '.') {
        if (!floating_syntax || point_seen) {
          invalid();
        }

        point_seen = true;

        continue;
      }

      if (byte == '_') {
        if (position == 0 || position + 1 == text.size() || (floating_syntax && (!validDigit(text[position - 1], radix_) || !validDigit(text[position + 1], radix_)))) {
          invalid();
        }

        continue;
      }

      if (!validDigit(byte, radix_)) {
        invalid();
      }

      digits_.push(runtime::asciiLower(byte));
      if (!point_seen) {
        ++point_;
      }
    }

    if (digits_.empty()) {
      invalid();
    }
  }

  template <Allocator Memory>
  std::ptrdiff_t RadixNumber<Memory>::exponent(std::string_view text, std::size_t source_bytes) {
    const bool negative = text.starts_with('-');
    if (negative || text.starts_with('+')) {
      text.remove_prefix(1);
    }

    if (text.empty()) {
      invalid();
    }

    const auto budget = static_cast<std::ptrdiff_t>(source_bytes) + minimum_exponent_budget;
    std::ptrdiff_t value = 0;

    for (std::size_t position = 0; position < text.size(); ++position) {
      if (text[position] == '_') {
        if (position == 0 || position + 1 == text.size() || !validDigit(text[position - 1], decimal_radix) || !validDigit(text[position + 1], decimal_radix)) {
          invalid();
        }

        continue;
      }

      if (!validDigit(text[position], decimal_radix)) {
        invalid();
      }

      value = std::min(budget, (value * decimal_radix) + static_cast<std::ptrdiff_t>(text[position] - '0'));
    }

    return negative ? -value : value;
  }

  template <Allocator Memory>
  void RadixNumber<Memory>::applyExponent(std::ptrdiff_t value) {
    if (radix_ == decimal_radix) {
      point_ += value;

      return;
    }

    auto whole = value / hexadecimal_bits;
    auto remainder = value % hexadecimal_bits;
    if (remainder < 0) {
      --whole;
      remainder += hexadecimal_bits;
    }

    point_ += whole;
    unsigned carry = 0;

    for (auto index = digits_.size(); index-- != 0;) {
      auto& digit = digits_.atMut(index);
      const auto product = (static_cast<unsigned>(digit_symbols.find(digit)) << static_cast<unsigned>(remainder)) + carry;

      digit = digit_symbols[product % radix_];
      carry = product / radix_;
    }

    if (carry != 0) {
      const char symbol = digit_symbols[carry];

      digits_.insert(0, {&symbol, 1});
      ++point_;
    }
  }

  template <Allocator Memory>
  void RadixNumber<Memory>::normalize() {
    const auto first = digits_.view().find_first_not_of('0');
    if (first == std::string_view::npos) {
      digits_.clear();
      point_ = 0;

      return;
    }

    digits_.remove(0, first);
    point_ -= static_cast<std::ptrdiff_t>(first);
    while (digits_.view().back() == '0') {
      digits_.truncate(digits_.size() - 1);
    }
  }

  template class RadixNumber<Memory>;
  template class RadixNumber<ConcurrentMemory>;

  template int RadixNumber<Memory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>&, bool) const noexcept;
  template int RadixNumber<Memory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::zero_half_exponent>&, bool) const noexcept;
  template int RadixNumber<ConcurrentMemory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>&, bool) const noexcept;
  template int RadixNumber<ConcurrentMemory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::zero_half_exponent>&, bool) const noexcept;

  bool JsonUnsignedInteger::integerSyntax(std::string_view text) noexcept {
    return text != "-0" && text.find_first_of(".eE") == std::string_view::npos;
  }

  template <std::unsigned_integral Number, Allocator Memory>
  tbc::val_a<Number> JsonUnsignedInteger::parse(tbc::mut_a<Memory> memory, std::string_view text, bool allow_float) {
    static_assert(std::numeric_limits<Number>::digits <= std::numeric_limits<std::uint16_t>::digits);

    const bool floating = !integerSyntax(text);
    if (floating && !allow_float) {
      invalid();
    }

    const RadixNumber<Memory> number{memory, text, floating};
    const auto maximum = static_cast<std::uint32_t>(std::numeric_limits<Number>::max());
    const auto integral = number.integerPart(maximum);

    if (number.integral()) {
      if (number.negative() && integral != 0) {
        invalid();
      }

      return static_cast<Number>(integral);
    }

    if (!floating) {
      invalid();
    }

    return static_cast<Number>(rounded(number, integral, maximum));
  }

  void JsonUnsignedInteger::invalid() {
    throw std::invalid_argument{"JSON number is not a representable unsigned integer"};
  }

  template <Allocator Memory>
  std::uint32_t JsonUnsignedInteger::rounded(const RadixNumber<Memory>& number, std::uint32_t integral, std::uint32_t maximum) {
    if (!number.negative()) {
      if (integral != 0) {
        const auto exponent = binary128_significand_bits + 1 - static_cast<unsigned>(std::bit_width(integral));
        const BinaryFraction<ordinary_half_exponent> upper{exponent, number.radix()};
        if (number.compareFraction(upper) <= 0) {
          return integral;
        }
      }

      if (integral < maximum) {
        const auto next = integral + 1;
        const auto exponent = binary128_significand_bits + 1 - static_cast<unsigned>(std::bit_width(next)) + static_cast<unsigned>(std::has_single_bit(next));
        const BinaryFraction<ordinary_half_exponent> lower{exponent, number.radix()};
        if (number.compareFraction(lower, true) >= 0) {
          return next;
        }
      }
    }

    if (integral == 0 && number.fractionLeadingZeros() >= (zero_half_exponent - 1) / hexadecimal_bits) {
      if (number.radix() == NumberRadix::decimal) {
        static const BinaryFraction<zero_half_exponent> zero{zero_half_exponent};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      } else {
        const BinaryFraction<zero_half_exponent> zero{zero_half_exponent, NumberRadix::hexadecimal};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      }
    }

    invalid();
  }

  template std::uint8_t JsonUnsignedInteger::parse<std::uint8_t, Memory>(Memory&, std::string_view, bool);
  template std::uint8_t JsonUnsignedInteger::parse<std::uint8_t, ConcurrentMemory>(ConcurrentMemory&, std::string_view, bool);
  template std::uint16_t JsonUnsignedInteger::parse<std::uint16_t, Memory>(Memory&, std::string_view, bool);
  template std::uint16_t JsonUnsignedInteger::parse<std::uint16_t, ConcurrentMemory>(ConcurrentMemory&, std::string_view, bool);

  MachineProfile MachineProfile::create(MachineId identity, MachineProfileFields fields) {
    if (identity.value() == 0) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineFieldRules::label(fields.label);
    MachineFieldRules::profileDestination(fields.destination);
    MachineProfile profile;

    profile.identity_ = identity;
    profile.label_.assign(fields.label);
    profile.destination_.assign(fields.destination);
    profile.enabled_ = fields.enabled;
    if (fields.color) {
      MachineFieldRules::color(*fields.color);
      profile.color_.assign(*fields.color);
    }

    if (fields.program) {
      profile.placeProgram(*fields.program);
    }

    return profile;
  }

  MachineId MachineProfile::identity() const noexcept {
    return identity_;
  }

  std::string_view MachineProfile::label() const noexcept {
    return label_.view();
  }

  std::string_view MachineProfile::destination() const noexcept {
    return destination_.view();
  }

  ds::Option<std::string_view> MachineProfile::color() const noexcept {
    return optional(color_.view());
  }

  ds::Option<std::string_view> MachineProfile::program() const noexcept {
    return optional(program_.view());
  }

  bool MachineProfile::enabled() const noexcept {
    return enabled_;
  }

  void MachineProfile::enable(bool enabled) noexcept {
    enabled_ = enabled;
  }

  void MachineProfile::relabel(std::string_view label) {
    MachineFieldRules::label(label);
    label_.assign(label);
  }

  void MachineProfile::placeProgram(std::string_view path) {
    MachineFieldRules::program(path);
    program_.assign(path);
  }

  void MachineProfile::recordLogin(MachineAgent agent, ds::Option<MachineLogin> login) {
    logins_.atCheckedMut(static_cast<std::size_t>(agent)) = login;
  }

  ds::Option<MachineLogin> MachineProfile::login(MachineAgent agent) const {
    return logins_.at(static_cast<std::size_t>(agent));
  }

  ds::Option<std::string_view> MachineProfile::optional(std::string_view value) noexcept {
    return value.empty() ? ds::none : ds::Option{value};
  }

  std::span<const MachineProfile> MachineProfiles::rows() const noexcept {
    return std::span{rows_}.first(length_);
  }

  ds::Option<std::string_view> MachineProfiles::localLabel() const noexcept {
    return local_label_.view().empty() ? ds::none : ds::Option{local_label_.view()};
  }

  void MachineProfiles::relabelLocal(std::string_view label) {
    MachineFieldRules::label(label);
    local_label_.assign(label);
  }

  ds::Option<std::size_t> MachineProfiles::find(std::string_view label) const noexcept {
    const auto found = std::ranges::find(rows(), label, &MachineProfile::label);

    return found == rows().end() ? ds::none : ds::Option{static_cast<std::size_t>(found - rows().begin())};
  }

  ds::Option<std::size_t> MachineProfiles::findDestination(std::string_view destination) const noexcept {
    const auto found = std::ranges::find(rows(), destination, &MachineProfile::destination);

    return found == rows().end() ? ds::none : ds::Option{static_cast<std::size_t>(found - rows().begin())};
  }

  void MachineProfiles::add(const MachineProfile& profile) {
    if (length_ == rows_.size()) {
      throw MachineFailure{MachineError::too_many};
    }

    requireFreeLabel(profile.label());
    for (const auto& existing : rows()) {
      if (existing.identity() == profile.identity()) {
        throw MachineFailure{MachineError::duplicate_id};
      }

      if (existing.destination() == profile.destination()) {
        throw MachineFailure{MachineError::duplicate_destination};
      }
    }

    rows_.atMut(length_) = profile;
    ++length_;
  }

  void MachineProfiles::remove(std::string_view label) {
    const auto position = require(label);

    for (auto index = position; index + 1 < length_; ++index) {
      rows_.atMut(index) = rows_[index + 1];
    }

    --length_;
  }

  void MachineProfiles::rename(std::string_view label, std::string_view replacement) {
    const auto position = require(label);

    if (label == replacement) {
      return;
    }

    requireFreeLabel(replacement);
    rows_.atMut(position).relabel(replacement);
  }

  void MachineProfiles::enable(std::string_view label, bool enabled) {
    rows_.atMut(require(label)).enable(enabled);
  }

  void MachineProfiles::recordLogin(std::string_view label, MachineAgent agent, MachineLogin login) {
    rows_.atMut(require(label)).recordLogin(agent, login);
  }

  void MachineProfiles::placeProgram(std::string_view label, std::string_view path) {
    rows_.atMut(require(label)).placeProgram(path);
  }

  std::uint16_t MachineProfiles::version() const {
    for (const auto& profile : rows()) {
      if (profile.program() || std::ranges::any_of(machine_agents, [&](MachineAgent agent) {
            return profile.login(agent).hasValue();
          })) {
        return extended_format_version;
      }
    }

    return plain_format_version;
  }

  std::size_t MachineProfiles::require(std::string_view label) const {
    const auto found = find(label);
    if (!found) {
      throw MachineFailure{MachineError::unknown_machine};
    }

    return *found;
  }

  void MachineProfiles::requireFreeLabel(std::string_view label) const {
    MachineFieldRules::label(label);
    if (find(label) || localLabel() == label) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  template <Allocator Memory>
  tbc::val_a<MachineProfiles> MachineProfileCodec::parse(tbc::mut_a<Memory> memory, std::string_view source) {
    try {
      validateUtf8(source);
      const runtime::JsonFields fields{memory, runtime::JsonValue::parse(source), file_fields};
      ds::String<Memory> scratch{memory};
      const auto version = readVersion(memory, fields.required("version"), scratch);

      validateOptionalString(fields.optional("local_label"), scratch);
      std::size_t count = 0;

      fields.required("machines").eachElement([&](const runtime::JsonValue& value) {
        validateProfile(memory, value, scratch);
        ++count;
      });

      if (version < MachineProfiles::plain_format_version || version > MachineProfiles::extended_format_version) {
        throw MachineFailure{MachineError::incompatible_profiles};
      }

      if (count > MachineLimits::profiles) {
        throw MachineFailure{MachineError::too_many};
      }

      MachineProfiles profiles;

      if (const auto& label = fields.optional("local_label"); label && !isNull(*label)) {
        label->string(scratch);
        profiles.relabelLocal(scratch);
      }

      fields.required("machines").eachElement([&](const runtime::JsonValue& value) {
        profiles.add(readProfile(memory, value));
      });

      return profiles;
    } catch (const std::bad_alloc&) {
      throw;
    } catch (const MachineFailure&) {
      throw;
    } catch (const std::exception&) {
      throw MachineFailure{MachineError::invalid_profiles};
    }
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> MachineProfileCodec::format(tbc::mut_a<Memory> memory, const MachineProfiles& profiles) {
    ds::String<Memory> output{memory};

    output.append(profiles.version() == MachineProfiles::plain_format_version ? "{\"version\":1" : "{\"version\":2");
    if (const auto label = profiles.localLabel()) {
      output.append(",\"local_label\":");
      runtime::appendJsonText(output, *label);
    }

    output.append(",\"machines\":[");
    bool first = true;

    for (const auto& profile : profiles.rows()) {
      output.append(first ? "\n  " : ",\n  ");
      first = false;
      appendProfile(output, profile);
    }

    if (!first) {
      output.push('\n');
    }

    output.append("]}\n");

    return output;
  }

  bool MachineProfileCodec::isNull(const runtime::JsonValue& value) noexcept {
    return value.encoded() == "null";
  }

  template <Allocator Memory>
  std::uint16_t MachineProfileCodec::readVersion(Memory& memory, const runtime::JsonValue& value, ds::String<Memory>& scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    return JsonUnsignedInteger::parse<std::uint16_t>(memory, text);
  }

  template <Allocator Memory>
  void MachineProfileCodec::validateOptionalString(const ds::Option<runtime::JsonValue>& value, ds::String<Memory>& scratch) {
    if (value && !isNull(*value)) {
      value->string(scratch);
    }
  }

  template <Allocator Memory>
  MachineLogin MachineProfileCodec::readLogin(const runtime::JsonValue& value, ds::String<Memory>& scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    auto const* const found = std::ranges::find(machine_login_names, text);
    if (found != machine_login_names.end()) {
      return static_cast<MachineLogin>(found - machine_login_names.begin());
    }

    const auto ordinal = JsonUnsignedInteger::parse<std::uint8_t>(scratch.memory(), text, false);
    if (ordinal >= machine_login_names.size()) {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    return static_cast<MachineLogin>(ordinal);
  }

  template <Allocator Memory>
  void MachineProfileCodec::validateProfile(Memory& memory, const runtime::JsonValue& value, ds::String<Memory>& scratch) {
    const runtime::JsonFields fields{memory, value, profile_fields};

    for (auto const* name : {"id", "label", "destination"}) {
      fields.required(name).string(scratch);
    }

    validateOptionalString(fields.optional("color"), scratch);
    validateOptionalString(fields.optional("telar_path"), scratch);
    if (const auto& enabled = fields.optional("enabled"); enabled && enabled->encoded() != "true" && enabled->encoded() != "false") {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    if (const auto& logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};

      for (const auto name : machine_agent_names) {
        if (const auto& login = values.optional(name); login && !isNull(*login)) {
          static_cast<void>(readLogin(*login, scratch));
        }
      }
    }
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> MachineProfileCodec::readString(tbc::mut_a<Memory> memory, const runtime::JsonValue& value) {
    ds::String<Memory> text{memory};

    value.string(text);

    return text;
  }

  template <Allocator Memory>
  MachineProfile MachineProfileCodec::readProfile(Memory& memory, const runtime::JsonValue& value) {
    runtime::JsonFields fields{memory, value, profile_fields};
    const auto identity = MachineId::parse(fields.string("id"));
    const auto label = readString(memory, fields.required("label"));
    const auto destination = readString(memory, fields.required("destination"));
    const auto& color_value = fields.optional("color");
    const auto color = color_value && !isNull(*color_value) ? ds::Option{readString(memory, *color_value)} : ds::none;
    const auto& program_value = fields.optional("telar_path");
    const auto program = program_value && !isNull(*program_value) ? ds::Option{readString(memory, *program_value)} : ds::none;
    const auto& enabled = fields.optional("enabled");
    auto profile = MachineProfile::create(identity, {
                                                        .label = label,
                                                        .destination = destination,
                                                        .color = color ? ds::Option<std::string_view>{*color} : ds::none,
                                                        .enabled = !enabled || enabled->boolean(),
                                                        .program = program ? ds::Option<std::string_view>{*program} : ds::none,
                                                    });

    if (const auto& logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};
      ds::String<Memory> scratch{memory};

      for (const auto agent : machine_agents) {
        const auto name = machine_agent_names.at(static_cast<std::size_t>(agent));
        if (const auto& login = values.optional(name); login && !isNull(*login)) {
          profile.recordLogin(agent, readLogin(*login, scratch));
        }
      }
    }

    return profile;
  }

  template <Allocator Memory>
  void MachineProfileCodec::appendProfile(ds::String<Memory>& output, const MachineProfile& profile) {
    output.append("{\"id\":");
    runtime::appendJsonText(output, profile.identity().format().view());
    output.append(",\"label\":");
    runtime::appendJsonText(output, profile.label());
    output.append(",\"destination\":");
    runtime::appendJsonText(output, profile.destination());
    if (const auto color = profile.color()) {
      output.append(",\"color\":");
      runtime::appendJsonText(output, *color);
    }

    output.append(profile.enabled() ? ",\"enabled\":true" : ",\"enabled\":false");
    if (const auto program = profile.program()) {
      output.append(",\"telar_path\":");
      runtime::appendJsonText(output, *program);
    }

    bool first = true;

    for (const auto agent : machine_agents) {
      const auto login = profile.login(agent);
      if (!login) {
        continue;
      }

      output.append(first ? ",\"logins\":{" : ",");
      first = false;
      runtime::appendJsonText(output, machine_agent_names.at(static_cast<std::size_t>(agent)));
      output.push(':');
      runtime::appendJsonText(output, machine_login_names.at(static_cast<std::size_t>(*login)));
    }

    output.append(first ? "}" : "}}");
  }

  template MachineProfiles MachineProfileCodec::parse<Memory>(Memory&, std::string_view);
  template MachineProfiles MachineProfileCodec::parse<ConcurrentMemory>(ConcurrentMemory&, std::string_view);
  template ds::String<Memory> MachineProfileCodec::format<Memory>(Memory&, const MachineProfiles&);
  template ds::String<ConcurrentMemory> MachineProfileCodec::format<ConcurrentMemory>(ConcurrentMemory&, const MachineProfiles&);
  template void MachineProfileCodec::appendProfile<Memory>(ds::String<Memory>&, const MachineProfile&);
  template void MachineProfileCodec::appendProfile<ConcurrentMemory>(ds::String<ConcurrentMemory>&, const MachineProfile&);

  MachineRemoteCommand::Text MachineRemoteCommand::discovery(ds::Option<std::string_view> program) {
    return format(discovery_prefix, program, discovery_suffix);
  }

  MachineRemoteCommand::Text MachineRemoteCommand::editor(ds::Option<std::string_view> program) {
    return format(editor_prefix, program, editor_suffix);
  }

  MachineRemoteCommand::Text MachineRemoteCommand::format(std::string_view prefix, ds::Option<std::string_view> program, std::string_view suffix) {
    if (program) {
      MachineFieldRules::program(*program);
    }

    Text command;

    command.append(prefix);
    command.append(program.valueOr("telar"));
    command.append(suffix);

    return command;
  }

}
