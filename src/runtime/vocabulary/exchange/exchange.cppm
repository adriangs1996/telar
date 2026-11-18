module;
#include "tbc/annotations.hpp"

export module telar.runtime.vocabulary.exchange;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.sensitive;

import telar.config.runtime;
import telar.base.ds;

// Interface: exchange_capture/quota.cppm
export {
  namespace telar::runtime {

    // Threads reserve and release bytes atomically, so a reference to the quota stays valid whatever is
    // done through it.
    class TBC_SHARED CaptureQuota {
    public:
      explicit CaptureQuota(std::size_t limit) noexcept;

      bool reserveExact(std::size_t requested) noexcept;

      std::size_t reserveAtMost(std::size_t requested) noexcept;

      void release(std::size_t bytes) noexcept;

      std::size_t used() const noexcept;

    private:
      const std::size_t limit_;
      std::atomic<std::size_t> used_{0};
    };

  }
}

// Interface: exchange_capture/buffer.cppm
export {
  namespace telar::runtime {

    class CaptureBuffer {
    public:
      explicit CaptureBuffer(ConcurrentMemory& memory, CaptureQuota& quota, std::size_t limit) noexcept;

      ~CaptureBuffer();

      CaptureBuffer(const CaptureBuffer&) = delete;
      CaptureBuffer& operator=(const CaptureBuffer&) = delete;

      std::size_t append(std::span<const std::uint8_t> input) noexcept;

      void reset() noexcept;

      std::span<const std::uint8_t> bytes() const noexcept;

      std::size_t size() const noexcept;

      std::size_t capacity() const noexcept;

      std::size_t remaining() const noexcept;

      bool truncated = false;

    private:
      std::size_t grownCapacity(std::size_t needed) const noexcept;

      std::size_t reserveAdditional(std::size_t bytes) noexcept;

      static constexpr std::size_t initial_capacity = 256;
      ErasingAllocator<ConcurrentMemory> memory_;
      CaptureQuota& quota_;
      const std::size_t limit_;
      std::uint8_t* storage_ = nullptr;
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
      response,
    };

    enum class CapturePart {
      request_head,
      request_body,
      response_head,
      response_body,
    };

    enum class CaptureOutcome {
      finished,
      failed,
      reset,
    };

    enum class CaptureProtocol {
      http1,
      http2,
      upgraded,
    };

    struct CaptureKey {
      std::uint64_t connection = 0;
      std::uint32_t stream = 0;

      bool operator==(const CaptureKey&) const = default;
    };

    struct CaptureTruncation {
      bool part = false;
      bool exchange = false;
      bool total = false;
    };

    // The host a capture names, owned and erased like the halves that copy it, so a start outlives the
    // connection text it was taken from. A host too long to keep is remembered as such.
    class CaptureHost {
    public:
      static constexpr std::size_t capacity = 255;

      inline CaptureHost() noexcept = default;

      // Generic over the caller's text, so it stays here.
      template <typename Text>
        requires std::convertible_to<const Text&, std::string_view>
      TBC_GENERIC inline CaptureHost(const Text& value) noexcept {
        const std::string_view text{value};

        oversized_ = text.size() > capacity;
        text_.append(text.substr(0, capacity));
      }

      std::string_view view() const noexcept;

      bool oversized() const noexcept;

    private:
      SensitiveText<capacity> text_;
      bool oversized_ = false;
    };

    struct CaptureStart {
      CaptureKey key{};
      CaptureSide side = CaptureSide::request;
      CaptureProtocol protocol = CaptureProtocol::http1;
      CaptureHost host{};
      std::int64_t started_at_ms = 0;
    };

  }
}

// Interface: exchange_capture/half.cppm
export {
  namespace telar::runtime {

    class CaptureHalf {
    public:
      // The half keeps the allocator and the quota, region `a`, and copies what it starts from.
      explicit CaptureHalf(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<CaptureQuota&, tbc::lt::a> quota, const ProxyCaptureLimits& limits, CaptureStart start);

      bool append(CapturePart part, std::span<const std::uint8_t> input) noexcept;

      bool append(CapturePart part, std::string_view input) noexcept;

      void appendHead(std::string_view bytes) noexcept;

      void setMethod(std::string_view value) noexcept;

      void setTarget(std::string_view value) noexcept;

      void setEncoding(std::string_view value) noexcept;

      void finish(CaptureOutcome result, std::int64_t timestamp) noexcept;

      CapturePart headPart() const noexcept;

      CapturePart bodyPart() const noexcept;

      std::size_t capturedBytes() const noexcept;

      std::size_t remaining() const noexcept;

      std::size_t bodyLimit() const noexcept;

      std::string_view host() const noexcept;

      std::string_view method() const noexcept;

      std::string_view target() const noexcept;

      std::string_view encoding() const noexcept;

      static constexpr std::size_t maximum_host_bytes = CaptureHost::capacity;
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
      tbc::view<CaptureBuffer, tbc::lt::a> head;
      tbc::view<CaptureBuffer, tbc::lt::a> body;

    private:
      template <std::size_t Capacity>
      static void setRouteField(bool& truncated, SensitiveText<Capacity>& field, std::string_view value) noexcept;

      CaptureBuffer* select(CapturePart part) noexcept;

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

    struct CapturedExchange {
      using Half = Owned<CaptureHalf, ConcurrentMemory>;

      // The halves keep the quota they were captured under, region `a`.
      explicit CapturedExchange(tbc::view<ConcurrentMemory&, tbc::lt::a> memory) noexcept;

      void include(tbc::view<Half, tbc::lt::a> half) noexcept;

      tbc::view<Half, tbc::lt::a> request;
      tbc::view<Half, tbc::lt::a> response;
    };

  }
}

// Interface: exchange_capture/flate_container.cppm
export {
  namespace telar::runtime {

    enum class FlateContainer {
      gzip,
      zlib,
    };

    class FlateEnvelope {
    public:
      static ds::Option<std::size_t> bodyOffset(std::span<const std::uint8_t> input, FlateContainer container) noexcept;

      static constexpr std::size_t footerSize(FlateContainer container) noexcept {
        return container == FlateContainer::gzip ? 2 * sizeof(std::uint32_t) : sizeof(std::uint32_t);
      }

    private:
      enum class GzipFlag : unsigned {
        header_checksum = 2,
        extra = 4,
        name = 8,
        comment = 16,
      };
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
    concept CaptureEventSource = requires(Source& source) {
      { source.descriptor() } noexcept -> std::same_as<int>;
      { source.collect() } noexcept -> std::same_as<bool>;
    };

    struct IgnoreCaptureEvents {
      constexpr int descriptor() const noexcept {
        return -1;
      }

      constexpr bool collect() noexcept {
        return false;
      }
    };

  }
}
