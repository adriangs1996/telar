module;
#include "tbc/annotations.hpp"

module telar.msgpack;

import std;
import telar.base.ds;
import telar.tbc;

namespace telar::msgpack {

  namespace {

    constexpr std::uint8_t nil_head = 0xc0;
    constexpr std::uint8_t never_used_head = 0xc1;
    constexpr std::uint8_t false_head = 0xc2;
    constexpr std::uint8_t true_head = 0xc3;
    constexpr std::uint8_t bin8_head = 0xc4;
    constexpr std::uint8_t bin16_head = 0xc5;
    constexpr std::uint8_t bin32_head = 0xc6;
    constexpr std::uint8_t ext8_head = 0xc7;
    constexpr std::uint8_t ext16_head = 0xc8;
    constexpr std::uint8_t ext32_head = 0xc9;
    constexpr std::uint8_t float32_head = 0xca;
    constexpr std::uint8_t float64_head = 0xcb;
    constexpr std::uint8_t uint8_head = 0xcc;
    constexpr std::uint8_t uint16_head = 0xcd;
    constexpr std::uint8_t uint32_head = 0xce;
    constexpr std::uint8_t uint64_head = 0xcf;
    constexpr std::uint8_t int8_head = 0xd0;
    constexpr std::uint8_t int16_head = 0xd1;
    constexpr std::uint8_t int32_head = 0xd2;
    constexpr std::uint8_t int64_head = 0xd3;
    constexpr std::uint8_t fixext1_head = 0xd4;
    constexpr std::uint8_t fixext16_head = 0xd8;
    constexpr std::uint8_t str8_head = 0xd9;
    constexpr std::uint8_t str16_head = 0xda;
    constexpr std::uint8_t str32_head = 0xdb;
    constexpr std::uint8_t array16_head = 0xdc;
    constexpr std::uint8_t array32_head = 0xdd;
    constexpr std::uint8_t map16_head = 0xde;
    constexpr std::uint8_t map32_head = 0xdf;

    constexpr std::uint8_t positive_fixint_last = 0x7f;
    constexpr std::uint8_t fixmap_first = 0x80;
    constexpr std::uint8_t fixarray_first = 0x90;
    constexpr std::uint8_t fixstr_first = 0xa0;
    constexpr std::uint64_t fixcontainer_length = 0x0f;
    constexpr std::uint64_t fixstr_length = 0x1f;
    constexpr std::int64_t negative_fixint_min = -32;
    constexpr unsigned byte_bits = 8;

    // What the bytes after a type byte say about a value: whether they spell a payload's length,
    // a count of children or the value itself.
    enum class Tail : std::uint8_t {
      none,
      value,
      payload,
      // A payload one byte longer than its length: an extension's type comes first.
      extension,
      items,
      pairs,
      invalid,
    };

    struct Shape {
      Tail tail = Tail::none;
      Width width = Width::none;
    };

    constexpr Shape shapeOf(std::uint8_t head) noexcept {
      switch (head) {
      case bin8_head:
      case str8_head:
        return {.tail = Tail::payload, .width = Width::one};
      case bin16_head:
      case str16_head:
        return {.tail = Tail::payload, .width = Width::two};
      case bin32_head:
      case str32_head:
        return {.tail = Tail::payload, .width = Width::four};
      case ext8_head:
        return {.tail = Tail::extension, .width = Width::one};
      case ext16_head:
        return {.tail = Tail::extension, .width = Width::two};
      case ext32_head:
        return {.tail = Tail::extension, .width = Width::four};
      case uint8_head:
      case int8_head:
        return {.tail = Tail::value, .width = Width::one};
      case uint16_head:
      case int16_head:
        return {.tail = Tail::value, .width = Width::two};
      case float32_head:
      case uint32_head:
      case int32_head:
        return {.tail = Tail::value, .width = Width::four};
      case float64_head:
      case uint64_head:
      case int64_head:
        return {.tail = Tail::value, .width = Width::eight};
      case array16_head:
        return {.tail = Tail::items, .width = Width::two};
      case array32_head:
        return {.tail = Tail::items, .width = Width::four};
      case map16_head:
        return {.tail = Tail::pairs, .width = Width::two};
      case map32_head:
        return {.tail = Tail::pairs, .width = Width::four};
      case never_used_head:
        return {.tail = Tail::invalid};
      default:
        return {};
      }
    }

    constexpr std::size_t bytesOf(Width width) noexcept {
      return static_cast<std::size_t>(width);
    }

    constexpr bool fixedExtension(std::uint8_t head) noexcept {
      return head >= fixext1_head && head <= fixext16_head;
    }

