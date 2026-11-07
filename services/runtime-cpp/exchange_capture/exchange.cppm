module;
#include <limits>
#include <utility>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>

#include <cstring>
#include <cstdint>
#include <span>

#include <string_view>

#include <array>
#include <stdexcept>
#include <optional>
#include <chrono>

#include <initializer_list>

#include <concepts>

export module telar.runtime.exchange_capture.exchange;

export import telar.base.memory;


export import telar.base.text;
export import telar.config;
import telar.base.diagnostics;

// Interface: exchange_capture/quota.cppm
export {
namespace telar::runtime {

class CaptureQuota {
public:
  inline explicit CaptureQuota(std::size_t limit) noexcept : limit_(limit) {}

  inline bool reserveExact(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);
    while (requested <= limit_ - current) {
      if (used_.compare_exchange_weak(current, current + requested, std::memory_order_relaxed)) {
        return true;
      }
    }
    return false;
  }

  inline std::size_t reserveAtMost(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);
    for (;;) {
      const auto granted = std::min(requested, limit_ - current);
      if (granted == 0 || used_.compare_exchange_weak(current, current + granted, std::memory_order_relaxed)) {
        return granted;
      }
    }
  }

  inline void release(std::size_t bytes) noexcept {
    if (bytes == 0) {
      return;
    }
    [[maybe_unused]] const auto previous = used_.fetch_sub(bytes, std::memory_order_relaxed);
    assert(previous >= bytes);
  }

  inline std::size_t used() const noexcept { return used_.load(std::memory_order_relaxed); }

private:
  const std::size_t limit_;
  std::atomic<std::size_t> used_{0};
};

}
}

// Interface: exchange_capture/buffer.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CaptureBuffer {
public:
  inline explicit CaptureBuffer(Memory &memory, CaptureQuota &quota, std::size_t limit) noexcept : memory_(memory), quota_(quota), limit_(limit) {}

  inline ~CaptureBuffer() {
    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
  }

  CaptureBuffer(const CaptureBuffer &) = delete;
  CaptureBuffer &operator=(const CaptureBuffer &) = delete;

  inline std::size_t append(std::span<const std::uint8_t> input) noexcept {
    const auto allowed = std::min(input.size(), limit_ - size_);
    const auto accepted = reserveAdditional(allowed);
    if (accepted != 0) {
      std::memcpy(storage_ + size_, input.data(), accepted);
      size_ += accepted;
    }
    truncated = truncated || accepted != input.size();
    return accepted;
  }

  inline void reset() noexcept {
    eraseSensitive(storage_, size_);
    size_ = 0;
    truncated = false;
  }

  inline std::span<const std::uint8_t> bytes() const noexcept { return {storage_, size_}; }
  inline std::size_t size() const noexcept { return size_; }
  inline std::size_t capacity() const noexcept { return capacity_; }
  inline std::size_t remaining() const noexcept { return limit_ - size_; }

  bool truncated = false;

private:
  inline std::size_t grownCapacity(std::size_t needed) const noexcept {
    auto capacity = std::min(limit_, std::max(initial_capacity, capacity_));
    while (capacity < needed) {
      capacity = capacity > limit_ / 2 ? limit_ : capacity * 2;
    }
    return capacity;
  }

  inline std::size_t reserveAdditional(std::size_t bytes) noexcept {
    if (bytes <= capacity_ - size_) {
      return bytes;
    }

    // The old allocation remains charged until the replacement has been copied.
    const auto replacement_capacity = quota_.reserveAtMost(grownCapacity(size_ + bytes));
    if (replacement_capacity <= capacity_) {
      quota_.release(replacement_capacity);
      return capacity_ - size_;
    }

    auto *replacement = static_cast<std::uint8_t *>(memory_.allocate(replacement_capacity, alignof(std::uint8_t)));
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

  static constexpr std::size_t initial_capacity = 256;
  ErasingAllocator<Memory> memory_;
  CaptureQuota &quota_;
  const std::size_t limit_;
  std::uint8_t *storage_ = nullptr;
  std::size_t size_ = 0;
  std::size_t capacity_ = 0;
};

}
}

// Interface: exchange_capture/types.cppm
export {
namespace telar::runtime {

enum class CaptureSide {
  request,
  response
};

enum class CapturePart {
  request_head,
  request_body,
  response_head,
  response_body
};

enum class CaptureOutcome {
  finished,
  failed,
  reset
};

enum class CaptureProtocol {
  http1,
  http2,
  upgraded
};

struct CaptureKey {
  std::uint64_t connection = 0;
  std::uint32_t stream = 0;

  bool operator==(const CaptureKey &) const = default;
};

struct CaptureTruncation {
  bool part = false;
  bool exchange = false;
  bool total = false;
};

struct CaptureStart {
  CaptureKey key{};
  CaptureSide side = CaptureSide::request;
  CaptureProtocol protocol = CaptureProtocol::http1;
  std::string_view host{};
  std::int64_t started_at_ms = 0;
};

}
}

