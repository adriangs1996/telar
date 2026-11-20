module telar.runtime.vocabulary.frames;

namespace telar::runtime::plugins {

  FrameReader::FrameReader(tbc::val_a<std::span<const Byte>> input) noexcept
      : remaining_(input) {}

  std::int64_t FrameReader::timestamp() {
    return std::bit_cast<std::int64_t>(integer<std::uint64_t>());
  }

  bool FrameReader::boolean() {
    return BoolByte::decode(remaining_);
  }

  tbc::val_a<std::span<const Byte>> FrameReader::bytes() {
    const auto length = integer<std::uint32_t>();
    if (length > remaining_.size()) {
      throw EncodingError{"Truncated tap field"};
    }

    const auto value = remaining_.first(length);

    remaining_ = remaining_.subspan(length);
    return value;
  }

  tbc::val_a<std::string_view> FrameReader::text() {
    const auto value = bytes();

    return textView(value);
  }

  void FrameReader::finish() const {
    if (!remaining_.empty()) {
      throw EncodingError{"Trailing tap frame bytes"};
    }
  }

  void FrameSize::timestamp([[maybe_unused]] std::int64_t value) {
    integer(std::uint64_t{});
  }

  void FrameSize::boolean([[maybe_unused]] bool value) {
    integer(Byte{});
  }

  void FrameSize::bytes(std::span<const Byte> value) {
    if (value.size() > std::numeric_limits<std::uint32_t>::max()) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }

    integer(std::uint32_t{});
    add(value.size());
  }

  void FrameSize::text(std::string_view value) {
    bytes(byteView(value));
  }

  std::size_t FrameSize::finish() const noexcept {
    return size_;
  }

  void FrameSize::add(std::size_t count) {
    size_ = checkedWireSize(size_, count);
  }

  FrameWriter::FrameWriter(tbc::val_a<std::span<Byte>> output) noexcept
      : output_(output),
        remaining_(output) {}

  void FrameWriter::timestamp(std::int64_t value) {
    integer(std::bit_cast<std::uint64_t>(value));
  }

  void FrameWriter::boolean(bool value) {
    BoolByte::encode(value, remaining_);
  }

  void FrameWriter::bytes(std::span<const Byte> value) {
    if (value.size() > std::numeric_limits<std::uint32_t>::max() || remaining_.size() < sizeof(std::uint32_t) || value.size() > remaining_.size() - sizeof(std::uint32_t)) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    std::ranges::copy(value, remaining_.begin());

    remaining_ = remaining_.subspan(value.size());
  }

  void FrameWriter::text(std::string_view value) {
    bytes(byteView(value));
  }

  void FrameWriter::append(std::span<const Byte> value) {
    if (value.size() > remaining_.size()) {
      throw EncodingError{"Tap data exceeds its frame buffer"};
    }

    std::ranges::copy(value, remaining_.begin());

    remaining_ = remaining_.subspan(value.size());
  }

  tbc::val_a<std::span<const Byte>> FrameWriter::finish() const noexcept {
    return output_.first(output_.size() - remaining_.size());
  }

}
