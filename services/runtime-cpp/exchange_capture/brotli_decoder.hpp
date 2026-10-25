#pragma once

#include "../memory/buffer_allocator.hpp"
#include "decoder_memory.hpp"
#include <array>
#include <brotli/decode.h>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class BrotliDecoder {
public:
  explicit BrotliDecoder(Memory &memory) noexcept : memory_(memory) {
    state_ = BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_);
  }

  ~BrotliDecoder() { BrotliDecoderDestroyInstance(state_); }

  BrotliDecoder(const BrotliDecoder &) = delete;
  BrotliDecoder &operator=(const BrotliDecoder &) = delete;

  std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
    if (state_ == nullptr) {
      return std::nullopt;
    }
    auto available_input = input.size();
    auto available_output = output.size();
    const auto *next_input = input.data();
    auto *next_output = output.data();
    const auto status = BrotliDecoderDecompressStream(state_, &available_input, &next_input, &available_output, &next_output, nullptr);
    if (status == BROTLI_DECODER_RESULT_SUCCESS || (status == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT && available_output == 0)) {
      return output.size() - available_output;
    }
    return std::nullopt;
  }

private:
  DecoderMemory<Memory> memory_;
  BrotliDecoderState *state_ = nullptr;
};

template <Allocator Memory>
BrotliDecoder(Memory &memory) -> BrotliDecoder<Memory>;

template <Allocator Memory>
[[gnu::noinline]] std::optional<std::size_t> decodeBrotli(Memory &memory, std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
  // Isolate scratch storage from the stack frames of the other content decoders.
  constexpr std::size_t decoder_scratch_capacity = 32 * 1024;
  alignas(std::max_align_t) std::array<std::byte, decoder_scratch_capacity> storage;
  BufferAllocator buffered{memory, storage};
  BrotliDecoder decoder{buffered};
  return decoder.decode(input, output);
}

}
