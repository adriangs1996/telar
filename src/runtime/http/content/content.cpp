module telar.runtime.http.content;

import telar.native.nghttp2;
import telar.base.text;

namespace telar::runtime {

  ContentCoding ContentCodings::coding(std::string_view name) noexcept {
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

  ContentCodings ContentCodings::parse(std::string_view value) noexcept {
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

  bool ContentCodings::onlyIdentity(std::string_view value) noexcept {
    TextFields fields{value, ","};

    while (const auto field = fields.next()) {
      if (coding(trimText(*field, " \t")) != ContentCoding::identity) {
        return false;
      }
    }

    return true;
  }

  std::span<const ContentCoding> ContentCodings::list() const noexcept {
    return std::span{codings}.first(count);
  }

  template <Allocator Memory>
  DecoderMemory<Memory>::DecoderMemory(Memory& memory) noexcept
      : memory_(memory),
        blocks_(memory_) {}

  template <Allocator Memory>
  void* DecoderMemory<Memory>::allocate(void* context, std::size_t bytes) noexcept {
    return static_cast<DecoderMemory*>(context)->blocks_.allocate(bytes);
  }

  template <Allocator Memory>
  void* DecoderMemory<Memory>::allocateArray(void* context, unsigned count, unsigned size) noexcept {
    if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
      return nullptr;
    }

    return allocate(context, static_cast<std::size_t>(count) * size);
  }

  template <Allocator Memory>
  void DecoderMemory<Memory>::release(void* context, void* pointer) noexcept {
    static_cast<DecoderMemory*>(context)->blocks_.release(pointer);
  }

  template <Allocator Memory>
  DecodedBody<Memory>::DecodedBody(Memory& memory, std::size_t capacity)
      : storage(memory, capacity) {}

  template <Allocator Memory>
  std::span<const std::uint8_t> DecodedBody<Memory>::bytes() const noexcept {
    return storage.bytes().first(size);
  }

  template <Allocator Memory>
  Http2Memory<Memory>::Http2Memory(Memory& memory) noexcept
      : memory_(memory),
        blocks_(memory_),
        callbacks_{.mem_user_data = &blocks_, .malloc = &allocate, .free = &release, .calloc = &allocateZeroed, .realloc = &resize} {}

  template <Allocator Memory>
  auto Http2Memory<Memory>::callbacks() noexcept -> nghttp2_mem* {
    return &callbacks_;
  }

  template <Allocator Memory>
  void* Http2Memory<Memory>::allocate(std::size_t size, void* owner) noexcept {
    return static_cast<Blocks*>(owner)->allocate(size);
  }

  template <Allocator Memory>
  void Http2Memory<Memory>::release(void* pointer, void* owner) noexcept {
    static_cast<Blocks*>(owner)->release(pointer);
  }

  template <Allocator Memory>
  void* Http2Memory<Memory>::allocateZeroed(std::size_t count, std::size_t size, void* owner) noexcept {
    return static_cast<Blocks*>(owner)->allocateZeroed(count, size);
  }

  template <Allocator Memory>
  void* Http2Memory<Memory>::resize(void* pointer, std::size_t size, void* owner) noexcept {
    return static_cast<Blocks*>(owner)->resize(pointer, size);
  }

  template class DecoderMemory<Memory>;
  template class DecoderMemory<ConcurrentMemory>;
  template struct DecodedBody<Memory>;
  template struct DecodedBody<ConcurrentMemory>;
  template class Http2Memory<Memory>;
  template class Http2Memory<ConcurrentMemory>;
  template class DecoderMemory<BufferAllocator<ConcurrentMemory>>;
  template class DecoderMemory<BufferAllocator<Memory>>;
  template class Http2Memory<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;
  template struct DecodedBody<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;
  template class DecoderMemory<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

}
