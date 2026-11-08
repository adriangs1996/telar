#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "../diagnostics/line.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "../graphics/png_decoder.hpp"
#include "one_shot_allocator.hpp"
#include <cerrno>
#include <exception>
#include <concepts>
#include <condition_variable>
#include <pthread.h>
#include <sys/types.h>
#include <chrono>
#include <bit>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif
#include <new>
#include "telar_config/terminal/control/policy.hpp"
#include <filesystem>
#include <fstream>
#include <thread>
#include <zlib.h>

#include "graphics/png_decoder.hpp"


import telar.runtime.graphics.synchronizer;
import telar.runtime.platform.request_worker;
import telar.runtime.runtime.execution_service;
import telar.runtime.runtime.media_service;
import telar.platform;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

namespace {
std::span<const Byte> bytes(std::string_view value) {
  return {reinterpret_cast<const Byte *>(value.data()), value.size()};
}

std::string encoded(std::span<const Byte> raw, bool padded = true) {
  std::string result((raw.size() + 2) / 3 * 4, '\0');
  check(base64::encode(raw, result).has_value());
  if (!padded) {
    while (!result.empty() && result.back() == '=') {
      result.pop_back();
    }
  }
  return result;
}

std::string query(auto &terminal, std::string_view header, std::string_view payload) {
  const auto request = "\x1b_Ga=q,i=9," + std::string{header} + ";" + std::string{payload} + "\x1b\\";
  terminal.feed(bytes(request));
  std::string result;
  while (!terminal.responses().empty()) {
    const auto response = terminal.responses();
    result.append(reinterpret_cast<const char *>(response.data()), response.size());
    terminal.consumeResponses(response.size());
  }
  return result;
}

void cursorChunkInterleaving(auto &memory) {
  constexpr std::string_view first = "\x1b_Ga=T,f=24,s=1,v=1,i=7,m=1;/w\x1b\\";
  constexpr std::string_view last = "\x1b_Gm=0;AA\x1b\\";
  constexpr TerminalSize size{80, 24, 9, 18};
  constexpr std::string_view middle_inputs[]{
    {}, "x", "\x05", "\x18", "\x1a", "\x80",
    "\x1b[1;32m", "\x1b[0m", "\x1b[2;3H", "\x1b[?25l", "\x1b[2J",
  };
  for (const auto middle : middle_inputs) {
    for (std::size_t split = 0; split <= first.size(); ++split) {
      Terminal terminal{memory, size, TerminalPurpose::separate_media};
      GraphicsCursor cursor;
      cursor.feed(terminal.handle(), bytes(first.substr(0, split)), size);
      cursor.feed(terminal.handle(), bytes(first.substr(split)), size);
      cursor.feed(terminal.handle(), bytes(middle), size);

      std::uint16_t before_x, before_y, after_x, after_y;
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_X, &before_x));
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &before_y));
      cursor.feed(terminal.handle(), bytes(last.substr(0, last.size() - 1)), size);
      cursor.feed(terminal.handle(), bytes(last.substr(last.size() - 1)), size);
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_X, &after_x));
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &after_y));
      check(after_x == before_x + 1 && after_y == before_y);
    }
  }
}

