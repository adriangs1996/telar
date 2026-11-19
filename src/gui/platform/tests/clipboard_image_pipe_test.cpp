#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "clipboard_pipe_status/clipboard_pipe_status.h"
#include "features/terminal/attachments/sensitive_bytes.hpp"
#include "foundation/core/memory.hpp"
#include "platform/clipboard_image_file.h"
#include "platform/clipboard_image_source.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <ctime>
#include <new>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <thread>
#include <unistd.h>

import telar.testing;
import telar.gui.tests.erasure_allocator;
import telar.gui.platform;
import telar.base.ds;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::platform;
  using telar::gui::test::ErasureAllocator;
  using telar::testing::check;

  // The test allocator behind the Memory interface the pipe is instantiated for.
  struct ErasureMemory : ErasureAllocator {
    MemoryAdapter<ErasureAllocator> adapter{*this};

    telar::Memory& memory() noexcept {
      return adapter;
    }
  };

  struct Pipe {
    Pipe() {
      TelarGuiClipboardImagePipe native{};
      if (telarGuiOpenClipboardImagePipe(&native) != 0) {
        throw std::runtime_error{"CannotCreateTestPipe"};
      }

      reading.reset(native.read_descriptor);
      writing.reset(native.write_descriptor);
    }

    void send(std::span<const std::byte> bytes) const {
      const auto written = ::write(writing.get(), bytes.data(), bytes.size());

      check(written >= 0 && static_cast<std::size_t>(written) == bytes.size(), "the private fixture must write its complete small payload");
    }

    telar::runtime::FileDescriptor reading;
    telar::runtime::FileDescriptor writing;
  };

  constexpr telar::ds::Array binary{std::byte{0xff}, std::byte{0}, std::byte{0x5a}, std::byte{0x80}, std::byte{0x17}, std::byte{0x23}};

  void expectFailure(const Pipe& pipe, ErasureMemory& memory, ClipboardImagePipeLimits limits, ClipboardImageError expected) {
    try {
      static_cast<void>(ClipboardImagePipe::read(memory.memory(), pipe.reading.get(), limits));
      check(false, "a failed transfer must never return an empty or partial attachment");
    } catch (const ClipboardImageFailure& failure) {
      check(failure.code() == expected, "the transfer must retain its exact failure classification");
    }

    check(memory.live == 0 && !memory.dirty_release, "failed and partially received transfer storage must be erased before release");
  }

  void binaryEofKeepsExactLimitsAndDescriptorOwnership() {
    constexpr std::size_t larger_png_limit = 64;

    for (const auto png_limit : telar::ds::Array{binary.size(), larger_png_limit}) {
      Pipe pipe;
      ErasureMemory memory;

      pipe.send(binary);
      pipe.writing.reset();
      check(telarGuiTestClipboardPipeHasReceiveFlags(pipe.reading.get()) != 0, "the native source must own a nonblocking close-on-exec read end");
      {
        const auto bytes = ClipboardImagePipe::read(memory.memory(), pipe.reading.get(), {.source_bytes = binary.size(), .png_bytes = png_limit});

        check(std::ranges::equal(bytes.view(), binary), "EOF at both exact byte limits must return unchanged binary data including NUL");
        check(memory.live == bytes.size(), "a small completed transfer must retain its allocator owner without exceeding the source cap when the PNG cap is larger");
      }

      check(memory.live == 0 && !memory.dirty_release, "completed transfer storage must be erased on final ownership release");
      check(telarGuiTestClipboardDescriptorOpen(pipe.reading.get()) != 0, "the reader must borrow its descriptor without closing its source");
    }
  }

  void overflowAndEmptyTransfersNeverReturnPartialData() {
    constexpr auto below_payload = binary.size() - 1;
    constexpr telar::ds::Array limits{ClipboardImagePipeLimits{.source_bytes = below_payload, .png_bytes = binary.size()}, ClipboardImagePipeLimits{.source_bytes = binary.size(), .png_bytes = below_payload}, ClipboardImagePipeLimits{.source_bytes = below_payload, .png_bytes = below_payload}};
    constexpr telar::ds::Array failures{ClipboardImageError::source_bytes, ClipboardImageError::png_bytes, ClipboardImageError::source_bytes};

    for (std::size_t index = 0; index < limits.size(); ++index) {
      Pipe pipe;
      ErasureMemory memory;

      pipe.send(binary);
      pipe.writing.reset();
      expectFailure(pipe, memory, limits[index], failures[index]);
    }

    Pipe empty;
    ErasureMemory memory;

    empty.writing.reset();
    const ClipboardImagePipeLimits defaults;

    expectFailure(empty, memory, defaults, ClipboardImageError::no_image);
  }

  void allocationFailureRetainsTheSourceAndClearsItsStorage() {
    Pipe pipe;
    ErasureMemory memory;

    memory.fail = true;
    pipe.send(binary);
    pipe.writing.reset();
    try {
      static_cast<void>(ClipboardImagePipe::read(memory.memory(), pipe.reading.get()));
      check(false, "allocation failure must propagate instead of publishing a partial image");
    } catch (const std::bad_alloc&) {
      check(memory.live == 0 && !memory.dirty_release, "failed allocation must not retain transfer storage");
    }

    check(telarGuiTestClipboardDescriptorOpen(pipe.reading.get()) != 0, "allocation failure must leave source descriptor ownership intact");
  }

  void providerActivityCannotRestartTheFiveSecondDeadline() {
    const Pipe pipe;
    ErasureMemory memory;
    std::atomic<bool> delivered = false;
    const auto started = std::chrono::steady_clock::now();
    std::jthread provider{[descriptor = pipe.writing.get(), &delivered] {
      constexpr std::chrono::seconds first_chunk_delay{3};

      std::this_thread::sleep_for(first_chunk_delay);
      constexpr std::byte byte{0x5a};

      delivered.store(::write(descriptor, &byte, sizeof(byte)) == sizeof(byte));
    }};

    const ClipboardImagePipeLimits defaults;

    expectFailure(pipe, memory, defaults, ClipboardImageError::read_failed);
    const auto elapsed = std::chrono::steady_clock::now() - started;

    provider.join();
    constexpr std::chrono::seconds original_deadline{5};
    constexpr std::chrono::milliseconds clock_resolution{1};
    constexpr std::chrono::seconds restarted_deadline_threshold{7};

    check(delivered.load() && elapsed + clock_resolution >= original_deadline && elapsed < restarted_deadline_threshold, "a partially active provider must expire at the original total deadline, not five seconds after its latest chunk");
  }

  const telar::testing::Case case_binary_eof_keeps_exact_limits_and_descriptor_ownership{"clipboard_image_pipe.binary_eof_keeps_exact_limits_and_descriptor_ownership", binaryEofKeepsExactLimitsAndDescriptorOwnership};
  const telar::testing::Case case_overflow_and_empty_transfers_never_return_partial_data{"clipboard_image_pipe.overflow_and_empty_transfers_never_return_partial_data", overflowAndEmptyTransfersNeverReturnPartialData};
  const telar::testing::Case case_allocation_failure_retains_the_source_and_clears_its_storage{"clipboard_image_pipe.allocation_failure_retains_the_source_and_clears_its_storage", allocationFailureRetainsTheSourceAndClearsItsStorage};
  const telar::testing::Case case_provider_activity_cannot_restart_the_five_second_deadline{"clipboard_image_pipe.provider_activity_cannot_restart_the_five_second_deadline", providerActivityCannotRestartTheFiveSecondDeadline};

}