    // The bytes a fixed extension holds after its type.
    constexpr std::uint64_t fixedExtensionSize(std::uint8_t head) noexcept {
      return std::uint64_t{1} << static_cast<unsigned>(head - fixext1_head);
    }

    // A number of a signed family, `width` bytes wide, as the 64 bits of the integer it spells.
    constexpr std::uint64_t signedBits(std::uint64_t value, Width width) noexcept {
      switch (width) {
      case Width::one:
        return static_cast<std::uint64_t>(std::int64_t{static_cast<std::int8_t>(value)});
      case Width::two:
        return static_cast<std::uint64_t>(std::int64_t{static_cast<std::int16_t>(value)});
      case Width::four:
        return static_cast<std::uint64_t>(std::int64_t{static_cast<std::int32_t>(value)});
      case Width::none:
      case Width::eight:
        break;
      }

      return value;
    }

    // The value a head of the value families spells with the number after it.
    constexpr Token valueOf(std::uint8_t head, std::uint64_t number) noexcept {
      if (head == float32_head) {
        return {.kind = Kind::floating, .bits = std::bit_cast<std::uint64_t>(double{std::bit_cast<float>(static_cast<std::uint32_t>(number))})};
      }

      if (head == float64_head) {
        return {.kind = Kind::floating, .bits = number};
      }

      if (head >= int8_head && head <= int64_head) {
        const auto bits = signedBits(number, shapeOf(head).width);

        return {.kind = static_cast<std::int64_t>(bits) < 0 ? Kind::negative_integer : Kind::unsigned_integer, .bits = bits};
      }

      return {.kind = Kind::unsigned_integer, .bits = number};
    }

    // The values that follow a container's head as its own.
    constexpr std::uint64_t childrenOf(const Token& token) noexcept {
      if (token.kind == Kind::map) {
        return token.bits * 2;
      }

      return token.kind == Kind::array ? token.bits : 0;
    }