void localMedia(auto &memory) {
  std::array<char, 64> directory;
  std::strcpy(directory.data(), "/tmp/telar-control-graphics-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  const auto path = (root / "tty-graphics-protocol-image").string();
  const auto wrong = (root / "ordinary-file").string();
  const auto quiet = (root / "tty-graphics-protocol-quiet").string();
  for (const auto &target : {path, wrong, quiet}) {
    std::ofstream file{target, std::ios::binary};
    file.write("\0\0\0\0", 4);
    check(file.good());
  }
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  check(query(terminal, "t=f,s=1,v=1", encoded(bytes(path), false)) == "\x1b_Gi=9;OK\x1b\\");
  check(std::filesystem::exists(path));
  check(query(terminal, "t=t,s=1,v=1", encoded(bytes(wrong))) == "\x1b_Gi=9;EINVAL: temporary file not named correctly\x1b\\");
  check(std::filesystem::exists(wrong));
  std::filesystem::create_symlink(path, root / "symlink");
  check(::mkfifo((root / "pipe").c_str(), 0600) == 0);
  for (const auto &invalid : {(root / "symlink").string(), (root / "pipe").string(), root.string(), std::string{"relative"}, std::string{"/tmp/a\0b", 8}}) {
    check(query(terminal, "t=f,s=1,v=1", encoded(bytes(invalid))) == "\x1b_Gi=9;EINVAL: invalid data\x1b\\");
  }
  check(query(terminal, "t=t,s=1,v=1", encoded(bytes(path))) == "\x1b_Gi=9;OK\x1b\\");
  check(!std::filesystem::exists(path));
  check(query(terminal, "t=t,s=1,v=1,q=2", encoded(bytes(quiet))).empty());
  check(!std::filesystem::exists(quiet));
  auto storage = SharedImageStorage::create(4);
  check(storage.has_value());
  std::ranges::fill(storage->mapping().bytes(), 0);
  const auto shared_name = storage->takeName();
  check(query(terminal, "t=s,s=1,v=1", encoded(bytes(shared_name.data()), false)) == "\x1b_Gi=9;OK\x1b\\");
  FileDescriptor reopened{::shm_open(shared_name.data(), O_RDONLY, 0)};
  check(!reopened && errno == ENOENT);
  std::filesystem::remove_all(root);
}

void configuredLimits(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, GraphicsLimits{.pane_bytes = 128 * 1024}};
  std::vector<Byte> raw(256 * 256 * 4, 0);
  check(query(terminal, "s=256,v=256", encoded(raw)) == "\x1b_Gi=9;ENOMEM: out of memory\x1b\\");
  std::vector<Byte> compressed(::compressBound(raw.size()));
  auto length = static_cast<uLongf>(compressed.size());
  check(::compress(compressed.data(), &length, raw.data(), raw.size()) == Z_OK);
  compressed.resize(length);
  check(query(terminal, "s=256,v=256,o=z", encoded(compressed)) == "\x1b_Gi=9;EINVAL: dimensions too large\x1b\\");
  check(query(terminal, "s=1,v=1", "AAAAAA==") == "\x1b_Gi=9;OK\x1b\\");
  Terminal disabled{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, GraphicsLimits{.pane_bytes = 0}};
  check(query(disabled, "s=1,v=1", "AAAAAA==").empty());
}

void graphicsReplyEncodings(auto &memory) {
  for (const std::uint32_t image : {1u, 9u, 10u, 100u, 1000000000u, UINT32_MAX}) {
    for (const std::uint32_t number : {0u, 1u, UINT32_MAX}) {
      for (const std::uint32_t placement : {0u, 1u, UINT32_MAX}) {
        Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
        const auto header = "i=" + std::to_string(image) + ",I=" + std::to_string(number) + ",p=" + std::to_string(placement) + ",s=1,v=1";
        const auto actual = query(terminal, header, "AAAAAA==");
        std::array<char, 160> expected;
        const auto count = number != 0
          ? placement != 0
            ? std::snprintf(expected.data(), expected.size(), "\x1b_Gi=%u,I=%u,p=%u;EINVAL: image ID and number are mutually exclusive\x1b\\", image, number, placement)
            : std::snprintf(expected.data(), expected.size(), "\x1b_Gi=%u,I=%u;EINVAL: image ID and number are mutually exclusive\x1b\\", image, number)
          : placement != 0
            ? std::snprintf(expected.data(), expected.size(), "\x1b_Gi=%u,p=%u;OK\x1b\\", image, placement)
            : std::snprintf(expected.data(), expected.size(), "\x1b_Gi=%u;OK\x1b\\", image);
        check(count > 0 && static_cast<std::size_t>(count) < expected.size());
        check(actual == std::string_view{expected.data(), static_cast<std::size_t>(count)});
      }
    }
  }
}

void graphicsHeaderParity(auto &memory) {
  const auto verify = [&](std::string_view header, bool accepted) {
    const auto request = "\x1b_G" + std::string{header} + ";AAAAAA==\x1b\\\x1b[6n";
    const std::string expected = accepted ? "\x1b_Gi=9;OK\x1b\\\x1b[1;1R" : "\x1b[1;1R";
    for (std::size_t split = 0; split <= request.size(); ++split) {
      Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
      terminal.feed(bytes(std::string_view{request}.substr(0, split)));
      terminal.feed(bytes(std::string_view{request}.substr(split)));
      std::string actual;
      while (!terminal.responses().empty()) {
        const auto response = terminal.responses();
        actual.append(reinterpret_cast<const char *>(response.data()), response.size());
        terminal.consumeResponses(response.size());
      }
      check(actual == expected);
    }
  };
  verify(",=0,a=q,i=9,s=1,v=1", true);
  verify(",=4294967295,a=q,i=9,s=1,v=1", true);
  for (const auto *key : {"z", "H", "V"}) {
    for (const auto *value : {"2147483647", "+2147483647", "-2147483648", "-0"}) {
      verify("a=q,i=9,s=1,v=1," + std::string{key} + '=' + value, true);
    }
    for (const auto *value : {"2147483648", "4294967295", "-2147483649", "+-1", "+-0"}) {
      verify("a=q,i=9,s=1,v=1," + std::string{key} + '=' + value, false);
    }
  }
  for (const auto *value : {"-0", "-00", "+0"}) {
    verify("a=q,i=9,s=1,v=1,X=" + std::string{value}, true);
  }
  for (const auto *value : {"-1", "+-0", "-+1"}) {
    verify("a=q,i=9,s=1,v=1,X=" + std::string{value}, false);
  }
}

