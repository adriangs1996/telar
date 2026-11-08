module;
#include "tbc/view.hpp"
#include "telar_client/codecs/telar_annotations.hpp"
#include <cstdio>
#include <cstdlib>

#include <cstddef>

#include <cstdint>


#include <cstring>




#include <new>

#include <cerrno>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

export module telar.client;

import std;

export import telar.base.text;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;

// The connection reports request failures with it; the rest of the protocol
// stays with telar.client.protocol.
export namespace telar::runtime {
using telar::runtime::RequestError;
}

// Interface: telar_client/serializers/telar_handshake.cppm
export {
namespace telar {

  using SchemaId = std::array<Byte, 8>;

  namespace handshake {

    inline constexpr std::array<Byte, 8> magic{
        'T',
        'E',
        'L',
        'A',
        'R',
        'I',
        'P',
        'C',
    };

    // Native control-query schema. Reject clients with the earlier frame
    // layout instead of interpreting their input-mode bytes at new offsets.
    inline constexpr SchemaId schema_id{'c', 'q', 'p', '0', '0', '0', '0', '1'};

  } // namespace handshake

  enum class HandshakeTag : Byte {
    client_hello = 1,
    server_accept = 2,
    server_reject = 3,
  };

  enum class HandshakeRejectReason : Byte {
    incompatible_schema = 1,
    client_limit_reached = 2,
  };

  struct ClientHello {
    SchemaId schema = handshake::schema_id;
  };

  struct ServerAccept {
    SchemaId schema;
  };

  struct ServerReject {
    HandshakeRejectReason reason;
    SchemaId expected_schema;
  };

  using HandshakeResponse = std::variant<ServerAccept, ServerReject>;

  struct HandshakeReasonByte {
    static constexpr std::size_t width = u8::width;

    inline static HandshakeRejectReason validate(HandshakeRejectReason reason) _throw(EncodingError) {
      switch (reason) {
      case HandshakeRejectReason::incompatible_schema:
      case HandshakeRejectReason::client_limit_reached:
        return reason;
      default:
        throw EncodingError{"Unknown handshake rejection reason"};
      }
    }

    inline static void encode(HandshakeRejectReason reason, std::span<Byte> &output)
        _throw(EncodingError) {
      u8::encode(static_cast<Byte>(validate(reason)), output);
    }

    inline static HandshakeRejectReason decode(std::span<const Byte> &input) _throw(EncodingError) {
      return validate(static_cast<HandshakeRejectReason>(u8::decode(input)));
    }
  };

  template <Direction Side, HandshakeTag Tag, typename... Fields>
  struct HandshakeLayout : Schema<Side, Tag, Fields...> {
    static constexpr auto magic = handshake::magic;
    static constexpr std::size_t payload_size =
        magic.size() + Schema<Side, Tag, Fields...>::payload_size;

#ifdef TELAR_DEBUG
    template <typename Message>
    static void pretty_print(const Message &message, std::FILE *output = stderr);
#endif
  };

  using SchemaIdCodec = FixedBytes<SchemaId{}.size()>;

  template <typename Message> struct HandshakeSchema;

  template <>
  struct HandshakeSchema<ClientHello>
      : HandshakeLayout<Direction::client,
                        HandshakeTag::client_hello,
                        Field<&ClientHello::schema, SchemaIdCodec, "schema">> {};

  template <>
  struct HandshakeSchema<ServerAccept>
      : HandshakeLayout<Direction::server,
                        HandshakeTag::server_accept,
                        Field<&ServerAccept::schema, SchemaIdCodec, "schema">> {};

  template <>
  struct HandshakeSchema<ServerReject>
      : HandshakeLayout<Direction::server,
                        HandshakeTag::server_reject,
                        Field<&ServerReject::reason, HandshakeReasonByte, "reason">,
                        Field<&ServerReject::expected_schema, SchemaIdCodec, "expected_schema">> {};

} // namespace telar
}

export {
namespace telar {

  struct HandshakeCodec {
    static constexpr std::size_t max_message_size = HandshakeSchema<ServerReject>::payload_size;

    template <typename Message> inline static auto encode(const Message &message) _throw(EncodingError) {
      using Sch = HandshakeSchema<Message>;
      std::array<Byte, Sch::payload_size> payload{};
      std::span<Byte> output = payload;

      FixedBytes<handshake::magic.size()>::encode(handshake::magic, output);
      u8::encode(static_cast<Byte>(Sch::tag), output);
      Sch::encodeBody(message, output);

      return payload;
    }

    template <typename Message>
    inline static Message decode(std::span<const Byte> input) _throw(EncodingError) {
      if (decodeHeader(input) != HandshakeSchema<Message>::tag) {
        throw EncodingError{"Unexpected handshake message"};
      }

      return decodeBody<Message>(input);
    }

    inline static HandshakeResponse decodeResponse(std::span<const Byte> input) _throw(EncodingError) {
      switch (decodeHeader(input)) {
      case HandshakeTag::server_accept:
        return decodeBody<ServerAccept>(input);
      case HandshakeTag::server_reject:
        return decodeBody<ServerReject>(input);
      default:
        throw EncodingError{"Unexpected handshake response"};
      }
    }

#ifdef TELAR_DEBUG
    template <typename Message>
    inline static void pretty_print(const Message &message, std::FILE *output = stderr) {
      const auto payload = encode(message);
      debug::printFrame<HandshakeSchema<Message>>(payload, output);
    }
#endif

  private:
    static constexpr std::size_t header_size = handshake::magic.size() + u8::width;

    inline static HandshakeTag decodeHeader(std::span<const Byte> &input) _throw(EncodingError) {
      if (input.size() < header_size) {
        throw EncodingError{"Invalid handshake response length"};
      }

      if (FixedBytes<handshake::magic.size()>::decode(input) != handshake::magic) {
        throw EncodingError{"Invalid handshake magic"};
      }

      const auto tag = static_cast<HandshakeTag>(u8::decode(input));
      switch (tag) {
      case HandshakeTag::client_hello:
      case HandshakeTag::server_accept:
      case HandshakeTag::server_reject:
        return tag;
      default:
        throw EncodingError{"Unknown handshake message tag"};
      }
    }

    template <typename Message>
    inline static Message decodeBody(std::span<const Byte> input) _throw(EncodingError) {
      using Sch = HandshakeSchema<Message>;
      if (input.size() != Sch::payload_size - header_size) {
        throw EncodingError{"Invalid handshake response length"};
      }

      Message message{};
      Sch::decodeBody(input, message);
      return message;
    }
  };

#ifdef TELAR_DEBUG
  template <Direction Side, HandshakeTag Tag, typename... Fields>
  template <typename Message>
  void HandshakeLayout<Side, Tag, Fields...>::pretty_print(const Message &message,
                                                           std::FILE *output) {
    HandshakeCodec::pretty_print(message, output);
  }
#endif

  static_assert(HandshakeSchema<ClientHello>::payload_size == 17);
  static_assert(HandshakeSchema<ServerAccept>::payload_size == 17);
  static_assert(HandshakeSchema<ServerReject>::payload_size == 18);

} // namespace telar
}

