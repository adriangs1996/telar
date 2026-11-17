#include <cstdint>
#include <cstdio>

import std;
import telar.base.memory.allocators;
import telar.runtime.terminal.control;
import telar.testing;

using telar::testing::check;

#include "control_parser_156.hpp"

namespace {

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::control;

  namespace {

    std::span<const std::uint8_t> bytes(std::string_view text) {
      return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()};
    }

    struct RecordingAllocator {
      SystemAllocator upstream;
      std::array<std::size_t, 128> requests{};
      std::size_t count = 0;
      std::size_t fail_at = 0;
      std::size_t live = 0;

      void* allocate(std::size_t size, std::size_t alignment) noexcept {
        check(count < requests.size());
        requests[count++] = size;
        if (count == fail_at) {
          return nullptr;
        }

        auto* result = upstream.allocate(size, alignment);
        if (result != nullptr) {
          live += size;
        }

        return result;
      }

      void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        check(size <= live);
        live -= size;
        upstream.deallocate(pointer, size, alignment);
      }
    };

    struct Consumer {
      std::vector<std::string> events;
      bool accept = true;
      bool streaming = false;

      void ordinary(std::span<const std::uint8_t> input) {
        events.push_back("ordinary:" + std::string{reinterpret_cast<const char*>(input.data()), input.size()});
      }

      void escapeBoundary() {
        events.emplace_back("escape");
      }

      bool streamComplete() {
        events.emplace_back("stream-complete");
        return accept;
      }

      bool enquire() {
        events.emplace_back("enquire");
        return accept;
      }

      bool borrowableApc(Sequence) const noexcept {
        return true;
      }

      bool streamable(Sequence sequence) {
        events.push_back("header:" + std::string{sequence.body()});
        return streaming;
      }

      bool complete(Sequence sequence) {
        events.push_back("complete:" + std::to_string(static_cast<unsigned>(sequence.kind)) + ":" + std::to_string(static_cast<unsigned>(sequence.ending)) + ":" + std::string{sequence.body()});
        return accept;
      }
    };

    struct Pair {
      RecordingAllocator old_memory;
      RecordingAllocator new_memory;
      BaselineOscParser<RecordingAllocator> old_parser{old_memory};
      Parser<RecordingAllocator> new_parser{new_memory};
      Consumer old_consumer;
      Consumer new_consumer;

      void compare() const {
        check(old_parser.ground() == new_parser.ground());
        check(old_parser.blocked() == new_parser.blocked());
        check(old_parser.overLimit() == new_parser.overLimit());
        check(old_consumer.events == new_consumer.events);
        check(old_memory.count == new_memory.count);
        check(old_memory.requests == new_memory.requests);
        check(old_memory.live == new_memory.live);
      }

      std::size_t feed(std::string_view input) {
        std::size_t old_count = 0;
        std::size_t new_count = 0;
        bool old_failed = false;
        bool new_failed = false;

        try {
          old_count = old_parser.feed(bytes(input), old_consumer);
        } catch (const std::bad_alloc&) {
          old_failed = true;
        }

        try {
          new_count = new_parser.feed(bytes(input), new_consumer);
        } catch (const std::bad_alloc&) {
          new_failed = true;
        }

        check(old_failed == new_failed);
        check(old_failed || old_count == new_count);
        compare();
        return old_failed ? std::string_view::npos : old_count;
      }

      void accept(bool value) {
        old_consumer.accept = value;
        new_consumer.accept = value;
      }

      void discard() {
        old_parser.discard();
        new_parser.discard();
        compare();
        check(old_memory.live == 0);
      }
    };

    void partitions(std::string_view input) {
      for (std::size_t split = 0; split <= input.size(); ++split) {
        Pair pair;

        check(pair.feed(input.substr(0, split)) == split);
        check(pair.feed(input.substr(split)) == input.size() - split);
      }

      Pair pair;

      for (const auto& character : input) {
        check(pair.feed({&character, 1}) == 1);
      }
    }

    void bytesAndBoundaries() {
      for (unsigned value = 0; value <= UINT8_MAX; ++value) {
        auto input = std::string{"\x1b]21;foreground=?;"} + std::string(32, 'a');

        input.push_back(static_cast<char>(value));
        input.append(32, 'b');
        input.append("\a\x1b[5n");
        partitions(input);
      }

      for (const auto length : {255u, 256u, 257u, 511u, 512u, 513u, 1023u, 1024u, 1025u}) {
        auto input = std::string{"\x1b]52;c;"};

        input.append(length - input.size(), 'A');
        input.append("\x1b\\tail");
        partitions(input);
      }

      for (const bool streaming : {false, true}) {
        Pair pair;

        pair.old_consumer.streaming = pair.new_consumer.streaming = streaming;
        pair.feed(std::string_view{"\x1b]5\x00"
                                   "2\x05",
            6});
        pair.feed(";c;payload;more\x1b\\");
        pair.feed("\x1b]21;foreground=?\x18tail\x1b]52;c;payload\x1a");
      }
    }

    void ownershipAndRetainedCapacity() {
      for (const auto warmup_size : {0u, 513u, 4096u}) {
        Pair pair;

        if (warmup_size != 0) {
          std::string apc{"\x1b_Ga=q;"};

          apc.append(warmup_size - apc.size(), 'A');
          apc.append("\x1b\\");
          pair.accept(false);
          const auto consumed = pair.feed(apc);

          check(consumed == apc.size() - 1);
          apc.assign(apc.size(), 'z');
          pair.feed({});
          pair.accept(true);
          pair.feed({});
          pair.feed("\\");
        }

        std::string input{"\x1b]52;c;"};

        input.append(4097, 'A');
        input.append("\x1b\\tail");
        pair.accept(false);
        check(pair.feed(input) == input.size() - 5);
        input.assign(input.size(), 'z');
        pair.feed({});
        pair.feed({});
        pair.accept(true);
        pair.feed({});
        check(pair.feed("\\tail") == 5);
        pair.discard();
      }
    }

    void retainedCapacityFailureAndBellOwnership() {
      Pair pair;

      pair.accept(false);
      std::string apc{"\x1b_Ga=q;"};

      apc.append(513 - apc.size(), 'A');
      apc.append("\x1b\\");
      check(pair.feed(apc) == apc.size() - 1);
      pair.accept(true);
      pair.feed({});
      pair.feed("\\");
      pair.old_memory.fail_at = pair.old_memory.count + 1;
      pair.new_memory.fail_at = pair.new_memory.count + 1;

      const auto request = std::string{"\x1b]52;c;"} + std::string(600, 'B');

      check(pair.feed(request) == std::string_view::npos);
      pair.feed("\a");
      pair.discard();

      pair.accept(false);
      auto blocked = request + "\atail";

      check(pair.feed(blocked) == request.size() + 1);
      blocked.assign(blocked.size(), 'z');
      pair.feed({});
      pair.accept(true);
      pair.feed({});
      check(pair.feed("tail") == 4);
      pair.discard();
    }

    void exactLimit() {
      constexpr auto limit = Parser<SystemAllocator>::osc_limit;

      for (const auto length : {limit - 1, limit, limit + 1}) {
        for (const auto& suffix : {std::string{"\0\a", 2}, std::string{"\x9c\a", 2}, std::string{"\x18"}, std::string{"\x1b\\"}}) {
          Pair pair;
          std::string input{"\x1b]52;c;"};

          input.append(length - input.size(), 'A');
          check(pair.feed(input) == input.size());
          check(pair.feed(suffix) == suffix.size());
          pair.feed("\x1b[5n");
          pair.discard();
        }
      }
    }

    void allocationFailures() {
      for (std::size_t failure = 1; failure <= 7; ++failure) {
        Pair pair;

        pair.old_memory.fail_at = pair.new_memory.fail_at = failure;
        std::string input{"\x1b]52;c;"};

        input.append(16384, 'A');
        check(pair.feed(input) == std::string_view::npos);
        // The failing allocation must preserve the same owned prefix. Completing
        // it before discard makes a partial-copy discrepancy observable.
        pair.feed("\a");
        pair.discard();
        constexpr std::string_view recovery{"\x1b]21;foreground=?\a"};

        check(pair.feed(recovery) == recovery.size());
      }
    }

    void boundedFuzz() {
      std::mt19937 random{0x4f5343};

      for (unsigned run = 0; run < 1000; ++run) {
        Pair pair;
        std::string input{"\x1b]52;c;"};

        input.append(random() % 2048, 'a');
        for (unsigned index = 0; index < 64; ++index) {
          input.push_back(static_cast<char>(random()));
        }

        input.append("\x18\x1b[5n");
        std::size_t offset = 0;

        while (offset < input.size()) {
          const auto size = std::min<std::size_t>(1 + random() % 127, input.size() - offset);

          check(pair.feed(std::string_view{input}.substr(offset, size)) == size);
          offset += size;
        }
      }
    }
  }

  const telar::testing::Case case_bytes_and_boundaries{
      "control_osc_owned.bytes_and_boundaries",
      [] {
        bytesAndBoundaries();
      },
  };
  const telar::testing::Case case_ownership_and_retained_capacity{
      "control_osc_owned.ownership_and_retained_capacity",
      [] {
        ownershipAndRetainedCapacity();
      },
  };
  const telar::testing::Case case_retained_capacity_failure_and_bell_ownership{
      "control_osc_owned.retained_capacity_failure_and_bell_ownership",
      [] {
        retainedCapacityFailureAndBellOwnership();
      },
  };
  const telar::testing::Case case_exact_limit{
      "control_osc_owned.exact_limit",
      [] {
        exactLimit();
      },
  };
  const telar::testing::Case case_allocation_failures{
      "control_osc_owned.allocation_failures",
      [] {
        allocationFailures();
      },
  };
  const telar::testing::Case case_bounded_fuzz{
      "control_osc_owned.bounded_fuzz",
      [] {
        boundedFuzz();
      },
  };

}