void sharedPaneBudget(auto &memory) {
  constexpr std::size_t pane_limit = 64 * 1024;
  constexpr std::size_t held_bytes = 48 * 1024;
  MediaBudget global{256 * 1024};
  MediaAllocator media{memory, global, pane_limit};
  auto *held = media.allocate(held_bytes, alignof(std::max_align_t));
  check(held != nullptr);
  {
    const GraphicsQueryResources resources{GraphicsLimits{.pane_bytes = pane_limit, .global_bytes = 256 * 1024}, global, &media.usage()};
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, resources};
    const std::vector<Byte> pixels(held_bytes / 2, 0);
    check(query(terminal, "s=128,v=48", encoded(pixels)) == "\x1b_Gi=9;ENOMEM: out of memory\x1b\\");
    check(media.used() == held_bytes);
    media.deallocate(held, held_bytes, alignof(std::max_align_t));
    check(query(terminal, "s=128,v=48", encoded(pixels)) == "\x1b_Gi=9;OK\x1b\\");
    check(media.used() == pixels.size());
    terminal.abortControl();
    check(media.used() == 0);
  }
  check(global.used() == 0);
}

void pngBudgetRecovery(auto &memory) {
  constexpr std::string_view png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
  for (const bool other_pane : {false, true}) {
    MediaBudget budget{64 * 1024};
    const GraphicsQueryResources resources{GraphicsLimits{.pane_bytes = 128 * 1024, .global_bytes = 64 * 1024}, budget};
    Terminal first{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, resources};
    Terminal second{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, resources};
    check(query(first, "f=100", png) == "\x1b_Gi=9;OK\x1b\\");

    // Decoder scratch must not starve a later request, including another pane.
    const std::vector<Byte> pixels(128 * 100 * 4, 0);
    check(query(other_pane ? second : first, "f=32,s=128,v=100", encoded(pixels)) == "\x1b_Gi=9;OK\x1b\\");
    first.abortControl();
    second.abortControl();
    check(budget.used() == 0);
  }
}

void sharedBudget(auto &memory) {
  MediaBudget global{4092};
  {
    const GraphicsQueryResources resources{GraphicsLimits{.pane_bytes = 8192, .global_bytes = 4092}, global};
    Terminal first{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, resources};
    Terminal second{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, resources};
    const std::vector<Byte> pixels(4092, 0);
    check(query(first, "s=31,v=33", encoded(pixels)) == "\x1b_Gi=9;OK\x1b\\");
    check(global.used() == pixels.size());
    check(query(second, "s=1,v=1", "AAAAAA==") == "\x1b_Gi=9;ENOMEM: out of memory\x1b\\");
    first.abortControl();
    check(global.used() == 0);
    check(query(second, "s=1,v=1", "AAAAAA==") == "\x1b_Gi=9;OK\x1b\\");
  }
  check(global.used() == 0);
}

void mediaAcknowledgements(SystemAllocator &memory) {
  auto queue = std::make_shared<PtyResponseQueue>();
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  auto media = std::make_shared<PaneMedia<SystemAllocator>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
  MediaProcessor<SystemAllocator> processor;
  ObservationWorker<decltype(processor) &> worker{std::in_place, processor};
#if TELAR_DIAGNOSTICS
  bool initial = true;
#endif
  const auto process = [&] {
    check(media->seal());
    MediaProcessor<SystemAllocator>::Request request;
    request.entries[request.count++].media = media;
    check(worker.submit(request));
    worker.wait([&](const auto &result) {
      check(result.count == 1);
#if TELAR_DIAGNOSTICS
      if (!initial) {
        check(result.entries[0].metrics.bytes == 0 && result.entries[0].metrics.ingest.count == 0 && result.entries[0].metrics.failures == 0);
      }
#endif
      media->complete();
    });
#if TELAR_DIAGNOSTICS
    initial = false;
#endif
  };
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue->tryPush(bytes("N")));
  }
  std::string commands;
  constexpr unsigned acknowledgements = 200;
  for (unsigned index = 0; index < acknowledgements; ++index) {
    commands.append("\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\");
  }
  media->output(bytes(commands));
  process();
  check(media->holdsRead(1) && !media->idle());
  check(!media->seal());
  check(!media->failed());
  const auto generation = media->terminal()->imageKey(7);
  const auto revision = media->terminal()->graphics.revision();
  std::string received;
  while (!media->idle()) {
    PtyResponseQueue::Producer native{*queue};
    check(!native.tryPush(bytes("unexpected")));
    native.release();
    while (const auto message = queue->peek()) {
      const auto count = std::min<std::size_t>(3, message->size());
      received.append(reinterpret_cast<const char *>(message->data()), count);
      queue->consume(count);
    }
    process();
    const auto current = media->terminal()->imageKey(7);
    check(current.generation == generation.generation && current.image_id == generation.image_id);
    check(media->terminal()->graphics.revision() == revision);
  }
  while (const auto message = queue->peek()) {
    received.append(reinterpret_cast<const char *>(message->data()), message->size());
    queue->consume(message->size());
  }
  std::string expected(PtyResponseQueue::message_capacity, 'N');
  for (unsigned index = 0; index < acknowledgements; ++index) {
    expected.append("\x1b_Gi=7;OK\x1b\\");
  }
  check(received == expected && queue->snapshot().dropped == 0);
  check(!media->holdsRead(1));
  {
    PtyResponseQueue::Producer native{*queue};
    check(native.tryPush(bytes("recovered")));
  }
  media->cancel();
  check(queue->closed() && queue->empty() && media->idle());
  check(budget.used() == 0);
}

