#include "terminal/control/ascii_ordinary.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>

using namespace telar::runtime::control;

namespace {
std::size_t checked = 0;

void require(bool value) {
  if (!value) {
    std::abort();
  }
}

void verify(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) {
  constexpr std::uint32_t canary = 0xdecafbad;
  auto *before = output.data() - 1;
  *before = canary;
  const auto limit = std::min(input.size(), output.size());
  std::size_t expected = 0;
  while (expected < limit && input[expected] < 0x80 && input[expected] != 0x05 && input[expected] != 0x1b) {
    ++expected;
  }

  const auto actual = ascii_detail::widen(input, output);
  require(actual == expected && *before == canary);
  for (std::size_t index = 0; index < actual; ++index) {
    require(output[index] == input[index]);
  }

  bool eligible = input.size() >= ascii_detail::gate_bytes;
  for (std::size_t index = 0; eligible && index < ascii_detail::gate_bytes; ++index) {
    eligible = input[index] < 0x80 && input[index] != 0x05 && input[index] != 0x1b;
  }
  require(ascii_detail::eligible(input) == eligible);
  ++checked;
}
}

int main() {
  const auto page = static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));
  const auto input_pages = (ascii_detail::codepoint_capacity + 1 + page - 1) / page;
  const auto output_pages = ((ascii_detail::codepoint_capacity + 1) * sizeof(std::uint32_t) + page - 1) / page;
  const auto input_bytes = (input_pages + 2) * page;
  const auto output_bytes = (output_pages + 2) * page;
  auto *input_map = static_cast<std::uint8_t *>(::mmap(nullptr, input_bytes, PROT_NONE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0));
  auto *output_map = static_cast<std::uint8_t *>(::mmap(nullptr, output_bytes, PROT_NONE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0));
  require(input_map != MAP_FAILED && output_map != MAP_FAILED);
  require(::mprotect(input_map + page, input_pages * page, PROT_READ | PROT_WRITE) == 0);
  require(::mprotect(output_map + page, output_pages * page, PROT_READ | PROT_WRITE) == 0);
  auto *input_end = input_map + (input_pages + 1) * page;
  auto *output_end = reinterpret_cast<std::uint32_t *>(output_map + (output_pages + 1) * page);
  constexpr std::size_t capacities[]{0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257};
  for (std::size_t size = 0; size <= 257; ++size) {
    auto *input = input_end - size;
    std::memset(input, 'x', size);
    for (const auto capacity : capacities) {
      auto *output = output_end - capacity;
      verify({input, size}, {output, capacity});
      for (std::size_t position = 0; position < size; ++position) {
        for (const std::uint8_t stop : {0x05, 0x1b, 0x80, 0xff}) {
          input[position] = stop;
          verify({input, size}, {output, capacity});
        }
        input[position] = 'x';
      }
    }
  }

  constexpr std::size_t long_size = ascii_detail::codepoint_capacity + 1;
  auto *input = input_end - long_size;
  std::memset(input, 'x', long_size);
  for (const auto position : {std::size_t{0}, std::size_t{15}, std::size_t{16}, std::size_t{31}, std::size_t{32}, std::size_t{4095}, std::size_t{4096}}) {
    for (unsigned byte = 0; byte < 256; ++byte) {
      input[position] = static_cast<std::uint8_t>(byte);
      for (const auto capacity : {std::size_t{0}, std::size_t{4095}, std::size_t{4096}}) {
        verify({input, long_size}, {output_end - capacity, capacity});
      }
    }
    input[position] = 'x';
  }

  std::uint64_t random = 0x13d8a06c52e9b741;
  for (std::size_t sample = 0; sample < 2000; ++sample) {
    random ^= random << 13;
    random ^= random >> 7;
    random ^= random << 17;
    const auto size = random % (long_size + 1);
    const auto capacity = (random >> 16) % (ascii_detail::codepoint_capacity + 1);
    auto *start = input_end - size;
    for (std::size_t index = 0; index < size; ++index) {
      random ^= random << 13;
      random ^= random >> 7;
      random ^= random << 17;
      start[index] = static_cast<std::uint8_t>(random);
    }
    verify({start, size}, {output_end - capacity, capacity});
  }

  require(::munmap(input_map, input_bytes) == 0 && ::munmap(output_map, output_bytes) == 0);
  std::printf("{\"checked\":%zu,\"differences\":0,\"input_output_guarded\":true}\n", checked);
}