// Interface: telar_client/codecs.cppm
export {

}

// Interface: telar_client/machines/number_radix.cppm
export {
namespace telar::runtime::machines {

enum class NumberRadix : std::uint8_t {
  decimal = 10,
  hexadecimal = 16,
};

}
}

// Interface: telar_client/machines/binary_fraction.cppm
export {
namespace telar::runtime::machines {

template <std::size_t MaximumExponent>
class BinaryFraction {
public:
  inline explicit BinaryFraction(std::size_t exponent, NumberRadix radix = NumberRadix::decimal) {
    if (exponent == 0 || exponent > MaximumExponent) {
      throw std::out_of_range{"Binary fraction exponent exceeds capacity"};
    }

    if (radix == NumberRadix::hexadecimal) {
      length_ = (exponent + hexadecimal_bits - 1) / hexadecimal_bits;
      const auto trailing_bits = exponent % hexadecimal_bits;
      digits_[length_ - 1] = static_cast<std::uint8_t>(trailing_bits == 0 ? 1 : 1U << (hexadecimal_bits - trailing_bits));

      return;
    }

    if (radix != NumberRadix::decimal) {
      throw std::invalid_argument{"Unsupported binary fraction radix"};
    }

    length_ = exponent;
    deriveDecimal(exponent);
  }

  [[nodiscard]] inline unsigned digit(std::size_t position) const noexcept {
    return position < length_ ? digits_[position] : 0;
  }

  [[nodiscard]] inline unsigned complementDigit(std::size_t position, NumberRadix radix) const noexcept {
    if (position >= length_) {
      return 0;
    }

    return static_cast<unsigned>(radix) - digit(position) - static_cast<unsigned>(position + 1 < length_);
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return length_;
  }

private:
  static constexpr unsigned decimal_radix = 10;
  static constexpr unsigned hexadecimal_bits = 4;
  static constexpr unsigned decimal_limb_digits = 9;
  static constexpr std::uint64_t decimal_limb_base = 1'000'000'000;
  static constexpr std::uint64_t half_decimal_radix = decimal_radix / 2;
  static constexpr std::size_t limb_capacity = ((MaximumExponent + decimal_limb_digits - 1) / decimal_limb_digits) + 1;

  inline void deriveDecimal(std::size_t exponent) {
    std::array<std::uint32_t, limb_capacity> limbs{};
    limbs.front() = 1;
    std::size_t count = 1;
    for (std::size_t power = 0; power < exponent; ++power) {
      std::uint64_t carry = 0;
      for (auto &limb : std::span{limbs}.first(count)) {
        const auto product = (static_cast<std::uint64_t>(limb) * half_decimal_radix) + carry;
        limb = static_cast<std::uint32_t>(product % decimal_limb_base);
        carry = product / decimal_limb_base;
      }

      if (carry != 0) {
        limbs[count++] = static_cast<std::uint32_t>(carry);
      }
    }

    auto position = exponent;
    for (auto limb : std::span{limbs}.first(count)) {
      for (unsigned digit = 0; digit < decimal_limb_digits && position != 0; ++digit) {
        digits_[--position] = static_cast<std::uint8_t>(limb % decimal_radix);
        limb /= decimal_radix;
      }
    }
  }

  std::array<std::uint8_t, MaximumExponent> digits_{};
  std::size_t length_ = 0;
};

}
}