void interactiveAcknowledgements(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}};
  std::string commands;
  std::string expected;
  for (unsigned index = 0; index < 200; ++index) {
    commands.append("\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\");
    expected.append("\x1b_Gi=7;OK\x1b\\");
  }
  terminal.feed(bytes(commands));
  check(terminal.hasPendingControl());
  check(terminal.graphics.images().size() == 1);
  const auto generation = terminal.graphics.images()[0].description.key.generation;
  terminal.feed(bytes("\x1b[5n"));
  expected.append("\x1b[0n");
  std::string received;
  while (!terminal.responses().empty()) {
    const auto message = terminal.responses();
    const auto count = std::min<std::size_t>(3, message.size());
    received.append(reinterpret_cast<const char *>(message.data()), count);
    terminal.consumeResponses(count);
  }
  check(received == expected && !terminal.hasPendingControl());
  check(terminal.graphics.images()[0].description.key.generation == generation);
}

struct FailingResponseAllocator {
  static constexpr bool thread_safe = true;
  SystemAllocator system;
  std::atomic<bool> fail = false;
  std::atomic<unsigned> failures = 0;
  std::atomic<bool> pause = false;
  std::atomic<bool> entered = false;
  std::atomic<bool> resume = false;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (pause.load(std::memory_order_relaxed) && size == 4096) {
      entered.store(true, std::memory_order_release);
      while (!resume.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
    }
    if (fail.load(std::memory_order_relaxed) && size == 4096) {
      failures.fetch_add(1, std::memory_order_relaxed);
      return nullptr;
    }
    return system.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    system.deallocate(pointer, size, alignment);
  }
};

void mediaAllocationFailure() {
  FailingResponseAllocator memory;
  auto queue = std::make_shared<PtyResponseQueue>();
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  auto media = std::make_shared<PaneMedia<FailingResponseAllocator>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
  MediaProcessor<FailingResponseAllocator> processor;
  ObservationWorker<decltype(processor) &> worker{std::in_place, processor};
  const auto process = [&] {
    check(media->seal());
    MediaProcessor<FailingResponseAllocator>::Request request;
    request.entries[request.count++].media = media;
    check(worker.submit(request));
    worker.wait([&](const auto &) { media->complete(); });
  };
  constexpr std::string_view command = "\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\";
  media->output(bytes(command));
  process();
  queue->clear();
  for (unsigned index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue->tryPush(bytes("N")));
  }
  const auto borrowed = queue->peekBatch();
  std::string commands;
  for (unsigned index = 0; index < 200; ++index) {
    commands.append(command);
  }
  memory.fail.store(true, std::memory_order_relaxed);
  media->output(bytes(commands));
  process();
  check(memory.failures.load(std::memory_order_relaxed) != 0);
  check(media->failed() && media->terminal() == nullptr && queue->closed());
  check(queue->snapshot().messages == borrowed.count && borrowed.message(0).front() == 'N');
  check(!media->seal() && media->idle());
  check(queue->empty() && queue->snapshot().dropped == 0 && budget.used() == 0);
}

void interactiveAllocationFailure() {
  FailingResponseAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    auto queue = std::make_shared<PtyResponseQueue>();
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::interactive, queue};
    constexpr std::string_view command = "\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\";
    terminal.feed(bytes(command));
    terminal.consumeResponses(terminal.responses().size());
    for (unsigned index = 0; index < PtyResponseQueue::message_capacity; ++index) {
      check(queue->tryPush(bytes("N")));
    }
    const auto borrowed = queue->peekBatch();
    std::string commands;
    for (unsigned index = 0; index < 200; ++index) {
      commands.append(command);
    }
    upstream.fail.store(true, std::memory_order_relaxed);
    bool failed = false;
    try {
      terminal.feed(bytes(commands));
    } catch (const TerminalError &) {
      failed = true;
    }
    check(failed && upstream.failures.load(std::memory_order_relaxed) != 0);
    check(queue->closed() && queue->snapshot().messages == borrowed.count && borrowed.message(0).front() == 'N');
    terminal.abortControl();
    check(!terminal.hasPendingControl() && queue->empty() && queue->snapshot().dropped == 0);
    upstream.fail.store(false, std::memory_order_relaxed);
    terminal.feed(bytes("\x1b[5n"));
    check(terminal.responses().empty());
  }
  check(memory.liveBytes() == 0);
}

