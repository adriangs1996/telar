module;
#include "tbc/annotations.hpp"

export module telar.runtime.http.content;

import std;
import telar.native.nghttp2;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.base.ds;

// Interface: http/content_codings.cppm
export {
  namespace telar::runtime {

    enum class ContentCoding : std::uint8_t {
      identity,
      gzip,
      deflate,
      brotli,
      zstd,
      unknown,
    };

    // The codings a Content-Encoding value lists, in the order they were applied: at most two, which
    // is all a relay decodes or a capture undoes. Parsing stops at the first empty element or the
    // third coding and says which; codings it does not know are kept as unknown, for the caller to
    // refuse or pass over.
    struct ContentCodings {
      enum class Failure : std::uint8_t {
        none,
        empty,
        too_many,
      };
      static constexpr std::size_t maximum = 2;

      ds::Array<ContentCoding, maximum> codings{};
      std::size_t count = 0;
      Failure failure = Failure::none;

      static ContentCoding coding(std::string_view name) noexcept;

      static ContentCodings parse(std::string_view value) noexcept;

      // Whether every element of `value`, however many, names identity.
      static bool onlyIdentity(std::string_view value) noexcept;

      std::span<const ContentCoding> list() const noexcept;
    };

  }
}

// Interface: http/decoder_memory.cppm
export {
  namespace telar::runtime {

    // The allocator a C codec calls back through its context pointer. Its blocks stay valid whatever is
    // allocated after them, as the erasing allocator and the block table it wraps keep theirs.
    template <Allocator Memory>
    class TBC_SHARED DecoderMemory {
    public:
      explicit DecoderMemory(Memory& memory) noexcept;

      static void* allocate(void* context, std::size_t bytes) noexcept;

      static void* allocateArray(void* context, unsigned count, unsigned size) noexcept;

      static void release(void* context, void* pointer) noexcept;

    private:
      ErasingAllocator<Memory> memory_;
      CAllocationBlocks<ErasingAllocator<Memory>> blocks_;
    };

    extern template class DecoderMemory<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class DecoderMemory<BufferAllocator<ConcurrentMemory>>;
    extern template class DecoderMemory<BufferAllocator<Memory>>;

    extern template class DecoderMemory<Memory>;
    extern template class DecoderMemory<ConcurrentMemory>;

  }
}

// Interface: http/decoded_body.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct DecodedBody {
      explicit DecodedBody(Memory& memory, std::size_t capacity);

      std::span<const std::uint8_t> bytes() const noexcept;

      SensitiveAllocation<Memory> storage;
      std::size_t size = 0;
      bool decoded = false;
      bool truncated = false;
      bool failed = false;
    };

    extern template struct DecodedBody<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template struct DecodedBody<Memory>;
    extern template struct DecodedBody<ConcurrentMemory>;

  }
}

// Interface: http/http2_memory.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Http2Memory {
      using Blocks = CAllocationBlocks<ErasingAllocator<Memory>>;

    public:
      explicit Http2Memory(Memory& memory) noexcept;

      Http2Memory(const Http2Memory&) = delete;
      Http2Memory& operator=(const Http2Memory&) = delete;

      auto callbacks() noexcept -> nghttp2_mem*;

    private:
      static void* allocate(std::size_t size, void* owner) noexcept;

      static void release(void* pointer, void* owner) noexcept;

      static void* allocateZeroed(std::size_t count, std::size_t size, void* owner) noexcept;

      static void* resize(void* pointer, std::size_t size, void* owner) noexcept;

      ErasingAllocator<Memory> memory_;
      // nghttp2 allocates through the blocks, which allocate from the sibling allocator.
      tbc::view<Blocks, tbc::lt::self> blocks_;
      tbc::view<nghttp2_mem, tbc::lt::self> callbacks_;
    };

    extern template class Http2Memory<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class Http2Memory<Memory>;
    extern template class Http2Memory<ConcurrentMemory>;

  }
}
