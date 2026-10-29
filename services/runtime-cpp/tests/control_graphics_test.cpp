#include "terminal/terminal.hpp"
#include "graphics/png_decoder.hpp"
#include "graphics/shared_image_storage.hpp"
#include "graphics/media_processor.hpp"
#include "platform/observation_worker.hpp"
#include "check.hpp"
#include <filesystem>
#include <fstream>
#include <thread>
#include <zlib.h>

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
  ObservationWorker worker{processor};
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
  ObservationWorker worker{processor};
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
  check(queue->snapshot().messages == borrowed.count && borrowed.messages[0].front() == 'N');
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
    check(queue->closed() && queue->snapshot().messages == borrowed.count && borrowed.messages[0].front() == 'N');
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
  ObservationWorker worker{processor};
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
}

int main() {
  installPngDecoder();
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  localMedia(memory);
  configuredLimits(memory);
  sharedBudget(memory);
  sharedPaneBudget(memory);
  interactiveAcknowledgements(memory);
  mediaAcknowledgements(system);
  mediaAllocationFailure();
  interactiveAllocationFailure();
  cancelBusyMedia();
  check(memory.liveBytes() == 0);
  std::puts("Native graphics query file, shared memory and budget tests passed");
}