void cancelBusyMedia() {
  FailingResponseAllocator memory;
  auto queue = std::make_shared<PtyResponseQueue>();
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  auto media = std::make_shared<PaneMedia<FailingResponseAllocator>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
  MediaProcessor<FailingResponseAllocator> processor;
  ObservationWorker<decltype(processor) &> worker{std::in_place, processor};
  constexpr std::string_view command = "\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\";
  const auto submit = [&] {
    check(media->seal());
    MediaProcessor<FailingResponseAllocator>::Request request;
    request.entries[request.count++].media = media;
    check(worker.submit(request));
  };
  media->output(bytes(command));
  submit();
  worker.wait([&](const auto &) { media->complete(); });
  queue->clear();
  for (unsigned index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue->tryPush(bytes("N")));
  }
  std::string commands;
  for (unsigned index = 0; index < 200; ++index) {
    commands.append(command);
  }
  memory.pause.store(true, std::memory_order_relaxed);
  media->output(bytes(commands));
  submit();
  while (!memory.entered.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  media->cancel();
  check(media->busy() && queue->closed());
  memory.resume.store(true, std::memory_order_release);
  worker.wait([&](const auto &) { media->complete(); });
  check(media->idle() && media->terminal() == nullptr && queue->empty());
  check(!media->failed() && budget.used() == 0);
  media->output(bytes(command));
  check(!media->seal() && media->idle());
}

void orderedMediaBoundaries() {
  constexpr std::string_view first = "\x1b_Ga=t,f=24,s=1,v=1,i=7;/wAA\x1b\\";
  constexpr std::string_view second = "\x1b_Ga=t,f=24,s=1,v=1,i=8;AP8A\x1b\\";
  const std::vector<Byte> pixels(16 * 16 * 4, 0);
  const std::string large_query = "\x1b_Ga=q,i=9,s=16,v=16;" + encoded(pixels) + "\x1b\\";
  const std::string input = std::string{"\x1b[5n"} + std::string{first} + "\x1b[5n" + large_query + std::string{second} + "\x1b[5n";
  const std::string expected = "\x1b[0n\x1b_Gi=7;OK\x1b\\\x1b[0n\x1b_Gi=9;OK\x1b\\\x1b_Gi=8;OK\x1b\\\x1b[0n";
  for (std::size_t split = 0; split <= input.size(); ++split) {
    SystemAllocator system;
    BudgetAllocator memory{system, 64 * 1024 * 1024};
    MediaBudget budget{GraphicsLimits::maximum_global_bytes};
    auto queue = std::make_shared<PtyResponseQueue>();
    auto shared_media = std::make_shared<PaneMedia<decltype(memory)>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
    auto &media = *shared_media;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, queue};
    terminal.attachMedia(shared_media);
    terminal.feed(bytes(input).first(split));
    terminal.feed(bytes(input).subspan(split));
    std::string actual;
    std::size_t jobs = 0;
    for (unsigned attempt = 0; terminal.hasPendingControl() || !media.idle() || !queue->empty(); ++attempt) {
      check(attempt < 100);
      if (media.seal()) {
        media.process();
        media.complete();
        ++jobs;
      }
      terminal.resumeControl();
      if (const auto response = queue->readable(); !response.empty()) {
        const auto count = std::min<std::size_t>(3, response.size());
        actual.append(reinterpret_cast<const char *>(response.data()), count);
        terminal.consumeResponses(count);
      }
    }
    check(actual == expected && jobs >= 2 && queue->snapshot().dropped == 0);
  }

  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  auto queue = std::make_shared<PtyResponseQueue>();
  auto shared_media = std::make_shared<PaneMedia<decltype(memory)>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
  auto &media = *shared_media;
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, queue};
  terminal.attachMedia(shared_media);
  std::string quiet;
  constexpr unsigned commands = 32;
  for (unsigned index = 0; index < commands; ++index) {
    quiet += "\x1b_Ga=q,q=2,i=9,s=1,v=1;AAAAAA==\x1b\\";
  }
  terminal.feed(bytes(quiet));
  unsigned jobs = 0;
  while (terminal.hasPendingControl() || !media.idle()) {
    check(media.seal());
    media.process();
    media.complete();
    ++jobs;
    terminal.resumeControl();
    check(queue->empty());
  }
  check(jobs >= commands && jobs <= commands + 1);
}

