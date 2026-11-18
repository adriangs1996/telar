// Cost of reaching the system allocator through Memory, the virtual interface, against the same
// allocator named by its type, as the Allocator concept does. Each round times both forms on the
// same sizes, alternating which goes first, and the probe prints medians as JSON.
//
//   memory-call-probe [rounds [implementation]]
//
// implementation 0 is the system allocator; with several implementations built in, 1 and 2 put a
// budget and a lock in front of it, and the concept side still calls the system allocator.
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>
#include <vector>

import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::probe {

  Memory& memoryCallSource(int implementation) noexcept;

}

namespace {

  constexpr std::size_t alignment = alignof(std::max_align_t);
  constexpr std::size_t size_count = 4096;
  constexpr std::size_t batch = 32;
  constexpr std::size_t repeats = 64;

  using Sizes = std::span<const std::uint16_t>;

  // One allocation released right away, as a temporary buffer is.
  template <telar::Allocator Memory>
  [[gnu::noinline]] std::uintptr_t pairs(Memory& memory, Sizes sizes) noexcept {
    std::uintptr_t checksum = 0;

    for (const auto size : sizes) {
      auto* pointer = static_cast<std::byte*>(memory.allocate(size, alignment));

      *pointer = std::byte{1};
      checksum ^= reinterpret_cast<std::uintptr_t>(pointer);
      memory.deallocate(pointer, size, alignment);
    }

    return checksum;
  }

  // A run of live allocations released together, as a message or a frame does.
  template <telar::Allocator Memory>
  [[gnu::noinline]] std::uintptr_t batches(Memory& memory, Sizes sizes) noexcept {
    telar::ds::Array<void*, batch> pointers;
    std::uintptr_t checksum = 0;

    for (std::size_t first = 0; first + batch <= sizes.size(); first += batch) {
      for (std::size_t index = 0; index < batch; ++index) {
        pointers.atMut(index) = memory.allocate(sizes[first + index], alignment);
        checksum ^= reinterpret_cast<std::uintptr_t>(pointers[index]);
      }

      for (std::size_t index = 0; index < batch; ++index) {
        memory.deallocate(pointers[index], sizes[first + index], alignment);
      }
    }

    return checksum;
  }

  // A Vec that grows to a few dozen elements, from the allocator.
  template <telar::Allocator Memory>
  [[gnu::noinline]] std::uintptr_t vectors(Memory& memory, Sizes sizes) {
    std::uintptr_t checksum = 0;

    for (const auto size : sizes) {
      telar::ds::Vec<std::uint32_t, Memory> values{memory};
      const std::uint32_t count = size % 48u + 1u;

      for (std::uint32_t value = 0; value < count; ++value) {
        values.push(value);
      }

      checksum += values.size() + values.back();
    }

    return checksum;
  }

  std::vector<std::uint16_t> makeSizes() {
    std::vector<std::uint16_t> sizes(size_count);
    std::uint32_t state = 0x9e3779b9u;

    // Mostly small blocks, as containers and strings ask for, with a tail up to 1 KiB.
    for (auto& size : sizes) {
      state = state * 1664525u + 1013904223u;

      const auto draw = state >> 16;

      size = static_cast<std::uint16_t>(draw % 8 == 0 ? 256 + draw % 769 : 8 + draw % 249);
    }

    return sizes;
  }

  template <typename Kernel>
  double nanosecondsPerOperation(Kernel kernel, Sizes sizes, std::uintptr_t& sink) {
    const auto started = std::chrono::steady_clock::now();

    for (std::size_t repeat = 0; repeat < repeats; ++repeat) {
      sink += kernel(sizes);
    }

    const auto elapsed = std::chrono::steady_clock::now() - started;

    return std::chrono::duration<double, std::nano>(elapsed).count() / static_cast<double>(repeats * sizes.size());
  }

  double median(std::vector<double> values) {
    std::ranges::sort(values);

    const auto middle = values.size() / 2;

    return values.size() % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2;
  }

  struct Result {
    double concept_ns;
    double memory_ns;
    double delta_ns;
    int memory_slower;
  };

  template <typename Concept, typename Virtual>
  Result measure(Concept concept_kernel, Virtual memory_kernel, Sizes sizes, int rounds, std::uintptr_t& sink) {
    std::vector<double> concept_samples;
    std::vector<double> memory_samples;
    std::vector<double> deltas;
    int memory_slower = 0;

    nanosecondsPerOperation(concept_kernel, sizes, sink);
    nanosecondsPerOperation(memory_kernel, sizes, sink);

    for (int round = 0; round < rounds; ++round) {
      double concept_ns = 0;
      double memory_ns = 0;

      if (round % 2 == 0) {
        concept_ns = nanosecondsPerOperation(concept_kernel, sizes, sink);
        memory_ns = nanosecondsPerOperation(memory_kernel, sizes, sink);
      } else {
        memory_ns = nanosecondsPerOperation(memory_kernel, sizes, sink);
        concept_ns = nanosecondsPerOperation(concept_kernel, sizes, sink);
      }

      concept_samples.push_back(concept_ns);
      memory_samples.push_back(memory_ns);
      deltas.push_back(memory_ns - concept_ns);
      memory_slower += memory_ns > concept_ns ? 1 : 0;
    }

    return {
        .concept_ns = median(concept_samples),
        .memory_ns = median(memory_samples),
        .delta_ns = median(deltas),
        .memory_slower = memory_slower,
    };
  }

  void print(const char* name, const Result& result, bool last) {
    std::printf(
        "\"%s\":{\"concept_ns\":%.3f,\"memory_ns\":%.3f,\"delta_ns\":%.3f,\"memory_slower\":%d}%s",
        name,
        result.concept_ns,
        result.memory_ns,
        result.delta_ns,
        result.memory_slower,
        last ? "" : ","
    );
  }

}

int main(int argc, char** argv) {
  const int rounds = argc > 1 ? std::atoi(argv[1]) : 21;
  const int implementation = argc > 2 ? std::atoi(argv[2]) : 0;
  if (argc > 3 || rounds < 1 || rounds > 1000) {
    std::fputs("usage: memory-call-probe [rounds [implementation]]\n", stderr);
    return 2;
  }

  // The implementation is a run-time value, so the compiler cannot fold the choice.
  auto& memory = telar::probe::memoryCallSource(implementation);
  telar::SystemAllocator system;
  const auto sizes = makeSizes();
  std::uintptr_t sink = 0;

  const auto pair_result = measure(
      [&](Sizes values) {
        return pairs(system, values);
      },
      [&](Sizes values) {
        return pairs(memory, values);
      },
      sizes,
      rounds,
      sink
  );
  const auto batch_result = measure(
      [&](Sizes values) {
        return batches(system, values);
      },
      [&](Sizes values) {
        return batches(memory, values);
      },
      sizes,
      rounds,
      sink
  );
  const auto vector_result = measure(
      [&](Sizes values) {
        return vectors(system, values);
      },
      [&](Sizes values) {
        return vectors(memory, values);
      },
      sizes,
      rounds,
      sink
  );

  std::printf(
      "{\"implementations\":%d,\"implementation\":%d,\"rounds\":%d,\"cases\":{",
      MEMORY_CALL_IMPLEMENTATIONS,
      implementation,
      rounds
  );
  print("pair", pair_result, false);
  print("batch", batch_result, false);
  print("vector", vector_result, true);
  std::printf("},\"sink\":%llu}\n", static_cast<unsigned long long>(sink % 2));
  return 0;
}
