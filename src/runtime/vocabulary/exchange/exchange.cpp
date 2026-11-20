module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.vocabulary.exchange;

import telar.base.ds;
import telar.base.text;
import telar.wire.vocabulary;

namespace telar::runtime {

  namespace {

    constexpr std::string_view blanks = " \t";

    // The `count` bytes of a buffer's allocation, as a view the copies below stay within.
    template <typename Element>
    std::span<Element> allocationBytes(Element* storage, std::size_t count) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {storage, count};
#pragma clang unsafe_buffer_usage end
    }

  }

  CaptureQuota::CaptureQuota(std::size_t limit) noexcept
      : limit_(limit) {}

  bool CaptureQuota::reserveExact(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);

    while (requested <= limit_ - current) {
      if (used_.compare_exchange_weak(current, current + requested, std::memory_order_relaxed)) {
        return true;
      }
    }

    return false;
  }

  std::size_t CaptureQuota::reserveAtMost(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);

    for (;;) {
      const auto granted = std::min(requested, limit_ - current);
      if (granted == 0 || used_.compare_exchange_weak(current, current + granted, std::memory_order_relaxed)) {
        return granted;
      }
    }
  }

  void CaptureQuota::release(std::size_t bytes) noexcept {
    if (bytes == 0) {
      return;
    }

    [[maybe_unused]] const auto previous = used_.fetch_sub(bytes, std::memory_order_relaxed);

    TELAR_ASSERT(previous >= bytes);
  }

  std::size_t CaptureQuota::used() const noexcept {
    return used_.load(std::memory_order_relaxed);
  }

  CaptureBuffer::CaptureBuffer(ConcurrentMemory& memory, CaptureQuota& quota, std::size_t limit) noexcept
      : memory_(memory),
        quota_(quota),
        limit_(limit) {}

  CaptureBuffer::~CaptureBuffer() {
    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
  }

  std::size_t CaptureBuffer::append(std::span<const std::uint8_t> input) noexcept {
    const auto allowed = std::min(input.size(), limit_ - size_);
    const auto accepted = reserveAdditional(allowed);
    if (accepted != 0) {
      std::ranges::copy(input.first(accepted), allocationBytes(storage_, capacity_).subspan(size_).begin());
      size_ += accepted;
    }

    truncated = truncated || accepted != input.size();
    return accepted;
  }

  void CaptureBuffer::reset() noexcept {
    eraseSensitive(storage_, size_);
    size_ = 0;
    truncated = false;
  }

  std::span<const std::uint8_t> CaptureBuffer::bytes() const noexcept {
    return allocationBytes(static_cast<const std::uint8_t*>(storage_), size_);
  }

  std::size_t CaptureBuffer::size() const noexcept {
    return size_;
  }

  std::size_t CaptureBuffer::capacity() const noexcept {
    return capacity_;
  }

  std::size_t CaptureBuffer::remaining() const noexcept {
    return limit_ - size_;
  }

  std::size_t CaptureBuffer::grownCapacity(std::size_t needed) const noexcept {
    auto capacity = std::min(limit_, std::max(initial_capacity, capacity_));

    while (capacity < needed) {
      capacity = capacity > limit_ / 2 ? limit_ : capacity * 2;
    }

    return capacity;
  }

  std::size_t CaptureBuffer::reserveAdditional(std::size_t bytes) noexcept {
    if (bytes <= capacity_ - size_) {
      return bytes;
    }

    // The old allocation remains charged until the replacement has been copied.
    const auto replacement_capacity = quota_.reserveAtMost(grownCapacity(size_ + bytes));
    if (replacement_capacity <= capacity_) {
      quota_.release(replacement_capacity);
      return capacity_ - size_;
    }

    auto* replacement = static_cast<std::uint8_t*>(memory_.allocate(replacement_capacity, alignof(std::uint8_t)));
    if (replacement == nullptr) {
      quota_.release(replacement_capacity);
      return capacity_ - size_;
    }

    if (size_ != 0) {
      std::ranges::copy(allocationBytes(static_cast<const std::uint8_t*>(storage_), size_), replacement);
    }

    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
    storage_ = replacement;
    capacity_ = replacement_capacity;
    return std::min(bytes, capacity_ - size_);
  }

  std::string_view CaptureHost::view() const noexcept {
    return text_.view();
  }

  bool CaptureHost::oversized() const noexcept {
    return oversized_;
  }

  CaptureHalf::CaptureHalf(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<CaptureQuota> quota, const ProxyCaptureLimits& limits, const CaptureStart& start)
      : key(start.key),
        side(start.side),
        protocol(start.protocol),
        started_at_ms(start.started_at_ms),
        head(memory, quota, limits.part_bytes),
        body(memory, quota, limits.part_bytes),
        maximum_bytes_(std::max(std::size_t{1}, limits.exchange_bytes / 2)) {
    host_.append(start.host.view());
  }

  bool CaptureHalf::append(CapturePart part, std::span<const std::uint8_t> input) noexcept {
    auto* selected = select(part);
    if (selected == nullptr) {
      return false;
    }

    const auto part_room = selected->remaining();
    const auto half_room = remaining();
    const auto allowed = std::min({input.size(), part_room, half_room});
    if (allowed != input.size()) {
      if (part_room <= half_room) {
        truncation.part = true;
      } else {
        truncation.exchange = true;
      }
    }

    const auto accepted = selected->append(input.first(allowed));
    if (accepted != allowed) {
      truncation.total = true;
    }

    selected->truncated = selected->truncated || accepted != input.size();
    return accepted == input.size() && !selected->truncated;
  }

  bool CaptureHalf::append(CapturePart part, std::string_view input) noexcept {
    return append(part, byteView(input));
  }

  void CaptureHalf::appendHead(std::string_view bytes) noexcept {
    append(headPart(), bytes);
    if (side == CaptureSide::request) {
      const auto line_end = bytes.find("\r\n");
      if (line_end == std::string_view::npos) {
        return;
      }

      TextFields fields{{.text = textPrefix(bytes, line_end), .delimiter = " "}};
      const auto method = fields.next();
      const auto target = fields.next();
      if (!method || !target) {
        return;
      }

      setMethod(*method);
      setTarget(*target);
    }

    TextFields lines{{.text = bytes, .delimiter = "\r\n"}};

    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon != std::string_view::npos && asciiEqualIgnoreCase(trimText(textPrefix(*line, colon), blanks), "content-encoding")) {
        setEncoding(trimText(textAfter(*line, colon + 1), blanks));
        return;
      }
    }
  }

  void CaptureHalf::setMethod(std::string_view value) noexcept {
    setRouteField(head.truncated, method_, value);
  }

  void CaptureHalf::setTarget(std::string_view value) noexcept {
    setRouteField(head.truncated, target_, value);
  }

  void CaptureHalf::setEncoding(std::string_view value) noexcept { // NOLINT(bugprone-exception-escape): append throws only past the capacity the cleared text keeps the value within
    encoding_.clear();
    encoding_.append(textPrefix(value, maximum_encoding_bytes));
    body.truncated = body.truncated || value.size() > maximum_encoding_bytes;
  }

  void CaptureHalf::finish(CaptureOutcome result, std::int64_t timestamp) noexcept {
    outcome = result;
    finished_at_ms = timestamp;
  }

  CapturePart CaptureHalf::headPart() const noexcept {
    return side == CaptureSide::request ? CapturePart::request_head : CapturePart::response_head;
  }

  CapturePart CaptureHalf::bodyPart() const noexcept {
    return side == CaptureSide::request ? CapturePart::request_body : CapturePart::response_body;
  }

  std::size_t CaptureHalf::capturedBytes() const noexcept {
    return head.size() + body.size();
  }

  std::size_t CaptureHalf::remaining() const noexcept {
    return maximum_bytes_ - capturedBytes();
  }

  std::size_t CaptureHalf::bodyLimit() const noexcept {
    return maximum_bytes_ - head.size();
  }

  std::string_view CaptureHalf::host() const noexcept {
    return host_.view();
  }

  std::string_view CaptureHalf::method() const noexcept {
    return method_.view();
  }

  std::string_view CaptureHalf::target() const noexcept {
    return target_.view();
  }

  std::string_view CaptureHalf::encoding() const noexcept {
    return encoding_.view();
  }

  template <std::size_t Capacity>
  void CaptureHalf::setRouteField(bool& truncated, SensitiveText<Capacity>& field, std::string_view value) noexcept {
    if (value.size() > Capacity) {
      truncated = true;
      return;
    }

    field.clear();
    field.append(value);
  }

  CaptureBuffer* CaptureHalf::select(CapturePart part) noexcept {
    switch (part) {
    case CapturePart::request_head:
      return side == CaptureSide::request ? &head : nullptr;
    case CapturePart::request_body:
      return side == CaptureSide::request ? &body : nullptr;
    case CapturePart::response_head:
      return side == CaptureSide::response ? &head : nullptr;
    case CapturePart::response_body:
      return side == CaptureSide::response ? &body : nullptr;
    }

    return nullptr;
  }

  CapturedExchange::CapturedExchange([[maybe_unused]] tbc::mut_a<ConcurrentMemory> memory) noexcept {}

  void CapturedExchange::include(tbc::val_a<Half> half) noexcept {
    (half->side == CaptureSide::request ? request : response) = std::move(half);
  }

  ds::Option<std::size_t> FlateEnvelope::bodyOffset(std::span<const std::uint8_t> input, FlateContainer container) noexcept {
    if (container == FlateContainer::zlib) {
      constexpr std::size_t header_size = 2;
      constexpr unsigned compression_method = 8;
      constexpr unsigned maximum_window_bits = 7;
      // The first byte holds the method in its low nibble and the window size in its high one.
      constexpr unsigned method_mask = 0x0f;
      constexpr unsigned window_shift = 4;
      if (input.size() < header_size || (static_cast<unsigned>(input[0]) & method_mask) != compression_method || (static_cast<unsigned>(input[0]) >> window_shift) > maximum_window_bits) {
        return ds::none;
      }

      return header_size;
    }

    constexpr std::size_t header_size = 10;
    constexpr std::uint8_t magic_first = 0x1f;
    constexpr std::uint8_t magic_second = 0x8b;
    constexpr std::uint8_t compression_method = 8;
    if (input.size() < header_size || input[0] != magic_first || input[1] != magic_second || input[2] != compression_method) {
      return ds::none;
    }

    const auto flags = input[3];
    auto offset = header_size;

    if ((flags & static_cast<unsigned>(GzipFlag::extra)) != 0U) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return ds::none;
      }

      constexpr unsigned byte_bits = 8;
      const auto length = static_cast<std::size_t>(static_cast<unsigned>(input[offset]) | (static_cast<unsigned>(input[offset + 1]) << byte_bits));

      offset += sizeof(std::uint16_t);
      if (length > input.size() - offset) {
        return ds::none;
      }

      offset += length;
    }

    for (const auto field : {GzipFlag::name, GzipFlag::comment}) {
      if ((flags & static_cast<unsigned>(field)) != 0U) {
        while (offset < input.size() && input[offset] != 0) {
          ++offset;
        }

        if (offset == input.size()) {
          return ds::none;
        }

        ++offset;
      }
    }

    if ((flags & static_cast<unsigned>(GzipFlag::header_checksum)) != 0U) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return ds::none;
      }

      offset += sizeof(std::uint16_t);
    }

    return offset;
  }

}