void orderedResizeFailure() {
  for (bool start_worker : {false, true}) {
    SystemAllocator memory;
    RuntimeModel model{memory};
    ClientStore<SystemAllocator> clients{memory};
    LimitService<SystemAllocator> limits;
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/control-resize-failure.sock"}};
    MediaService<SystemAllocator, decltype(poller), decltype(limits)> service{poller, limits};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    const TabLocation location{.workspace = {.id = 7}, .tab_id = 1};
    auto &failed = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
    auto &healthy = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
    failed.media->resize({80, 25, 9, 18});
    for (unsigned index = 0; index < MediaBatch::event_capacity / 2; ++index) {
      failed.media->output(bytes("x"));
      if (index + 1 < MediaBatch::event_capacity / 2) {
        failed.media->resize({80, 25, 9, 18});
      }
    }
    failed.resize({80, 26, 9, 18});
    check(failed.media->failed() && failed.pty_responses->closed() && !failed.output_closed);
    if (start_worker) {
      service.start(model, clients, panes);
    } else {
      panes.flushInput(failed);
    }
    check(failed.output_closed && failed.close_requested && !failed.terminal.hasPendingControl());
    healthy.terminal.feed(bytes("\x1b[5n"));
    check(!healthy.output_closed && healthy.terminal.responses().size() == 4);
    service.finish(model);
    const auto failed_id = failed.id;
    const auto healthy_id = healthy.id;
    panes.remove(model, clients, failed_id);
    panes.remove(model, clients, healthy_id);
  }
}

void semanticFailureDuringResume() {
  control_test::OneShotAllocator upstream;
  BudgetAllocator budget{upstream, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    RuntimeModel model{memory};
    ClientStore<decltype(memory)> clients{memory};
    LimitService<decltype(memory)> limits;
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/control-semantic-failure.sock"}};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    const TabLocation location{.workspace = {.id = 7}, .tab_id = 1};
    auto &failed = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
    auto &healthy = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
    for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
      failed.terminal.feed(bytes("\x1b[5n"));
    }
    failed.terminal.feed(bytes("\x1b[5n\x1b]2;unavailable\x1b\\\x1b[5n"));
    check(failed.terminal.hasPendingControl() && !failed.pty_responses->hasCapacity());

    upstream.failNext();
    panes.flushInput(failed);
    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(failed.terminal.handle(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    check(processing_error && upstream.failures() == 1);
    check(failed.output_closed && failed.close_requested && !failed.terminal.hasPendingControl());
    check(failed.pty_responses->closed() && failed.pty_responses->empty());
    panes.flushInput(failed);
    check(failed.pty_responses->empty() && !failed.terminal.hasPendingControl());

    healthy.terminal.feed(bytes("\x1b[5n"));
    const auto reply = healthy.terminal.responses();
    check(!healthy.output_closed && std::string_view{reinterpret_cast<const char *>(reply.data()), reply.size()} == "\x1b[0n");
    const auto failed_id = failed.id;
    const auto healthy_id = healthy.id;
    panes.remove(model, clients, failed_id);
    panes.remove(model, clients, healthy_id);
  }
  check(budget.liveBytes() == 0 && upstream.liveBytes() == 0);
}

void retainedAtomicFrames() {
  std::array<char, 64> directory;
  std::strcpy(directory.data(), "/tmp/telar-control-atomic-boundary-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  const auto path = (root / "pixels").string();
  {
    std::ofstream file{path, std::ios::binary};
    file.write("\xff\0\0\xff", 4);
    check(file.good());
  }
  const auto name = encoded(bytes(path));
  const auto frame = std::string{AtomicFrame::cursor_save} + std::string{AtomicFrame::prefix} + "a=T,t=f,f=32,s=1,v=1,i=7,p=1,C=1,q=2;" + name + std::string{AtomicFrame::suffix} + std::string{AtomicFrame::cursor_restore};
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  auto queue = std::make_shared<PtyResponseQueue>();
  auto shared_media = std::make_shared<PaneMedia<decltype(memory)>>(memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 9, 18}, queue);
  auto &media = *shared_media;
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, queue};
  terminal.attachMedia(shared_media);
  std::string input;
  for (unsigned index = 0; index < 9; ++index) {
    input += frame;
  }
  input += "\x1b[5n";
  terminal.feed(bytes(input));
  check(queue->empty() && terminal.hasPendingControl());
  check(media.seal() && !media.process());
#if TELAR_DIAGNOSTICS
  check(media.batchMetrics().direct_frames == 1 && media.batchMetrics().discarded_frames == 7);
#endif
  media.complete();
  check(media.terminal()->graphics.images().size() == 1);
  const auto first = media.terminal()->imageKey(7);
  terminal.resumeControl();
  check(queue->empty() && media.seal() && !media.process());
#if TELAR_DIAGNOSTICS
  check(media.batchMetrics().direct_frames == 1 && media.batchMetrics().discarded_frames == 0);
#endif
  media.complete();
  const auto second = media.terminal()->imageKey(7);
  check(first.generation != second.generation);
  terminal.resumeControl();
  check(terminal.responses().size() == 4 && !terminal.hasPendingControl());
  std::filesystem::remove_all(root);
}