    // The same bytes as text and as the bytes a value holds.
    std::span<const std::uint8_t> byteView(std::string_view text) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): a byte may alias a character, and no cast-free view reads text as bytes
#pragma clang unsafe_buffer_usage end
    }

  }

  tbc::val_a<std::string_view> Token::text() const noexcept {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): a character may alias a byte, and no cast-free view reads bytes as text
  }

  ds::Option<std::uint64_t> Reader::load(Width width, std::size_t skip) const noexcept {
    const auto count = bytesOf(width);
    if (input_.size() - offset_ < skip + count) {
      return ds::none;
    }

    std::uint64_t value = 0;

    for (const auto byte : input_.subspan(offset_ + skip, count)) {
      value = (value << byte_bits) | byte;
    }

    return value;
  }

  tbc::val_a<Read> Reader::extension(Body body) noexcept {
    const auto type = load(Width::one, body.head);
    if (!type) {
      return {};
    }

    auto read = payload(Kind::extension, {.head = body.head + 1, .length = body.length});

    read.token.extension = static_cast<std::int8_t>(*type);
    return read;
  }

  tbc::val_a<Read> Reader::tagged(std::uint8_t head) noexcept {
    if (head == nil_head) {
      return produce({.kind = Kind::nil}, 1);
    }

    if (head == false_head || head == true_head) {
      return produce({.kind = Kind::boolean, .bits = head == true_head ? std::uint64_t{1} : std::uint64_t{0}}, 1);
    }

    if (fixedExtension(head)) {
      return extension({.head = 1, .length = fixedExtensionSize(head)});
    }

    const auto shape = shapeOf(head);
    if (shape.tail == Tail::invalid || shape.tail == Tail::none) {
      return {.status = Status::malformed};
    }

    const auto number = load(shape.width);
    if (!number) {
      return {};
    }

    const std::size_t head_size = 1 + bytesOf(shape.width);

    switch (shape.tail) {
    case Tail::payload:
      return payload(head == bin8_head || head == bin16_head || head == bin32_head ? Kind::binary : Kind::string, {.head = head_size, .length = *number});
    case Tail::extension:
      return extension({.head = head_size, .length = *number});
    case Tail::items:
      return produce({.kind = Kind::array, .bits = *number}, head_size);
    case Tail::pairs:
      return produce({.kind = Kind::map, .bits = *number}, head_size);
    case Tail::value:
      return produce(valueOf(head, *number), head_size);
    case Tail::none:
    case Tail::invalid:
      break;
    }

    return {.status = Status::malformed};
  }

  bool Reader::number(double& value) noexcept {
    const auto token = this->value();
    if (!token) {
      return false;
    }

    if (token->kind == Kind::floating) {
      value = token->floating();
    } else if (token->kind == Kind::unsigned_integer) {
      value = static_cast<double>(token->bits);
    } else if (token->kind == Kind::negative_integer) {
      value = static_cast<double>(token->integer());
    } else {
      return fail();
    }

    return true;
  }

  Kind Reader::peek() const noexcept {
    Reader ahead{input_.subspan(std::min(offset_, input_.size()))};
    const auto read = ahead.next();

    return read.status == Status::ok ? read.token.kind : Kind::nil;
  }

  bool Reader::skip(unsigned depth) noexcept {
    // The values still to skip at each open container, innermost last.
    ds::Array<std::uint64_t, max_depth> pending{};
    unsigned open = 0;
    std::uint64_t left = 1;

    if (failed_ || depth > max_depth) {
      return fail();
    }

    while (left > 0 || open > 0) {
      if (left == 0) {
        left = pending[--open];
        continue;
      }

      const auto read = next();
      if (read.status != Status::ok) {
        return fail();
      }

      --left;

      const auto children = childrenOf(read.token);

      if (children == 0) {
        continue;
      }

      if (open == depth) {
        return fail();
      }

      pending.atMut(open++) = left;
      left = children;
    }

    return true;
  }

  void Scanner::reset() noexcept {
    skip_ = 0;
    depth_ = 0;
    head_size_ = 0;
    head_need_ = 0;
  }

  bool Scanner::valueEnded() noexcept {
    while (depth_ > 0) {
      if (--pending_.atMut(depth_ - 1U) > 0) {
        return false;
      }

      --depth_;
    }

    return true;
  }

  Scanner::Step Scanner::gather(std::span<const std::uint8_t> bytes, std::size_t& consumed) noexcept {
    if (head_size_ == 0) {
      const auto head = bytes[consumed];
      const auto shape = shapeOf(head);
      if (shape.tail == Tail::invalid) {
        return Step::malformed;
      }

      head_.atMut(0) = head;
      head_size_ = 1;
      head_need_ = static_cast<std::uint8_t>(1 + bytesOf(shape.width));
      ++consumed;
    }

    while (head_size_ < head_need_ && consumed < bytes.size()) {
      head_.atMut(head_size_++) = bytes[consumed++];
    }

    return head_size_ == head_need_ ? Step::advanced : Step::starved;
  }

  Scanner::Rest Scanner::rest() const noexcept {
    const auto head = head_[0];
    std::uint64_t number = 0;

    for (const auto byte : head_.view().subspan(1, head_need_ - std::size_t{1})) {
      number = (number << byte_bits) | byte;
    }

    switch (shapeOf(head).tail) {
    case Tail::payload:
      return {.payload = number};
    case Tail::extension:
      return {.payload = number + 1};
    case Tail::items:
      return {.children = number};
    case Tail::pairs:
      return {.children = number * 2};
    case Tail::value:
    case Tail::invalid:
      return {};
    case Tail::none:
      break;
    }

    if (fixedExtension(head)) {
      return {.payload = fixedExtensionSize(head) + 1};
    }

    if (head >= fixstr_first && head < nil_head) {
      return {.payload = static_cast<std::uint64_t>(head) & fixstr_length};
    }

    if (head >= fixarray_first && head < fixstr_first) {
      return {.children = static_cast<std::uint64_t>(head) & fixcontainer_length};
    }

    if (head >= fixmap_first && head < fixarray_first) {
      return {.children = 2 * (static_cast<std::uint64_t>(head) & fixcontainer_length)};
    }

    return {};
  }

  Scanner::Step Scanner::step(std::span<const std::uint8_t> bytes, std::size_t& consumed) noexcept {
    if (skip_ > 0) {
      const auto taken = static_cast<std::size_t>(std::min<std::uint64_t>(skip_, bytes.size() - consumed));

      consumed += taken;
      skip_ -= taken;
    } else {
      const auto gathered = gather(bytes, consumed);
      if (gathered != Step::advanced) {
        return gathered;
      }

      const auto left = rest();

      head_size_ = 0;
      if (left.children > 0) {
        if (depth_ == max_depth) {
          return Step::malformed;
        }

        pending_.atMut(depth_++) = left.children;
        return Step::advanced;
      }

      skip_ = left.payload;
    }

    return skip_ == 0 && valueEnded() ? Step::ended : Step::advanced;
  }

  Scanner::Progress Scanner::feed(std::span<const std::uint8_t> bytes) noexcept {
    std::size_t consumed = 0;

    while (consumed < bytes.size()) {
      switch (step(bytes, consumed)) {
      case Step::ended:
        return {.consumed = consumed, .status = Status::ok};
      case Step::malformed:
        return {.consumed = consumed, .status = Status::malformed};
      case Step::starved:
        return {.consumed = consumed, .status = Status::incomplete};
      case Step::advanced:
        break;
      }
    }

    return {.consumed = consumed, .status = Status::incomplete};
  }

  Writer::Writer(tbc::val_a<std::span<std::uint8_t>> output) noexcept
      : output_(output) {}

  void Writer::append(std::span<const std::uint8_t> bytes) noexcept {
    if (overflowed_ || output_.size() - size_ < bytes.size()) {
      overflowed_ = true;
      return;
    }

    std::ranges::copy(bytes, output_.subspan(size_).begin());
    size_ += bytes.size();
  }

  void Writer::put(std::uint8_t head, Width width, std::uint64_t value) noexcept {
    constexpr std::size_t longest = 9;
    ds::Array<std::uint8_t, longest> bytes{};
    const auto count = bytesOf(width);

    bytes.atMut(0) = head;

    for (std::size_t index = 0; index < count; ++index) {
      bytes.atMut(1 + index) = static_cast<std::uint8_t>(value >> (byte_bits * (count - 1 - index)));
    }

    append(bytes.view().first(1 + count));
  }

  bool Writer::sized(std::size_t size, ds::Array<std::uint8_t, 3> heads) noexcept {
    if (size <= std::numeric_limits<std::uint8_t>::max() && heads[0] != 0) {
      put(heads[0], Width::one, size);
    } else if (size <= std::numeric_limits<std::uint16_t>::max()) {
      put(heads[1], Width::two, size);
    } else if (size <= std::numeric_limits<std::uint32_t>::max()) {
      put(heads[2], Width::four, size);
    } else {
      overflowed_ = true;
    }

    return !overflowed_;
  }

  void Writer::nil() noexcept {
    put(nil_head);
  }

  void Writer::boolean(bool value) noexcept {
    put(value ? true_head : false_head);
  }

  void Writer::unsignedInteger(std::uint64_t value) noexcept {
    if (value <= positive_fixint_last) {
      put(static_cast<std::uint8_t>(value));
    } else if (value <= std::numeric_limits<std::uint8_t>::max()) {
      put(uint8_head, Width::one, value);
    } else if (value <= std::numeric_limits<std::uint16_t>::max()) {
      put(uint16_head, Width::two, value);
    } else if (value <= std::numeric_limits<std::uint32_t>::max()) {
      put(uint32_head, Width::four, value);
    } else {
      put(uint64_head, Width::eight, value);
    }
  }

  void Writer::integer(std::int64_t value) noexcept {
    const auto bits = static_cast<std::uint64_t>(value);

    if (value >= 0) {
      unsignedInteger(bits);
    } else if (value >= negative_fixint_min) {
      put(static_cast<std::uint8_t>(bits));
    } else if (value >= std::numeric_limits<std::int8_t>::min()) {
      put(int8_head, Width::one, bits);
    } else if (value >= std::numeric_limits<std::int16_t>::min()) {
      put(int16_head, Width::two, bits);
    } else if (value >= std::numeric_limits<std::int32_t>::min()) {
      put(int32_head, Width::four, bits);
    } else {
      put(int64_head, Width::eight, bits);
    }
  }

  void Writer::floating(double value) noexcept {
    put(float64_head, Width::eight, std::bit_cast<std::uint64_t>(value));
  }

  void Writer::string(std::string_view value) noexcept {
    if (value.size() <= fixstr_length) {
      put(static_cast<std::uint8_t>(fixstr_first | value.size()));
    } else if (!sized(value.size(), {str8_head, str16_head, str32_head})) {
      return;
    }

    append(byteView(value));
  }

  void Writer::binary(std::span<const std::uint8_t> value) noexcept {
    if (sized(value.size(), {bin8_head, bin16_head, bin32_head})) {
      append(value);
    }
  }

  void Writer::array(std::uint32_t count) noexcept {
    if (count <= fixcontainer_length) {
      put(static_cast<std::uint8_t>(fixarray_first | count));
    } else {
      sized(count, {0, array16_head, array32_head});
    }
  }

  void Writer::map(std::uint32_t count) noexcept {
    if (count <= fixcontainer_length) {
      put(static_cast<std::uint8_t>(fixmap_first | count));
    } else {
      sized(count, {0, map16_head, map32_head});
    }
  }

  bool Writer::overflowed() const noexcept {
    return overflowed_;
  }

  tbc::val_a<std::span<const std::uint8_t>> Writer::written() const noexcept {
    return output_.first(size_);
  }

}