// Interface: exchange_capture/half.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CaptureHalf {
public:
  inline explicit CaptureHalf(Memory &memory, CaptureQuota &quota, const ProxyCaptureLimits &limits, CaptureStart start)
      : key(start.key), side(start.side), protocol(start.protocol), started_at_ms(start.started_at_ms),
        head(memory, quota, limits.part_bytes), body(memory, quota, limits.part_bytes), maximum_bytes_(std::max(std::size_t{1}, limits.exchange_bytes / 2)) {
    host_.append(start.host);
  }

  inline bool append(CapturePart part, std::span<const std::uint8_t> input) noexcept {
    auto *selected = select(part);
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

  inline bool append(CapturePart part, std::string_view input) noexcept {
    return append(part, {reinterpret_cast<const std::uint8_t *>(input.data()), input.size()});
  }

  inline void appendHead(std::string_view bytes) noexcept {
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

  inline void setMethod(std::string_view value) noexcept { setRouteField(method_, value); }
  inline void setTarget(std::string_view value) noexcept { setRouteField(target_, value); }

  inline void setEncoding(std::string_view value) noexcept {
    encoding_.clear();
    encoding_.append(value.substr(0, maximum_encoding_bytes));
    body.truncated = body.truncated || value.size() > maximum_encoding_bytes;
  }

  inline void finish(CaptureOutcome result, std::int64_t timestamp) noexcept {
    outcome = result;
    finished_at_ms = timestamp;
  }

  inline CapturePart headPart() const noexcept { return side == CaptureSide::request ? CapturePart::request_head : CapturePart::response_head; }
  inline CapturePart bodyPart() const noexcept { return side == CaptureSide::request ? CapturePart::request_body : CapturePart::response_body; }
  inline std::size_t capturedBytes() const noexcept { return head.size() + body.size(); }
  inline std::size_t remaining() const noexcept { return maximum_bytes_ - capturedBytes(); }
  inline std::size_t bodyLimit() const noexcept { return maximum_bytes_ - head.size(); }
  inline std::string_view host() const noexcept { return host_.view(); }
  inline std::string_view method() const noexcept { return method_.view(); }
  inline std::string_view target() const noexcept { return target_.view(); }
  inline std::string_view encoding() const noexcept { return encoding_.view(); }

  static constexpr std::size_t maximum_host_bytes = 255;
  static constexpr std::size_t maximum_method_bytes = 32;
  static constexpr std::size_t maximum_target_bytes = 8 * 1024;
  static constexpr std::size_t maximum_encoding_bytes = 128;
  const CaptureKey key;
  const CaptureSide side;
  const CaptureProtocol protocol;
  const std::int64_t started_at_ms;
  std::int64_t finished_at_ms = 0;
  CaptureOutcome outcome = CaptureOutcome::failed;
  std::uint16_t status_code = 0;
  bool body_decoded = false;
  CaptureTruncation truncation;
  CaptureBuffer<Memory> head;
  CaptureBuffer<Memory> body;

private:
  template <std::size_t Capacity>
  inline void setRouteField(SensitiveText<Capacity> &field, std::string_view value) noexcept {
    if (value.size() > Capacity) {
      head.truncated = true;
      return;
    }
    field.clear();
    field.append(value);
  }

  inline CaptureBuffer<Memory> *select(CapturePart part) noexcept {
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

  const std::size_t maximum_bytes_;
  SensitiveText<maximum_host_bytes> host_;
  SensitiveText<maximum_method_bytes> method_;
  SensitiveText<maximum_target_bytes> target_;
  SensitiveText<maximum_encoding_bytes> encoding_;
};

}
}

// Interface: exchange_capture/exchange.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct CapturedExchange {
  using Half = Owned<CaptureHalf<Memory>, Memory>;

  inline explicit CapturedExchange(Memory &memory) noexcept
      : request(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}),
        response(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}) {}

  inline void include(Half half) noexcept {
    (half->side == CaptureSide::request ? request : response) = std::move(half);
  }

  Half request;
  Half response;
};

}
}

// Interface: exchange_capture/flate_container.cppm
export {
namespace telar::runtime {

enum class FlateContainer { gzip,
                            zlib };

class FlateEnvelope {
public:
  inline static std::optional<std::size_t> bodyOffset(std::span<const std::uint8_t> input, FlateContainer container) noexcept {
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

  static constexpr std::size_t footerSize(FlateContainer container) noexcept {
    return container == FlateContainer::gzip ? 2 * sizeof(std::uint32_t) : sizeof(std::uint32_t);
  }

private:
  enum class GzipFlag : unsigned { header_checksum = 2,
                                   extra = 4,
                                   name = 8,
                                   comment = 16 };
};

}
}

// Interface: exchange_capture/metrics.cppm
export {
namespace telar::runtime {

struct CaptureMetrics {
  std::uint64_t started = 0;
  std::uint64_t truncated = 0;
  std::uint64_t truncated_part = 0;
  std::uint64_t truncated_exchange = 0;
  std::uint64_t truncated_total = 0;
  std::uint64_t skipped = 0;
  std::uint64_t decode_failed = 0;
  std::uint64_t dropped_queue = 0;
  std::uint64_t queued = 0;
  std::uint64_t queue_high_water = 0;
};

}
}

// Interface: exchange_capture/source.cppm
export {
namespace telar::runtime {

template <typename Source>
concept CaptureEventSource = requires(Source &source) {
  { source.descriptor() } noexcept -> std::same_as<int>;
  { source.collect() } noexcept -> std::same_as<bool>;
};

struct IgnoreCaptureEvents {
  inline int descriptor() const noexcept { return -1; }
  inline bool collect() noexcept { return false; }
};

}
}