void checkedAtomicSharedMemory() {
  constexpr std::size_t size = 4096;
  auto storage = SharedImageStorage::create(size);
  check(storage.has_value());
  std::ranges::fill(storage->mapping().bytes(), 23);
  const auto name = storage->takeName();
  FileDescriptor writer{::shm_open(name.data(), O_RDWR, 0)};
  check(static_cast<bool>(writer));
  const auto payload = encoded(bytes(name.data()));
  const auto pixels = GraphicsFramePixels::open({payload, size, size, GraphicsInputMedium::shared_memory});
  check(pixels.has_value());
  std::array<Byte, size> output;
  check(pixels->copyTo(output) && output.front() == 23 && output.back() == 23);
  const auto truncated = ::ftruncate(writer.get(), 0);
#if defined(__APPLE__)
  // Darwin may reject resizing an already-sized POSIX SHM object.
  check(truncated == 0 || errno == EINVAL);
#else
  check(truncated == 0);
#endif
  if (truncated == 0) {
    check(!pixels->copyTo(output));
  }
  FileDescriptor reopened{::shm_open(name.data(), O_RDONLY, 0)};
  check(!reopened && errno == ENOENT);

  std::array<char, 64> path;
  std::strcpy(path.data(), "/tmp/telar-control-copy-XXXXXX");
  FileDescriptor backing{::mkstemp(path.data())};
  check(static_cast<bool>(backing) && ::unlink(path.data()) == 0);
  output.fill(41);
  check(::write(backing.get(), output.data(), output.size()) == static_cast<ssize_t>(output.size()));
  check(GraphicsChildSharedMemory::read(backing.get(), output, 0) && output.front() == 41);
  check(::ftruncate(backing.get(), 0) == 0);
  check(!GraphicsChildSharedMemory::read(backing.get(), output, 0));
}

std::vector<Byte> pngPixels(unsigned depth, unsigned color, unsigned interlace, std::span<const Byte> raw) {
  std::vector<Byte> result{137, 80, 78, 71, 13, 10, 26, 10};
  const auto integer = [&](std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) {
      result.push_back(static_cast<Byte>(value >> shift));
    }
  };
  const auto chunk = [&](std::string_view kind, std::span<const Byte> payload) {
    integer(static_cast<std::uint32_t>(payload.size()));
    const auto start = result.size();
    result.insert(result.end(), kind.begin(), kind.end());
    result.insert(result.end(), payload.begin(), payload.end());
    integer(static_cast<std::uint32_t>(::crc32(0, result.data() + start, result.size() - start)));
  };
  const std::array<Byte, 13> header{0, 0, 0, 3, 0, 0, 0, 3, static_cast<Byte>(depth), static_cast<Byte>(color), 0, 0, static_cast<Byte>(interlace)};
  chunk("IHDR", header);
  if (color == 3) {
    constexpr std::array<Byte, 12> palette{255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255};
    constexpr std::array<Byte, 4> alpha{255, 128, 0, 255};
    chunk("PLTE", palette);
    chunk("tRNS", alpha);
  }

  std::vector<Byte> compressed(::compressBound(raw.size()));
  auto length = static_cast<uLongf>(compressed.size());
  check(::compress(compressed.data(), &length, raw.data(), raw.size()) == Z_OK);
  compressed.resize(length);
  chunk("IDAT", compressed);
  chunk("IEND", {});
  return result;
}