// Interface: telar_client/machines/bounded_text.cppm
export {
namespace telar::runtime::machines {

template <std::size_t Capacity>
class BoundedText {
public:
  inline void append(std::string_view text) {
    if (text.size() > Capacity - length_) {
      throw std::length_error{"Text capacity exceeded"};
    }

    if (!text.empty()) {
      std::memmove(storage_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  template <std::unsigned_integral Number>
  inline void appendDecimal(Number number) {
    const auto result = std::to_chars(storage_.data() + length_, storage_.data() + Capacity, number);
    if (result.ec != std::errc{}) {
      throw std::length_error{"Text capacity exceeded"};
    }

    length_ = static_cast<std::size_t>(result.ptr - storage_.data());
  }

  inline void truncate(std::size_t length) {
    if (length > length_) {
      throw std::out_of_range{"Text truncation exceeds length"};
    }

    length_ = length;
  }

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {storage_.data(), length_};
  }

private:
  std::array<char, Capacity> storage_{};
  std::size_t length_ = 0;
};

}
}

// Interface: telar_client/machines/failure.cppm
export {
namespace telar::runtime::machines {

enum class MachineError : std::uint8_t {
  invalid_id,
  invalid_label,
  invalid_destination,
  invalid_color,
  invalid_program,
  invalid_profiles,
  incompatible_profiles,
  too_many,
  duplicate_id,
  duplicate_label,
  duplicate_destination,
  unknown_machine,
  discovery_unreadable,
  host_key_rejected,
  authentication_failed,
  remote_program_missing,
  remote_program_incompatible,
  remote_runtime_incompatible,
  endpoint_unavailable,
  incompatible_schema,
  runtime_already_running,
  invalid_runtime_directory,
};

class MachineFailure final : public std::runtime_error {
public:
  inline explicit MachineFailure(MachineError code)
      : std::runtime_error(name(code)),
        code_(code) {}

  [[nodiscard]] inline MachineError code() const noexcept {
    return code_;
  }

  [[nodiscard]] inline static const char *name(MachineError code) {
    static constexpr std::array names{
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
        "SshHostKeyRejected",
        "SshAuthenticationFailed",
        "RemoteTelarMissing",
        "RemoteTelarIncompatible",
        "RemoteRuntimeIncompatible",
        "RemoteEndpointUnavailable",
        "IncompatibleSchema",
        "RuntimeAlreadyRunning",
        "InvalidRuntimeDirectory",
    };

    return names.at(static_cast<std::size_t>(code));
  }

private:
  MachineError code_;
};

}
}

// Interface: telar_client/machines/discovery.cppm
export {
namespace telar::runtime::machines {

template <std::size_t MaximumPathBytes>
class MachineDiscovery {
public:
  static constexpr std::size_t path_count = 3;
  static constexpr std::size_t max_output_bytes = (path_count * (MaximumPathBytes + 1)) + SchemaId{}.size() + 1;

  [[nodiscard]] inline static MachineDiscovery parse(std::string_view output) {
    if (output.size() > max_output_bytes) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    MachineDiscovery result;
    const std::array paths{&result.home_, &result.shell_, &result.endpoint_};
    for (auto *const path : paths) {
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

    std::memcpy(result.schema_.data(), output.data(), result.schema_.size());

    return result;
  }

  [[nodiscard]] inline std::string_view home() const noexcept {
    return home_.view();
  }

  [[nodiscard]] inline std::string_view shell() const noexcept {
    return shell_.view();
  }

  [[nodiscard]] inline std::string_view endpoint() const noexcept {
    return endpoint_.view();
  }

  [[nodiscard]] inline const SchemaId &schema() const noexcept {
    return schema_;
  }

  [[nodiscard]] inline bool compatible(const SchemaId &expected = handshake::schema_id) const noexcept {
    return schema_ == expected;
  }

private:
  inline static bool asciiAlphanumeric(char character) noexcept {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9');
  }

  inline static void validatePath(std::string_view path, bool socket_path) {
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

  runtime::FixedText<MaximumPathBytes> home_;
  runtime::FixedText<MaximumPathBytes> shell_;
  runtime::FixedText<MaximumPathBytes> endpoint_;
  SchemaId schema_{};
};

}
}

// Interface: telar_client/machines/limits.cppm
export {
namespace telar::runtime::machines {

struct MachineLimits {
  static constexpr std::size_t profiles = 16;
  static constexpr std::size_t window_slots = profiles + 1;
  static constexpr std::size_t label_bytes = 32;
  static constexpr std::size_t destination_bytes = 255;
  static constexpr std::size_t color_bytes = 24;
  static constexpr std::size_t program_bytes = 255;
  static constexpr std::size_t file_bytes = std::size_t{32} * 1024;
  static constexpr std::size_t failure_bytes = 256;
};

}
}

// Interface: telar_client/machines/field_rules.cppm
export {
namespace telar::runtime::machines {

struct MachineFieldRules {
  inline static void label(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::label_bytes || !alphanumeric(text.front()) || !std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '.' || byte == '_' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_label};
    }
  }

  inline static void destination(std::string_view text) {
    if (text.empty() || text.front() == '-' || std::ranges::any_of(text, [](unsigned char byte) {
          return byte <= ' ' || byte == delete_byte;
        })) {
      throw MachineFailure{MachineError::invalid_destination};
    }
  }

  inline static void profileDestination(std::string_view text) {
    if (text.size() > MachineLimits::destination_bytes || inspectUtf8(text) != Utf8Validation::valid) {
      throw MachineFailure{MachineError::invalid_destination};
    }

    destination(text);
  }

  inline static void color(std::string_view text) {
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

  inline static void program(std::string_view text) {
    if (text.size() < minimum_program_bytes || text.size() > MachineLimits::program_bytes || text.front() != '/' || text.back() == '/' || text.contains("/../") || text.ends_with("/..")) {
      throw MachineFailure{MachineError::invalid_program};
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '/' || byte == '.' || byte == '_' || byte == '+' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_program};
    }
  }

private:
  static constexpr unsigned char delete_byte = 0x7f;
  static constexpr std::size_t minimum_program_bytes = 2;

  inline static bool decimal(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  inline static bool alphanumeric(char byte) noexcept {
    return decimal(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }
};

}
}

// Interface: telar_client/machines/identity.cppm
export {
namespace telar::runtime::machines {

template <typename Random>
concept MachineIdentityRandom = requires(Random &random, std::span<std::uint8_t> bytes) {
  { random.fill(bytes) } -> std::same_as<void>;
};

class MachineId {
public:
  static constexpr std::string_view prefix = "m-";
  static constexpr std::size_t hex_digits = 12;
  static constexpr std::size_t text_bytes = prefix.size() + hex_digits;
  static constexpr unsigned bits_per_digit = 4;
  static constexpr unsigned value_bits = hex_digits * bits_per_digit;
  static constexpr auto maximum_value = (std::uint64_t{1} << value_bits) - 1;

  [[nodiscard]] inline static MachineId fromRaw(std::uint64_t value) {
    if (value == 0 || value > maximum_value) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineId identity;
    identity.value_ = value;

    return identity;
  }

  [[nodiscard]] inline static MachineId parse(std::string_view text) {
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

  template <MachineIdentityRandom Random>
  [[nodiscard]] inline static MachineId generate(Random &random) {
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned entropy_bits = sizeof(std::uint64_t) * bits_per_byte;
    for (;;) {
      std::array<std::uint8_t, sizeof(std::uint64_t)> bytes{};
      random.fill(bytes);
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

  [[nodiscard]] inline BoundedText<text_bytes> format() const {
    BoundedText<text_bytes> text;
    text.append(prefix);
    for (std::size_t position = hex_digits; position != 0; --position) {
      const auto shift = (position - 1) * bits_per_digit;
      text.append(digits.substr((value_ >> shift) & digit_mask, 1));
    }

    return text;
  }

  [[nodiscard]] inline std::uint64_t value() const noexcept {
    return value_;
  }

  bool operator==(const MachineId &) const = default;

private:
  static constexpr std::string_view digits = "0123456789abcdef";
  static constexpr auto digit_mask = (std::uint64_t{1} << bits_per_digit) - 1;
  std::uint64_t value_ = 0;
};

}
}

// Interface: telar_client/machines/radix_number.cppm
export {
namespace telar::runtime::machines {

template <Allocator Memory>
class RadixNumber {
public:
  static constexpr unsigned decimal_radix = static_cast<unsigned>(NumberRadix::decimal);
  static constexpr unsigned hexadecimal_radix = static_cast<unsigned>(NumberRadix::hexadecimal);
  static constexpr unsigned hexadecimal_bits = 4;

  inline RadixNumber(Memory &memory, std::string_view text, bool floating_syntax)
      : digits_(AllocatorRef<char, Memory>{memory}) {
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

  [[nodiscard]] inline bool negative() const noexcept {
    return negative_;
  }

  [[nodiscard]] inline NumberRadix radix() const noexcept {
    return static_cast<NumberRadix>(radix_);
  }

  [[nodiscard]] inline bool zero() const noexcept {
    return digits_.empty();
  }

  [[nodiscard]] inline bool integral() const noexcept {
    return point_ >= static_cast<std::ptrdiff_t>(digits_.size());
  }

  [[nodiscard]] inline std::size_t fractionLeadingZeros() const noexcept {
    return point_ < 0 ? static_cast<std::size_t>(-point_) : 0;
  }

  [[nodiscard]] inline std::uint32_t integerPart(std::uint32_t maximum) const {
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

  template <typename Fraction>
  [[nodiscard]] inline int compareFraction(const Fraction &threshold, bool complement = false) const noexcept {
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

private:
  static constexpr std::string_view digit_symbols = "0123456789abcdef";
  static constexpr std::size_t hexadecimal_prefix_bytes = 2;
  static constexpr std::ptrdiff_t minimum_exponent_budget = 20'000;

  [[noreturn]] static void invalid() {
    throw std::invalid_argument{"Invalid numeric text"};
  }

  [[nodiscard]] unsigned digitAt(std::ptrdiff_t position) const noexcept {
    return position < 0 || position >= static_cast<std::ptrdiff_t>(digits_.size()) ? 0 : static_cast<unsigned>(digit_symbols.find(digits_[static_cast<std::size_t>(position)]));
  }

  static bool validDigit(char byte, unsigned radix) noexcept {
    return digit_symbols.find(runtime::asciiLower(byte)) < radix;
  }

  void readMantissa(std::string_view text, bool floating_syntax) {
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

      digits_.push_back(runtime::asciiLower(byte));
      if (!point_seen) {
        ++point_;
      }
    }

    if (digits_.empty()) {
      invalid();
    }
  }

  static std::ptrdiff_t exponent(std::string_view text, std::size_t source_bytes) {
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

  void applyExponent(std::ptrdiff_t value) {
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
    for (auto digit = digits_.rbegin(); digit != digits_.rend(); ++digit) {
      const auto product = (static_cast<unsigned>(digit_symbols.find(*digit)) << static_cast<unsigned>(remainder)) + carry;
      *digit = digit_symbols[product % radix_];
      carry = product / radix_;
    }

    if (carry != 0) {
      digits_.insert(digits_.begin(), digit_symbols[carry]);
      ++point_;
    }
  }

  void normalize() {
    const auto first = digits_.find_first_not_of('0');
    if (first == std::string_view::npos) {
      digits_.clear();
      point_ = 0;

      return;
    }

    digits_.erase(0, first);
    point_ -= static_cast<std::ptrdiff_t>(first);
    while (digits_.back() == '0') {
      digits_.pop_back();
    }
  }

  String<Memory> digits_;
  std::ptrdiff_t point_ = 0;
  unsigned radix_ = decimal_radix;
  bool negative_ = false;
};

}
}

// Interface: telar_client/machines/json_unsigned_integer.cppm
export {
namespace telar::runtime::machines {

struct JsonUnsignedInteger {
  static constexpr unsigned binary128_significand_bits = 113;
  static constexpr unsigned binary128_minimum_normal_exponent = 16382;
  static constexpr unsigned zero_half_exponent = binary128_minimum_normal_exponent + binary128_significand_bits;
  static constexpr unsigned ordinary_half_exponent = binary128_significand_bits + 1;
  static constexpr unsigned hexadecimal_bits = 4;

  [[nodiscard]] inline static bool integerSyntax(std::string_view text) noexcept {
    return text != "-0" && text.find_first_of(".eE") == std::string_view::npos;
  }

  template <std::unsigned_integral Number, Allocator Memory>
  [[nodiscard]] inline static Number parse(Memory &memory, std::string_view text, bool allow_float = true) {
    static_assert(std::numeric_limits<Number>::digits <= std::numeric_limits<std::uint16_t>::digits);

    const bool floating = !integerSyntax(text);
    if (floating && !allow_float) {
      invalid();
    }

    const RadixNumber number{memory, text, floating};
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

private:
  [[noreturn]] inline static void invalid() {
    throw std::invalid_argument{"JSON number is not a representable unsigned integer"};
  }

  template <Allocator Memory>
  inline static std::uint32_t rounded(const RadixNumber<Memory> &number, std::uint32_t integral, std::uint32_t maximum) {
    if (!number.negative()) {
      if (integral != 0) {
        const auto exponent = binary128_significand_bits - (std::bit_width(integral) - 1);
        const BinaryFraction<ordinary_half_exponent> upper{exponent, number.radix()};
        if (number.compareFraction(upper) <= 0) {
          return integral;
        }
      }

      if (integral < maximum) {
        const auto next = integral + 1;
        const auto exponent = binary128_significand_bits - (std::bit_width(next) - 1) + static_cast<unsigned>(std::has_single_bit(next));
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
};

}
}

// Interface: telar_client/machines/profile.cppm
export {
namespace telar::runtime::machines {

enum class MachineLogin : std::uint8_t {
  pending,
  done,
  failed,
};
enum class MachineAgent : std::uint8_t {
  claude,
  codex,
  pi,
  cursor,
  opencode,
};

inline constexpr std::array machine_agents{MachineAgent::claude, MachineAgent::codex, MachineAgent::pi, MachineAgent::cursor, MachineAgent::opencode};
inline constexpr std::array<std::string_view, machine_agents.size()> machine_agent_names{"claude", "codex", "pi", "cursor", "opencode"};
inline constexpr auto machine_login_names = std::to_array<std::string_view>({"pending", "done", "failed"});

struct MachineProfileFields {
  std::string_view label;
  std::string_view destination;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  std::optional<std::string_view> program = std::nullopt;
};

class MachineProfile {
public:
  [[nodiscard]] inline static MachineProfile create(MachineId identity, MachineProfileFields fields) {
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

  [[nodiscard]] inline MachineId identity() const noexcept {
    return identity_;
  }

  [[nodiscard]] inline std::string_view label() const noexcept {
    return label_.view();
  }

  [[nodiscard]] inline std::string_view destination() const noexcept {
    return destination_.view();
  }

  [[nodiscard]] inline std::optional<std::string_view> color() const noexcept {
    return optional(color_.view());
  }

  [[nodiscard]] inline std::optional<std::string_view> program() const noexcept {
    return optional(program_.view());
  }

  [[nodiscard]] inline bool enabled() const noexcept {
    return enabled_;
  }

  inline void enable(bool enabled) noexcept {
    enabled_ = enabled;
  }

  inline void relabel(std::string_view label) {
    MachineFieldRules::label(label);
    label_.assign(label);
  }

  inline void placeProgram(std::string_view path) {
    MachineFieldRules::program(path);
    program_.assign(path);
  }

  inline void recordLogin(MachineAgent agent, std::optional<MachineLogin> login) {
    logins_.at(static_cast<std::size_t>(agent)) = login;
  }

  [[nodiscard]] inline std::optional<MachineLogin> login(MachineAgent agent) const {
    return logins_.at(static_cast<std::size_t>(agent));
  }

private:
  inline static std::optional<std::string_view> optional(std::string_view value) noexcept {
    return value.empty() ? std::nullopt : std::optional{value};
  }

  MachineId identity_;
  runtime::FixedText<MachineLimits::label_bytes> label_;
  runtime::FixedText<MachineLimits::destination_bytes> destination_;
  runtime::FixedText<MachineLimits::color_bytes> color_;
  runtime::FixedText<MachineLimits::program_bytes> program_;
  std::array<std::optional<MachineLogin>, machine_agents.size()> logins_{};
  bool enabled_ = true;
};

}
}

// Interface: telar_client/machines/profiles.cppm
export {
namespace telar::runtime::machines {

class MachineProfiles {
public:
  static constexpr std::uint16_t plain_format_version = 1;
  static constexpr std::uint16_t extended_format_version = 2;

  [[nodiscard]] inline std::span<const MachineProfile> rows() const noexcept {
    return std::span{rows_}.first(length_);
  }

  [[nodiscard]] inline std::optional<std::string_view> localLabel() const noexcept {
    return local_label_.view().empty() ? std::nullopt : std::optional{local_label_.view()};
  }

  inline void relabelLocal(std::string_view label) {
    MachineFieldRules::label(label);
    local_label_.assign(label);
  }

  [[nodiscard]] inline std::optional<std::size_t> find(std::string_view label) const noexcept {
    const auto found = std::ranges::find(rows(), label, &MachineProfile::label);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  [[nodiscard]] inline std::optional<std::size_t> findDestination(std::string_view destination) const noexcept {
    const auto found = std::ranges::find(rows(), destination, &MachineProfile::destination);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  inline void add(const MachineProfile &profile) {
    if (length_ == rows_.size()) {
      throw MachineFailure{MachineError::too_many};
    }

    requireFreeLabel(profile.label());
    for (const auto &existing : rows()) {
      if (existing.identity() == profile.identity()) {
        throw MachineFailure{MachineError::duplicate_id};
      }

      if (existing.destination() == profile.destination()) {
        throw MachineFailure{MachineError::duplicate_destination};
      }
    }

    rows_[length_] = profile;
    ++length_;
  }

  inline void remove(std::string_view label) {
    const auto position = require(label);
    for (auto index = position; index + 1 < length_; ++index) {
      rows_[index] = rows_[index + 1];
    }

    --length_;
  }

  inline void rename(std::string_view label, std::string_view replacement) {
    const auto position = require(label);
    if (label == replacement) {
      return;
    }

    requireFreeLabel(replacement);
    rows_[position].relabel(replacement);
  }

  inline void enable(std::string_view label, bool enabled) {
    rows_[require(label)].enable(enabled);
  }

  inline void recordLogin(std::string_view label, MachineAgent agent, MachineLogin login) {
    rows_[require(label)].recordLogin(agent, login);
  }

  inline void placeProgram(std::string_view label, std::string_view path) {
    rows_[require(label)].placeProgram(path);
  }

  [[nodiscard]] inline std::uint16_t version() const {
    for (const auto &profile : rows()) {
      if (profile.program() || std::ranges::any_of(machine_agents, [&](MachineAgent agent) {
            return profile.login(agent).has_value();
          })) {
        return extended_format_version;
      }
    }

    return plain_format_version;
  }

private:
  [[nodiscard]] inline std::size_t require(std::string_view label) const {
    const auto found = find(label);
    if (!found) {
      throw MachineFailure{MachineError::unknown_machine};
    }

    return *found;
  }

  inline void requireFreeLabel(std::string_view label) const {
    MachineFieldRules::label(label);
    if (find(label) || localLabel() == label) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  std::array<MachineProfile, MachineLimits::profiles> rows_;
  runtime::FixedText<MachineLimits::label_bytes> local_label_;
  std::size_t length_ = 0;
};

}
}

// Interface: telar_client/machines/profile_codec.cppm
export {
namespace telar::runtime::machines {

struct MachineProfileCodec {
  template <Allocator Memory>
  [[nodiscard]] inline static MachineProfiles parse(Memory &memory, std::string_view source) {
    try {
      validateUtf8(source);
      const runtime::JsonFields fields{memory, runtime::JsonValue::parse(source), file_fields};
      String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
      const auto version = readVersion(memory, fields.required("version"), scratch);
      validateOptionalString(fields.optional("local_label"), scratch);
      std::size_t count = 0;
      fields.required("machines").eachElement([&](const runtime::JsonValue &value) {
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
      if (const auto &label = fields.optional("local_label"); label && !isNull(*label)) {
        label->string(scratch);
        profiles.relabelLocal(scratch);
      }

      fields.required("machines").eachElement([&](const runtime::JsonValue &value) {
        profiles.add(readProfile(memory, value));
      });

      return profiles;
    } catch (const std::bad_alloc &) {
      throw;
    } catch (const MachineFailure &) {
      throw;
    } catch (const std::exception &) {
      throw MachineFailure{MachineError::invalid_profiles};
    }
  }

  template <Allocator Memory>
  [[nodiscard]] inline static String<Memory> format(Memory &memory, const MachineProfiles &profiles) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += profiles.version() == MachineProfiles::plain_format_version ? "{\"version\":1" : "{\"version\":2";
    if (const auto label = profiles.localLabel()) {
      output += ",\"local_label\":";
      runtime::appendJsonString(output, *label);
    }

    output += ",\"machines\":[";
    bool first = true;
    for (const auto &profile : profiles.rows()) {
      output += first ? "\n  " : ",\n  ";
      first = false;
      appendProfile(output, profile);
    }

    if (!first) {
      output += '\n';
    }

    output += "]}\n";

    return output;
  }

private:
  static constexpr auto file_fields = std::to_array<std::string_view>({"version", "local_label", "machines"});
  static constexpr auto profile_fields = std::to_array<std::string_view>({"id", "label", "destination", "color", "enabled", "telar_path", "logins"});

  inline static bool isNull(const runtime::JsonValue &value) noexcept {
    return value.encoded() == "null";
  }

  template <Allocator Memory>
  inline static std::uint16_t readVersion(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    return JsonUnsignedInteger::parse<std::uint16_t>(memory, text);
  }

  template <Allocator Memory>
  inline static void validateOptionalString(const std::optional<runtime::JsonValue> &value, String<Memory> &scratch) {
    if (value && !isNull(*value)) {
      value->string(scratch);
    }
  }

  template <Allocator Memory>
  inline static MachineLogin readLogin(const runtime::JsonValue &value, String<Memory> &scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    auto const *const found = std::ranges::find(machine_login_names, text);
    if (found != machine_login_names.end()) {
      return static_cast<MachineLogin>(found - machine_login_names.begin());
    }

    const auto ordinal = JsonUnsignedInteger::parse<std::uint8_t>(scratch.get_allocator().memory(), text, false);
    if (ordinal >= machine_login_names.size()) {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    return static_cast<MachineLogin>(ordinal);
  }

  template <Allocator Memory>
  inline static void validateProfile(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
    const runtime::JsonFields fields{memory, value, profile_fields};
    for (auto const *name : {"id", "label", "destination"}) {
      fields.required(name).string(scratch);
    }

    validateOptionalString(fields.optional("color"), scratch);
    validateOptionalString(fields.optional("telar_path"), scratch);
    if (const auto &enabled = fields.optional("enabled"); enabled && enabled->encoded() != "true" && enabled->encoded() != "false") {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    if (const auto &logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};
      for (const auto name : machine_agent_names) {
        if (const auto &login = values.optional(name); login && !isNull(*login)) {
          static_cast<void>(readLogin(*login, scratch));
        }
      }
    }
  }

  template <Allocator Memory>
  inline static String<Memory> readString(Memory &memory, const runtime::JsonValue &value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    value.string(text);

    return text;
  }

  template <Allocator Memory>
  inline static MachineProfile readProfile(Memory &memory, const runtime::JsonValue &value) {
    runtime::JsonFields fields{memory, value, profile_fields};
    const auto identity = MachineId::parse(fields.string("id"));
    const auto label = readString(memory, fields.required("label"));
    const auto destination = readString(memory, fields.required("destination"));
    const auto &color_value = fields.optional("color");
    const auto color = color_value && !isNull(*color_value) ? std::optional{readString(memory, *color_value)} : std::nullopt;
    const auto &program_value = fields.optional("telar_path");
    const auto program = program_value && !isNull(*program_value) ? std::optional{readString(memory, *program_value)} : std::nullopt;
    const auto &enabled = fields.optional("enabled");
    auto profile = MachineProfile::create(identity, {
                                                        .label = label,
                                                        .destination = destination,
                                                        .color = color ? std::optional<std::string_view>{*color} : std::nullopt,
                                                        .enabled = !enabled || enabled->boolean(),
                                                        .program = program ? std::optional<std::string_view>{*program} : std::nullopt,
                                                    });
    if (const auto &logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};
      String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
      for (const auto agent : machine_agents) {
        const auto name = machine_agent_names.at(static_cast<std::size_t>(agent));
        if (const auto &login = values.optional(name); login && !isNull(*login)) {
          profile.recordLogin(agent, readLogin(*login, scratch));
        }
      }
    }

    return profile;
  }

public:
  template <Allocator Memory>
  inline static void appendProfile(String<Memory> &output, const MachineProfile &profile) {
    output += "{\"id\":";
    runtime::appendJsonString(output, profile.identity().format().view());
    output += ",\"label\":";
    runtime::appendJsonString(output, profile.label());
    output += ",\"destination\":";
    runtime::appendJsonString(output, profile.destination());
    if (const auto color = profile.color()) {
      output += ",\"color\":";
      runtime::appendJsonString(output, *color);
    }

    output += profile.enabled() ? ",\"enabled\":true" : ",\"enabled\":false";
    if (const auto program = profile.program()) {
      output += ",\"telar_path\":";
      runtime::appendJsonString(output, *program);
    }

    bool first = true;
    for (const auto agent : machine_agents) {
      const auto login = profile.login(agent);
      if (!login) {
        continue;
      }

      output += first ? ",\"logins\":{" : ",";
      first = false;
      runtime::appendJsonString(output, machine_agent_names.at(static_cast<std::size_t>(agent)));
      output += ':';
      runtime::appendJsonString(output, machine_login_names.at(static_cast<std::size_t>(*login)));
    }

    output += first ? "}" : "}}";
  }
};

}
}

// Interface: telar_client/machines/remote_command.cppm
export {
namespace telar::runtime::machines {

class MachineRemoteCommand {
  static constexpr std::string_view discovery_prefix = R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec )";
  static constexpr std::string_view discovery_suffix = " server endpoint'";
  static constexpr std::string_view bridge_prefix = "exec ";
  static constexpr std::string_view bridge_suffix = " server bridge";

public:
  static constexpr std::size_t max_bytes = discovery_prefix.size() + MachineLimits::program_bytes + discovery_suffix.size();
  using Text = BoundedText<max_bytes>;

  [[nodiscard]] inline static Text discovery(std::optional<std::string_view> program = std::nullopt) {
    return format(discovery_prefix, program, discovery_suffix);
  }

  [[nodiscard]] inline static Text bridge(std::optional<std::string_view> program = std::nullopt) {
    return format(bridge_prefix, program, bridge_suffix);
  }

private:
  inline static Text format(std::string_view prefix, std::optional<std::string_view> program, std::string_view suffix) {
    if (program) {
      MachineFieldRules::program(*program);
    }

    Text command;
    command.append(prefix);
    command.append(program.value_or("telar"));
    command.append(suffix);

    return command;
  }
};

}
}

// Interface: telar_client/serializers.cppm
export {

}

// Interface: telar_client/telar_client.cppm
export {
namespace telar {

  struct SocketError final : std::exception {
    inline SocketError(const char *message)
        : message{message} {}

    inline const char *what() const noexcept override {
      return message;
    }

  private:
    const char *message;
  };

  class Client final {
  public:
    inline static Client init(const char *socket_path) _throw(SocketError) {
      Client client{};
      client._address.sun_family = AF_UNIX;

      const auto path_length = std::strlen(socket_path);
      if (path_length >= sizeof(client._address.sun_path)) {
        throw SocketError{"Socket path too long"};
      }

      std::memcpy(client._address.sun_path, socket_path, path_length + 1);

      client._fd = socket(AF_UNIX, SOCK_STREAM, 0);
      if (client._fd < 0) {
        throw SocketError{"Error opening socket"};
      }

      if (setsockopt(client._fd, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout)) < 0) {
        client.deinit();
        throw SocketError{"Error configuring runtime I/O timeout"};
      }

#ifdef SO_NOSIGPIPE
      const int enabled = 1;
      if (setsockopt(client._fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
        client.deinit();
        throw SocketError{"Error configuring socket"};
      }
#endif

      auto address_ptr = reinterpret_cast<sockaddr *>(&client._address);
      while (connect(client._fd, address_ptr, sizeof(client._address)) < 0) {
        if (errno == EINTR) {
          continue;
        }

        client.deinit();
        throw SocketError{"Error connecting"};
      }

      return client;
    }

    inline void handshake() _throw(std::exception) {
      timeval timeout{
          .tv_sec = 30,
          .tv_usec = 0,
      };

      if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        throw SocketError{"Error enabling runtime receive timeout for handshake"};
      }

      try {
        const ClientHello request{};
        sendFrame(HandshakeCodec::encode(request));

        std::array<Byte, HandshakeCodec::max_message_size> buffer{};
        const auto response = HandshakeCodec::decodeResponse(receiveFrame(buffer));

        if (const auto *accepted = std::get_if<ServerAccept>(&response)) {
          if (accepted->schema != request.schema) {
            throw SocketError{"Runtime accepted an unexpected wire schema"};
          }

          timeout.tv_sec = 0;
          if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
            throw SocketError{"Error disabling runtime receive timeout"};
          }

          return;
        }

        switch (std::get<ServerReject>(response).reason) {
        case HandshakeRejectReason::incompatible_schema:
          throw SocketError{"Runtime rejected the wire schema"};
        case HandshakeRejectReason::client_limit_reached:
          throw SocketError{"Runtime client limit reached"};
        }
      } catch (...) {
        deinit();
        throw;
      }
    }

    inline void deinit() {
      if (_fd >= 0) {
        close(_fd);
        _fd = -1;
      }
    }

    template <typename Message> inline void send(const Message &message) {
      using Schema = MessageSchema<Message>;
      static_assert(Schema::direction == Direction::client, "Can only send Client Messages");

      sendFrame(Codec::encode(message));
    }

    template <typename Message> inline void send(const Message &message, std::span<Byte> frame_buffer) {
      static_assert(MessageSchema<Message>::direction == Direction::client,
                    "Can only send Client Messages");
      if (frame_buffer.size() < frame_prefix_size) {
        throw EncodingError{"Frame buffer too small"};
      }

      const auto payload = Codec::encode(message, frame_buffer.subspan(frame_prefix_size));
      auto prefix = frame_buffer.first(frame_prefix_size);
      u32::encode(static_cast<std::uint32_t>(payload.size()), prefix);
      writeAll(frame_buffer.data(), frame_prefix_size + payload.size());
    }

    inline tbc::view<std::span<const Byte>, tbc::lt::a> receiveFrame(tbc::view<std::span<Byte>, tbc::lt::a> buffer) _throw(SocketError) {
      std::array<Byte, frame_prefix_size> prefix{};
      readAll(prefix.data(), prefix.size());

      std::span<const Byte> input = prefix;
      const auto length = u32::decode(input);
      if (length == 0 || length > max_payload_size || length > buffer.size()) {
        throw SocketError{"Invalid runtime frame length"};
      }

      readAll(buffer.data(), length);
      return buffer.first(length);
    }

    inline void interruptRead() const noexcept {
      if (_fd < 0) {
        return;
      }

      int result;

      do {
        result = ::shutdown(_fd, SHUT_RD);
      } while (result < 0 && errno == EINTR);
    }

    inline int descriptor() const noexcept {
      return _fd;
    }

    inline void interrupt() const noexcept {
      if (_fd >= 0) {
        ::shutdown(_fd, SHUT_RDWR);
      }
    }

  private:
    static constexpr timeval io_timeout{
        .tv_sec = 30,
        .tv_usec = 0,
    };

    template <std::size_t N>
    inline void sendFrame(const std::array<Byte, N> &payload) _throw(SocketError) {
      static_assert(N > 0 && N <= max_payload_size, "Invalid runtime frame length");
      std::array<Byte, frame_prefix_size + N> frame{};
      std::span<Byte> output = frame;
      u32::encode(static_cast<std::uint32_t>(payload.size()), output);

      std::memcpy(output.data(), payload.data(), payload.size());
      writeAll(frame.data(), frame.size());
    }

    inline void writeAll(const std::uint8_t *bytes, std::size_t size) _throw(SocketError) {
      while (size != 0) {
#ifdef MSG_NOSIGNAL
        const auto count = ::send(_fd, bytes, size, MSG_NOSIGNAL);
#else
        const auto count = ::send(_fd, bytes, size, 0);
#endif
        if (count < 0 && errno == EINTR) {
          continue;
        }

        if (count <= 0) {
          if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            throw SocketError{"Runtime send timed out"};
          }

          throw SocketError{"Error sending runtime message"};
        }

        bytes += count;
        size -= static_cast<std::size_t>(count);
      }
    }

    inline void readAll(std::uint8_t *bytes, std::size_t size) _throw(SocketError) {
      while (size != 0) {
        const auto count = recv(_fd, bytes, size, 0);
        if (count < 0 && errno == EINTR) {
          continue;
        }

        if (count < 0) {
          if (errno == EAGAIN || errno == EWOULDBLOCK) {
            throw SocketError{"Runtime receive timed out"};
          }

          throw SocketError{"Error receiving runtime message"};
        }

        if (count == 0) {
          throw SocketError{"Runtime closed the connection"};
        }

        bytes += count;
        size -= static_cast<std::size_t>(count);
      }
    }

    sockaddr_un _address = {};
    int _fd = -1;
  };

} // namespace telar
}

// Interface: telar_client/telar.cppm
export {

}
