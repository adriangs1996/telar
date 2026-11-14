module;
#include "tbc/view.hpp"
#include <cstddef>
#include <cstdint>
#include <nghttp2/nghttp2.h>

export module telar.runtime.http.content;

import std;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;
export import telar.base.memory.sensitive;
import telar.base.text;

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

      std::array<ContentCoding, maximum> codings{};
      std::size_t count = 0;
      Failure failure = Failure::none;

      inline static ContentCoding coding(std::string_view name) noexcept {
        if (asciiEqualIgnoreCase(name, "identity")) {
          return ContentCoding::identity;
        }

        if (asciiEqualIgnoreCase(name, "gzip")) {
          return ContentCoding::gzip;
        }

        if (asciiEqualIgnoreCase(name, "deflate")) {
          return ContentCoding::deflate;
        }

        if (asciiEqualIgnoreCase(name, "br")) {
          return ContentCoding::brotli;
        }

        if (asciiEqualIgnoreCase(name, "zstd")) {
          return ContentCoding::zstd;
        }

        return ContentCoding::unknown;
      }

      inline static ContentCodings parse(std::string_view value) noexcept {
        ContentCodings result;
        TextFields fields{value, ","};

        while (const auto field = fields.next()) {
          if (result.count == maximum) {
            result.failure = Failure::too_many;
            break;
          }

          const auto name = trimText(*field, " \t");
          if (name.empty()) {
            result.failure = Failure::empty;
            break;
          }

          result.codings[result.count++] = coding(name);
        }

        return result;
      }

      // Whether every element of `value`, however many, names identity.
      inline static bool onlyIdentity(std::string_view value) noexcept {
        TextFields fields{value, ","};

        while (const auto field = fields.next()) {
          if (coding(trimText(*field, " \t")) != ContentCoding::identity) {
            return false;
          }
        }

        return true;
      }

      inline std::span<const ContentCoding> list() const noexcept {
        return std::span{codings}.first(count);
      }
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
      inline explicit DecoderMemory(Memory& memory) noexcept
          : memory_(memory),
            blocks_(memory_) {}

      inline static void* allocate(void* context, std::size_t bytes) noexcept {
        return static_cast<DecoderMemory*>(context)->blocks_.allocate(bytes);
      }

      inline static void* allocateArray(void* context, unsigned count, unsigned size) noexcept {
        if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
          return nullptr;
        }

        return allocate(context, static_cast<std::size_t>(count) * size);
      }

      inline static void release(void* context, void* pointer) noexcept {
        static_cast<DecoderMemory*>(context)->blocks_.release(pointer);
      }

    private:
      ErasingAllocator<Memory> memory_;
      CAllocationBlocks<ErasingAllocator<Memory>> blocks_;
    };

  }
}

// Interface: http/decoded_body.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct DecodedBody {
      inline explicit DecodedBody(Memory& memory, std::size_t capacity)
          : storage(memory, capacity) {}

      inline std::span<const std::uint8_t> bytes() const noexcept {
        return storage.bytes().first(size);
      }

      SensitiveAllocation<Memory> storage;
      std::size_t size = 0;
      bool decoded = false;
      bool truncated = false;
      bool failed = false;
    };

  }
}

// Interface: http/http2_memory.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Http2Memory {
      using Blocks = CAllocationBlocks<ErasingAllocator<Memory>>;

    public:
      inline explicit Http2Memory(Memory& memory) noexcept
          : memory_(memory),
            blocks_(memory_),
            callbacks_{.mem_user_data = &blocks_, .malloc = &allocate, .free = &release, .calloc = &allocateZeroed, .realloc = &resize} {}

      Http2Memory(const Http2Memory&) = delete;
      Http2Memory& operator=(const Http2Memory&) = delete;

      inline auto callbacks() noexcept -> nghttp2_mem* {
        return &callbacks_;
      }

    private:
      inline static void* allocate(std::size_t size, void* owner) noexcept {
        return static_cast<Blocks*>(owner)->allocate(size);
      }

      inline static void release(void* pointer, void* owner) noexcept {
        static_cast<Blocks*>(owner)->release(pointer);
      }

      inline static void* allocateZeroed(std::size_t count, std::size_t size, void* owner) noexcept {
        return static_cast<Blocks*>(owner)->allocateZeroed(count, size);
      }

      inline static void* resize(void* pointer, std::size_t size, void* owner) noexcept {
        return static_cast<Blocks*>(owner)->resize(pointer, size);
      }

      ErasingAllocator<Memory> memory_;
      // nghttp2 allocates through the blocks, which allocate from the sibling allocator.
      tbc::view<Blocks, tbc::lt::self> blocks_;
      tbc::view<nghttp2_mem, tbc::lt::self> callbacks_;
    };

  }
}
