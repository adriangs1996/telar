module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.vocabulary.exchange;

namespace telar::runtime {

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

  template <Allocator Memory>
  CaptureBuffer<Memory>::CaptureBuffer(Memory& memory, CaptureQuota& quota, std::size_t limit) noexcept
      : memory_(memory),
        quota_(quota),
        limit_(limit) {}

  template <Allocator Memory>
  CaptureBuffer<Memory>::~CaptureBuffer() {
    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::append(std::span<const std::uint8_t> input) noexcept {
    const auto allowed = std::min(input.size(), limit_ - size_);
    const auto accepted = reserveAdditional(allowed);
    if (accepted != 0) {
      std::memcpy(storage_ + size_, input.data(), accepted);
      size_ += accepted;
    }

    truncated = truncated || accepted != input.size();
    return accepted;
  }

  template <Allocator Memory>
  void CaptureBuffer<Memory>::reset() noexcept {
    eraseSensitive(storage_, size_);
    size_ = 0;
    truncated = false;
  }

  template <Allocator Memory>
  std::span<const std::uint8_t> CaptureBuffer<Memory>::bytes() const noexcept {
    return {storage_, size_};
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::size() const noexcept {
    return size_;
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::capacity() const noexcept {
    return capacity_;
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::remaining() const noexcept {
    return limit_ - size_;
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::grownCapacity(std::size_t needed) const noexcept {
    auto capacity = std::min(limit_, std::max(initial_capacity, capacity_));

    while (capacity < needed) {
      capacity = capacity > limit_ / 2 ? limit_ : capacity * 2;
    }

    return capacity;
  }

  template <Allocator Memory>
  std::size_t CaptureBuffer<Memory>::reserveAdditional(std::size_t bytes) noexcept {
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
      std::memcpy(replacement, storage_, size_);
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

  template <Allocator Memory>
  CaptureHalf<Memory>::CaptureHalf(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<CaptureQuota&, tbc::lt::a> quota, const ProxyCaptureLimits& limits, CaptureStart start)
      : key(start.key),
        side(start.side),
        protocol(start.protocol),
        started_at_ms(start.started_at_ms),
        head(memory, quota, limits.part_bytes),
        body(memory, quota, limits.part_bytes),
        maximum_bytes_(std::max(std::size_t{1}, limits.exchange_bytes / 2)) {
    host_.append(start.host.view());
  }

  template <Allocator Memory>
  bool CaptureHalf<Memory>::append(CapturePart part, std::span<const std::uint8_t> input) noexcept {
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

  template <Allocator Memory>
  bool CaptureHalf<Memory>::append(CapturePart part, std::string_view input) noexcept {
    return append(part, {reinterpret_cast<const std::uint8_t*>(input.data()), input.size()});
  }

  template <Allocator Memory>
  void CaptureHalf<Memory>::appendHead(std::string_view bytes) noexcept {
    append(headPart(), bytes);
    if (side == CaptureSide::request) {
      const auto line_end = bytes.find("\r\n");
      if (line_end == std::string_view::npos) {
        return;
      }

      TextFields fields{bytes.substr(0, line_end), " "};
      const auto method = fields.next();
      const auto target = fields.next();
      if (!method || !target) {
        return;
      }

      setMethod(*method);
      setTarget(*target);
    }

    TextFields lines{bytes, "\r\n"};

    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon != std::string_view::npos && asciiEqualIgnoreCase(trimText(line->substr(0, colon), " \t"), "content-encoding")) {
        setEncoding(trimText(line->substr(colon + 1), " \t"));
        return;
      }
    }
  }

  template <Allocator Memory>
  void CaptureHalf<Memory>::setMethod(std::string_view value) noexcept {
    setRouteField(head.truncated, method_, value);
  }

  template <Allocator Memory>
  void CaptureHalf<Memory>::setTarget(std::string_view value) noexcept {
    setRouteField(head.truncated, target_, value);
  }

  template <Allocator Memory>
  void CaptureHalf<Memory>::setEncoding(std::string_view value) noexcept {
    encoding_.clear();
    encoding_.append(value.substr(0, maximum_encoding_bytes));
    body.truncated = body.truncated || value.size() > maximum_encoding_bytes;
  }

  template <Allocator Memory>
  void CaptureHalf<Memory>::finish(CaptureOutcome result, std::int64_t timestamp) noexcept {
    outcome = result;
    finished_at_ms = timestamp;
  }

  template <Allocator Memory>
  CapturePart CaptureHalf<Memory>::headPart() const noexcept {
    return side == CaptureSide::request ? CapturePart::request_head : CapturePart::response_head;
  }

  template <Allocator Memory>
  CapturePart CaptureHalf<Memory>::bodyPart() const noexcept {
    return side == CaptureSide::request ? CapturePart::request_body : CapturePart::response_body;
  }

  template <Allocator Memory>
  std::size_t CaptureHalf<Memory>::capturedBytes() const noexcept {
    return head.size() + body.size();
  }

  template <Allocator Memory>
  std::size_t CaptureHalf<Memory>::remaining() const noexcept {
    return maximum_bytes_ - capturedBytes();
  }

  template <Allocator Memory>
  std::size_t CaptureHalf<Memory>::bodyLimit() const noexcept {
    return maximum_bytes_ - head.size();
  }

  template <Allocator Memory>
  std::string_view CaptureHalf<Memory>::host() const noexcept {
    return host_.view();
  }

  template <Allocator Memory>
  std::string_view CaptureHalf<Memory>::method() const noexcept {
    return method_.view();
  }

  template <Allocator Memory>
  std::string_view CaptureHalf<Memory>::target() const noexcept {
    return target_.view();
  }

  template <Allocator Memory>
  std::string_view CaptureHalf<Memory>::encoding() const noexcept {
    return encoding_.view();
  }

  template <Allocator Memory>
  template <std::size_t Capacity>
  void CaptureHalf<Memory>::setRouteField(bool& truncated, SensitiveText<Capacity>& field, std::string_view value) noexcept {
    if (value.size() > Capacity) {
      truncated = true;
      return;
    }

    field.clear();
    field.append(value);
  }

  template <Allocator Memory>
  CaptureBuffer<Memory>* CaptureHalf<Memory>::select(CapturePart part) noexcept {
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

  template <Allocator Memory>
  CapturedExchange<Memory>::CapturedExchange(tbc::view<Memory&, tbc::lt::a> memory) noexcept
      : request(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}),
        response(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}) {}

  template <Allocator Memory>
  void CapturedExchange<Memory>::include(tbc::view<Half, tbc::lt::a> half) noexcept {
    (half->side == CaptureSide::request ? request : response) = std::move(half);
  }

  std::optional<std::size_t> FlateEnvelope::bodyOffset(std::span<const std::uint8_t> input, FlateContainer container) noexcept {
    if (container == FlateContainer::zlib) {
      constexpr std::size_t header_size = 2;
      constexpr unsigned compression_method = 8;
      constexpr unsigned maximum_window_bits = 7;
      if (input.size() < header_size || (input[0] & 15) != compression_method || (input[0] >> 4) > maximum_window_bits) {
        return std::nullopt;
      }

      return header_size;
    }

    constexpr std::size_t header_size = 10;
    constexpr std::uint8_t magic_first = 0x1f;
    constexpr std::uint8_t magic_second = 0x8b;
    constexpr std::uint8_t compression_method = 8;
    if (input.size() < header_size || input[0] != magic_first || input[1] != magic_second || input[2] != compression_method) {
      return std::nullopt;
    }

    const auto flags = input[3];
    auto offset = header_size;

    if (flags & static_cast<unsigned>(GzipFlag::extra)) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return std::nullopt;
      }

      const auto length = static_cast<std::size_t>(input[offset] | (input[offset + 1] << 8));

      offset += sizeof(std::uint16_t);
      if (length > input.size() - offset) {
        return std::nullopt;
      }

      offset += length;
    }

    for (const auto field : {GzipFlag::name, GzipFlag::comment}) {
      if (flags & static_cast<unsigned>(field)) {
        while (offset < input.size() && input[offset] != 0) {
          ++offset;
        }

        if (offset == input.size()) {
          return std::nullopt;
        }

        ++offset;
      }
    }

    if (flags & static_cast<unsigned>(GzipFlag::header_checksum)) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return std::nullopt;
      }

      offset += sizeof(std::uint16_t);
    }

    return offset;
  }

  template class CaptureBuffer<telar::ConcurrentMemory>;

  template class CaptureHalf<telar::ConcurrentMemory>;

  template struct CapturedExchange<telar::ConcurrentMemory>;

}