void pngPixelFormats() {
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  GhosttyAllocatorBridge allocator{memory};
  constexpr std::array<std::array<Byte, 4>, 4> palette{{{255, 0, 0, 255}, {0, 255, 0, 128}, {0, 0, 0, 0}, {0, 0, 255, 255}}};
  constexpr std::array<unsigned, 9> indices{0, 1, 2, 3, 0, 1, 2, 3, 0};
  std::vector<Byte> expected;
  for (const auto index : indices) {
    expected.insert(expected.end(), palette[index].begin(), palette[index].end());
  }
  const auto verify = [&](const std::vector<Byte> &png) {
    GhosttySysImage decoded{};
    check(decodePngImage(allocator.get(), png, decoded));
    check(decoded.width == 3 && decoded.height == 3 && decoded.data_len == expected.size());
    check(std::equal(expected.begin(), expected.end(), decoded.data));
    ghostty_free(allocator.get(), decoded.data, decoded.data_len);
    check(memory.liveBytes() == 0);
  };
  constexpr std::array<Byte, 6> indexed{0, 0x18, 0, 0xc4, 0, 0xb0};
  verify(pngPixels(2, 3, 0, indexed));

  std::vector<Byte> rgba16;
  for (std::size_t row = 0; row < 3; ++row) {
    rgba16.push_back(0);
    for (std::size_t column = 0; column < 12; ++column) {
      // Samples multiplied by 257 have an exact independent 8-bit result.
      const auto sample = expected[row * 12 + column];
      rgba16.insert(rgba16.end(), {sample, sample});
    }
  }
  verify(pngPixels(16, 6, 0, rgba16));

  std::vector<Byte> adam7;
  // Nonempty scanlines of the seven Adam7 passes for a 3x3 image.
  constexpr unsigned absent = indices.size();
  constexpr std::array<std::array<unsigned, 3>, 6> rows{{{0, absent, absent}, {2, absent, absent}, {6, 8, absent}, {1, absent, absent}, {7, absent, absent}, {3, 4, 5}}};
  for (const auto &row : rows) {
    adam7.push_back(0);
    for (const auto pixel : row) {
      if (pixel != absent) {
        adam7.insert(adam7.end(), expected.begin() + pixel * 4, expected.begin() + pixel * 4 + 4);
      }
    }
  }
  verify(pngPixels(8, 6, 1, adam7));
}

struct FailingCodecAllocator {
  SystemAllocator upstream;
  unsigned remaining;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (remaining == 0) {
      return nullptr;
    }
    --remaining;
    return upstream.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    upstream.deallocate(pointer, size, alignment);
  }
};

void pngFailureCleanup() {
  // Independent 1x1 RGBA red PNG fixture: Python zlib plus PNG CRC32 chunks.
  constexpr std::array<Byte, 70> png{
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52,
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 0x0d,
      0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0, 5, 0, 1, 0xff,
      0x89, 0x99, 0x3d, 0x1d, 0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  };
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  GhosttyAllocatorBridge allocator{memory};
  for (std::size_t length = 0; length <= png.size(); ++length) {
    GhosttySysImage image{};
    const bool decoded = decodePngImage(allocator.get(), std::span{png}.first(length), image);
    constexpr std::size_t complete_frame_bytes = 58;
    check(decoded == (length >= complete_frame_bytes));
    if (decoded) {
      const std::array<Byte, 4> expected{255, 0, 0, 255};
      check(image.width == 1 && image.height == 1 && image.data_len == expected.size());
      check(std::equal(expected.begin(), expected.end(), image.data));
      ghostty_free(allocator.get(), image.data, image.data_len);
    }
    check(memory.liveBytes() == 0);
  }
  for (std::size_t position = 0; position < png.size(); ++position) {
    auto mutated = png;
    mutated[position] ^= 0x80;
    GhosttySysImage image{};
    if (decodePngImage(allocator.get(), mutated, image)) {
      ghostty_free(allocator.get(), image.data, image.data_len);
    }
    check(memory.liveBytes() == 0);
  }
  GhosttySysImage image{};
  check(!decodePngImage(allocator.get(), png, image, 2) && memory.liveBytes() == 0);

  for (unsigned permitted = 0; permitted <= 3; ++permitted) {
    FailingCodecAllocator upstream{{}, permitted};
    BudgetAllocator budget{upstream, 64 * 1024 * 1024};
    GhosttyAllocatorBridge bridge{budget};
    GhosttySysImage decoded{};
    const bool success = decodePngImage(bridge.get(), png, decoded);
    check(success == (permitted == 3));
    if (success) {
      ghostty_free(bridge.get(), decoded.data, decoded.data_len);
    } else {
      check(decoded.data == nullptr && decoded.data_len == 0);
    }
    check(budget.liveBytes() == 0);
  }
}
}

int main() {
  installPngDecoder();
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  cursorChunkInterleaving(memory);
  localMedia(memory);
  configuredLimits(memory);
  graphicsReplyEncodings(memory);
  graphicsHeaderParity(memory);
  sharedBudget(memory);
  pngBudgetRecovery(memory);
  sharedPaneBudget(memory);
  interactiveAcknowledgements(memory);
  mediaAcknowledgements(system);
  mediaAllocationFailure();
  interactiveAllocationFailure();
  cancelBusyMedia();
  orderedMediaBoundaries();
  orderedResizeFailure();
  semanticFailureDuringResume();
  retainedAtomicFrames();
  checkedAtomicSharedMemory();
  pngFailureCleanup();
  pngPixelFormats();
  check(memory.liveBytes() == 0);
  std::puts("Native graphics query file, shared memory and budget tests passed");
}
