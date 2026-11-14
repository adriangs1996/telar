module telar.gui.core.unicode_scalar;

import std;

namespace telar::gui {

  std::uint32_t CellRectangle::right() const noexcept {
    return static_cast<std::uint32_t>(x) + width;
  }

  std::uint32_t CellRectangle::bottom() const noexcept {
    return static_cast<std::uint32_t>(y) + height;
  }

  bool CellRectangle::empty() const noexcept {
    return width == 0 || height == 0;
  }

  CellRectangle CellRectangle::inner(std::uint16_t margin) const noexcept {
    const auto shrink = static_cast<std::uint32_t>(margin) * 2;
    if (width <= shrink || height <= shrink) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();

    return {
        .x = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(x) + margin, static_cast<std::uint32_t>(maximum))),
        .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + margin, static_cast<std::uint32_t>(maximum))),
        .width = static_cast<std::uint16_t>(width - shrink),
        .height = static_cast<std::uint16_t>(height - shrink),
    };
  }

  CellRectangle CellRectangle::intersect(CellRectangle other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);
    const auto end = std::max<std::uint32_t>(left, std::min(right(), other.right()));
    const auto lower = std::max<std::uint32_t>(top, std::min(bottom(), other.bottom()));

    return {.x = left, .y = top, .width = static_cast<std::uint16_t>(end - left), .height = static_cast<std::uint16_t>(lower - top)};
  }

  CellRectangle CellRectangle::row(std::uint16_t index) const noexcept {
    if (index >= height) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();

    return {.x = x, .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + index, static_cast<std::uint32_t>(maximum))), .width = width, .height = 1};
  }

  std::string_view Utf8Scalar::view() const noexcept {
    return {bytes.data(), length};
  }

  Utf8Scalar Utf8Scalar::encode(std::uint32_t codepoint) {
    if (!valid(codepoint)) {
      throw std::invalid_argument{"Invalid Unicode scalar"};
    }

    Utf8Scalar result;

    while (codepoint > maximum_codepoints[result.length]) {
      ++result.length;
    }

    const auto continuation_count = result.length;

    result.bytes[0] = static_cast<char>(leading_prefixes[continuation_count] | (codepoint >> (continuation_bits * continuation_count)));
    for (std::size_t index = 0; index < continuation_count; ++index) {
      const auto shift = continuation_bits * (continuation_count - index - 1);

      result.bytes[index + 1] = static_cast<char>(continuation_prefix | ((codepoint >> shift) & continuation_mask));
    }

    ++result.length;

    return result;
  }

  std::uint32_t Utf8Scalar::decode(std::string_view text) {
    const auto decoded = read(text);

    switch (decoded.error) {
    case DecodeError::none:
      return decoded.value;
    case DecodeError::length:
      throw std::invalid_argument{"Expected one UTF-8 scalar"};
    case DecodeError::leading_byte:
      throw std::invalid_argument{"Invalid UTF-8 leading byte"};
    case DecodeError::continuation_byte:
      throw std::invalid_argument{"Invalid UTF-8 continuation byte"};
    case DecodeError::scalar:
      throw std::invalid_argument{"Invalid or overlong UTF-8 scalar"};
    }

    throw std::invalid_argument{"Invalid Unicode decoding state"};
  }

  std::optional<std::uint32_t> Utf8Scalar::tryDecode(std::string_view text) noexcept {
    const auto decoded = read(text);
    if (decoded.error != DecodeError::none) {
      return std::nullopt;
    }

    return decoded.value;
  }

  Utf8Scalar::Decoded Utf8Scalar::read(std::string_view text) noexcept {
    if (text.empty() || text.size() > leading_masks.size()) {
      return {.error = DecodeError::length};
    }

    const auto length = text.size();
    const auto first = static_cast<unsigned char>(text.front());
    const auto prefix_mask = ~leading_masks[length - 1] & std::uint8_t{0xff};
    if ((first & prefix_mask) != leading_prefixes[length - 1]) {
      return {.error = DecodeError::leading_byte};
    }

    auto codepoint = static_cast<std::uint32_t>(first & leading_masks[length - 1]);
    auto continuations = text;

    continuations.remove_prefix(1);
    for (const auto byte : continuations) {
      const auto continuation = static_cast<unsigned char>(byte);
      constexpr unsigned prefix_mask = 0xc0;
      if ((continuation & prefix_mask) != continuation_prefix) {
        return {.error = DecodeError::continuation_byte};
      }

      codepoint = (codepoint << continuation_bits) | (continuation & continuation_mask);
    }

    if (!valid(codepoint) || codepoint < minimum_codepoints[length - 1]) {
      return {.error = DecodeError::scalar};
    }

    return {.value = codepoint};
  }

}
