#include "check.hpp"
#include "graphics/kitty_cursor.hpp"
#include "graphics/media_processor.hpp"
#include "platform/observation_worker.hpp"
#include "terminal/terminal.hpp"
#include <filesystem>
#include <fstream>

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> mediaBytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

static void testCursorCommands() {
  KittyCursor cursor;
  const auto observe = [&](std::string_view control, std::string_view payload = {}) {
    return cursor.observe(KittyCommandView{0, control, payload, false}, 8, 16);
  };
  check(observe("a=T,s=16,v=32,i=1") == DisplayCells{2, 2});
  check(observe("a=p,i=1,c=4") == DisplayCells{4, 4});
  check(!observe("a=p,i=9,c=4,r=4"));
  check(!observe("a=T,s=16,v=32,i=2,m=1"));
  check(!observe("a=T,s=800,v=800,i=9,m=1"));
  check(observe("m=0") == DisplayCells{2, 2});
  check(observe("a=p,i=2") == DisplayCells{2, 2});
  check(!observe("a=d,d=i,i=2"));
  check(observe("a=p,i=2") == DisplayCells{2, 2});
  check(!observe("a=d,d=I,i=2"));
  check(!observe("a=p,i=2"));
  check(!observe("a=T,s=16,v=32,i=3,C=1"));
  check(observe("a=p,i=3") == DisplayCells{2, 2});
  check(!observe("a=T,s=16,v=32,i=4,U=1"));
  check(!observe("a=T,s=16,v=32,i=5,P=0"));
  check(!observe("a=T,s=16,v=32,i=5,I=1"));
  check(!observe("a=T,s=16,v=32,"));
  check(observe("a=T,s=1__6,v=32") == DisplayCells{2, 2});
  check(observe("a=T,f=100", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB") == DisplayCells{1, 1});
  check(!observe("a=T,f=100,o=z", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"));
  check(observe("a=T,s=640,v=480,w=80,h=32,X=100,Y=100") == DisplayCells{11, 3});
  check(observe("a=T,c=4294967295,r=4294967295") == DisplayCells{UINT32_MAX, UINT32_MAX});
}

static void testMediaCursor(SystemAllocator &memory) {
  Terminal terminal{memory, TerminalSize{10, 4, 8, 16}, TerminalPurpose::separate_media};
  terminal.feed(mediaBytes("x\x1b_Ga=T,s=16,v=32,i=1,q=2;invalid\x1b\\z"));
  terminal.refresh();
  check(terminal.screen.cursor.x == 4 && terminal.screen.cursor.y == 1);
  check(terminal.screen.cells[13].text[0] == 'z');
  check(terminal.responses().empty() && terminal.graphics.images().empty());

  terminal.feed(mediaBytes("\x1b[2;3r\x1b[3;9H\x1b_Ga=T,c=2,r=2,q=2;invalid\x1b\\z"));
  terminal.refresh();
  check(terminal.screen.cursor.x == 1 && terminal.screen.cursor.y == 2);
  check(terminal.screen.cells[20].text[0] == 'z');
}

static void testMediaBatches(SystemAllocator &memory) {
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  {
    auto media = std::make_shared<PaneMedia<SystemAllocator>>(memory, budget, GraphicsLimits{}, TerminalSize{10, 4, 8, 16});
    MediaProcessor<SystemAllocator> processor;
    ObservationWorker worker{processor};
    media->output(mediaBytes("\x1b_Ga=T,s=1,v=1,i=7,q=2,m=1;/wAA"));
    check(media->seal());
    MediaProcessor<SystemAllocator>::Request request;
    request.entries[request.count++].media = media;
    check(worker.submit(request));
    const std::string continuation(MediaBatch::byte_capacity, 'A');
    media->output(mediaBytes(continuation));
    check(media->holdsRead(16 * 1024));
#if TELAR_DIAGNOSTICS
    media->noteHeldRead();
    const auto queued = media->queueMetrics();
    check(queued.events == 2 && queued.event_high_water == 2 && queued.held_reads == 1);
    check(queued.bytes == continuation.size() + std::string_view{"\x1b_Ga=T,s=1,v=1,i=7,q=2,m=1;/wAA"}.size());
    check(queued.byte_high_water == queued.bytes && queued.dropped_bytes == 0);
#endif
    worker.wait([&](const auto &result) {
      check(result.count == 1 && !result.entries[0].reset);
#if TELAR_DIAGNOSTICS
      const auto &metrics = result.entries[0].metrics;
      check(metrics.bytes == std::string_view{"\x1b_Ga=T,s=1,v=1,i=7,q=2,m=1;/wAA"}.size());
      check(metrics.ingest.count == 1 && metrics.resets == 0 && metrics.failures == 0);
#endif
      media->complete();
    });
    check(!media->holdsRead(16 * 1024));
#if TELAR_DIAGNOSTICS
    check(media->queueMetrics().events == 1 && media->queueMetrics().bytes == continuation.size());
    check(media->queueMetrics().byte_high_water == queued.byte_high_water);
    check(media->usedBytes() > 0);
#endif
  }
  check(budget.used() == 0);

  {
    PaneMedia media{memory, budget, GraphicsLimits{}, TerminalSize{10, 4, 8, 16}};
    media.output(mediaBytes("\x1b[2;3H\x1b_Ga=T,f=32,s=1,v=1,i=7,C=1,q=2;/wAA/w==\x1b\\"));
    media.resize(TerminalSize{20, 8, 8, 16});
    check(media.seal() && !media.process());
    media.complete();
    check(media.terminal() && media.terminal()->graphics.images().size() == 1);
    check(media.terminal()->graphics.images().front().pixels.size() == 4);
    const auto placement = media.terminal()->graphics.placements().front();
    check(placement.x == 2 && placement.y == 1);

    const std::string output(MediaBatch::byte_capacity, 'a');
    media.output(mediaBytes(output));
    media.output(mediaBytes("b"));
    check(media.takeDroppedBytes() == MediaBatch::byte_capacity + 1);
#if TELAR_DIAGNOSTICS
    const auto queue = media.queueMetrics();
    check(queue.events == 1 && queue.bytes == 1 && queue.dropped_events == 2);
    check(queue.dropped_bytes == MediaBatch::byte_capacity + 1 && queue.byte_high_water == MediaBatch::byte_capacity);
#endif
    check(media.seal() && media.process());
#if TELAR_DIAGNOSTICS
    check(media.batchMetrics().bytes == 1 && media.batchMetrics().resets == 1);
    check(media.batchMetrics().ingest.count == 1 && media.batchMetrics().failures == 0);
#endif
    media.complete();
    check(media.terminal() && media.terminal()->graphics.images().empty());
#if TELAR_DIAGNOSTICS
    check(media.queueMetrics().events == 0 && media.queueMetrics().bytes == 0);
    check(media.queueMetrics().dropped_bytes == MediaBatch::byte_capacity + 1);
#endif
  }
  check(budget.used() == 0);
}

static void testBase64() {
  std::array<Byte, 8> decoded;
  std::array<char, 12> encoded;
  check(base64::decode("", decoded) == 0);
  check(base64::decode("YQ==", decoded) == 1 && decoded[0] == 'a');
  check(base64::decode("YWI=", decoded) == 2 && decoded[1] == 'b');
  check(base64::decode("YWJj", decoded) == 3 && decoded[2] == 'c');
  check(base64::encode(mediaBytes("abcdefg"), encoded) == 12);
  check(std::string_view{encoded.data(), encoded.size()} == "YWJjZGVmZw==");
  for (const auto malformed : {"a", "a===", "YR==", "YWF=", "YWJj=", "YQ==YQ==", "!!!!"}) {
    check(!base64::decode(malformed, decoded));
  }
  check(!base64::decode("YWJj", std::span{decoded}.first(2)));
  check(!base64::encode(mediaBytes("abcd"), std::span{encoded}.first(7)));

  const std::array<std::string_view, 7> plain{"", "f", "fo", "foo", "foob", "fooba", "foobar"};
  const std::array<std::string_view, 7> expected{"", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"};
  for (std::size_t index = 0; index < plain.size(); ++index) {
    check(base64::encode(mediaBytes(plain[index]), encoded) == expected[index].size());
    check(std::string_view{encoded.data(), expected[index].size()} == expected[index]);
  }

  std::array<Byte, 512> binary;
  std::array<Byte, 512> restored;
  std::array<char, 684> text;
  for (std::size_t index = 0; index < binary.size(); ++index) {
    binary[index] = static_cast<Byte>(index);
  }
  for (std::size_t length = 0; length <= binary.size(); ++length) {
    const auto written = base64::encode(std::span{binary}.first(length), text);
    check(written == (length + 2) / 3 * 4);
    check(base64::decode({text.data(), *written}, restored) == length);
    check(std::equal(binary.begin(), binary.begin() + length, restored.begin()));
    if (*written != 0) {
      check(!base64::encode(std::span{binary}.first(length), std::span{text}.first(*written - 1)));
    }
  }
}

static std::string encodedPath(std::string_view path) {
  std::string encoded((path.size() + 2) / 3 * 4, '\0');
  check(base64::encode(mediaBytes(path), encoded) == encoded.size());
  return encoded;
}

static void testFileInput(SystemAllocator &memory) {
  std::array<char, 64> directory;
  std::strcpy(directory.data(), "/tmp/telar-media-test-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  const auto file_path = (root / "pixels").string();
  {
    std::ofstream file{file_path, std::ios::binary};
    const std::array<Byte, 8> pixels{1, 2, 3, 4, 255, 0, 0, 255};
    file.write(reinterpret_cast<const char *>(pixels.data()), pixels.size());
    check(file.good());
  }
  check(::chmod(file_path.c_str(), 0644) == 0);
  std::filesystem::create_symlink(file_path, root / "symlink");
  check(::mkfifo((root / "pipe").c_str(), 0600) == 0);

  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  MediaAllocator allocator{memory, budget, GraphicsLimits::maximum_pane_bytes};
  MediaTerminal terminal{allocator, TerminalSize{10, 4, 8, 16}, GraphicsLimits{}};
  terminal.feed(mediaBytes("\x1b_Ga=T,t=f,f=32,s=1,v=1,i=7,C=1,q=2,O=4,S=4;" + encodedPath(file_path) + "\x1b\\"));
  terminal.refresh();
  check(terminal.graphics.images().size() == 1);
  const auto pixels = terminal.graphics.images().front().pixels;
  check(pixels.size() == 4 && pixels[0] == 255 && pixels[3] == 255);

  const auto query = [&](std::string_view path) {
    terminal.feed(mediaBytes("\x1b_Ga=q,t=f,f=32,s=1,v=1,i=9;" + encodedPath(path) + "\x1b\\"));
    const auto response = terminal.responses();
    const std::string text{reinterpret_cast<const char *>(response.data()), response.size()};
    terminal.consumeResponses(response.size());
    return text;
  };
  check(query(file_path) == "\x1b_Gi=9;OK\x1b\\");
  for (const auto &path : {(root / "symlink").string(), (root / "pipe").string(), (root / "missing").string(), root.string(), std::string{"relative"}, std::string{"/tmp/a\0b", 8}}) {
    check(query(path) == "\x1b_Gi=9;EBADF:file not accepted\x1b\\");
  }
  check(std::filesystem::exists(file_path));
  std::filesystem::remove_all(root);
}

static void testFrozenImages(SystemAllocator &memory) {
  MediaBudget budget{1024};
  MediaAllocator allocator{memory, budget, 768};
  const std::array<Byte, 4> pixels{255, 0, 0, 255};
  std::array<char, 32> name{};
  {
    FrozenImage frozen{memory, allocator, pixels, false};
    check(frozen.name().empty() && std::ranges::equal(frozen.pixels(), pixels));
    check(budget.used() == pixels.size());
    auto moved = std::move(frozen);
    check(frozen.pixels().empty() && std::ranges::equal(moved.pixels(), pixels));
  }
  check(budget.used() == 0);

  {
    FrozenImage frozen{memory, allocator, pixels, true};
    check(!frozen.name().empty() && frozen.pixels().empty());
    std::copy(frozen.name().begin(), frozen.name().end(), name.begin());
    FileDescriptor opened{::shm_open(name.data(), O_RDONLY, 0)};
    struct stat metadata{};
    check(opened && ::fstat(opened.get(), &metadata) == 0 && (metadata.st_mode & 0777) == 0600);
  }
  check(::shm_open(name.data(), O_RDONLY, 0) == -1 && errno == ENOENT && budget.used() == 0);

  {
    FrozenImage frozen{memory, allocator, pixels, true};
    name.fill(0);
    std::copy(frozen.name().begin(), frozen.name().end(), name.begin());
    frozen.published();
  }
  FileDescriptor transferred{::shm_open(name.data(), O_RDONLY, 0)};
  check(transferred && budget.used() == 0);
  check(::shm_unlink(name.data()) == 0);

  BudgetAllocator failing_memory{memory, 1};
  MediaAllocator failing_budget{failing_memory, budget, 768};
  bool failed = false;
  try {
    FrozenImage rejected{failing_memory, failing_budget, pixels, false};
  } catch (const std::bad_alloc &) {
    failed = true;
  }
  check(failed && budget.used() == 0 && failing_memory.liveBytes() == 0);
}

static void testTransferPreparation(SystemAllocator &memory) {
  MediaBudget budget{1024};
  MediaAllocator allocator{memory, budget, 768};
  const std::array<Byte, 4> pixels{255, 0, 0, 255};
  std::array<GraphicsImageView, 5> images;
  for (std::size_t index = 0; index < images.size(); ++index) {
    images[index] = {.description = {.key = {static_cast<std::uint32_t>(index + 1), 1}, .format = ImageFormat::rgba, .width = 1, .height = 1, .byte_len = pixels.size()}, .pixels = pixels};
  }

  {
    PreparedImages prepared{memory, allocator};
    prepared.prepare(images);
    TELAR_DIAGNOSTIC(check(prepared.takePreparedCount() == 4));
    TELAR_DIAGNOSTIC(check(prepared.takePreparedCount() == 0));
    check(budget.used() == 4 * pixels.size());
    auto first = prepared.take(images[0].description.key);
    check(first && !prepared.take(images[0].description.key));
    first.reset();
    prepared.prepare(images);
    TELAR_DIAGNOSTIC(check(prepared.takePreparedCount() == 1));
    check(!prepared.take(images[0].description.key));
    check(budget.used() == 4 * pixels.size());
    prepared.discardUnwanted([](ImageKey key, bool shared) { return shared && key.image_id == 2; });
    check(budget.used() == pixels.size());
    prepared.clear();
    check(budget.used() == 0);
  }

  {
    TransferRequests requests{memory, allocator};
    check(requests.request(images[0].description.key, false));
    check(!requests.request(images[0].description.key, false));
    check(!requests.take(images[0].description.key, false));
    requests.process(images);
    check(budget.used() == pixels.size());
    auto frozen = requests.take(images[0].description.key, false);
    check(frozen && std::ranges::equal(frozen->pixels(), pixels));
    check(requests.request(images[0].description.key, true));
    requests.process(images);
    check(budget.used() == 2 * pixels.size());
    requests.discardUnwanted([](ImageKey, bool) { return false; });
    check(budget.used() == pixels.size());
    frozen.reset();
    check(budget.used() == 0);
    for (unsigned index = 0; index < 8; ++index) {
      check(requests.request(ImageKey{index + 10, 1}, false));
    }
    check(!requests.request(ImageKey{99, 1}, false));
    requests.process(images);
    check(requests.request(images[0].description.key, false));
  }
  check(budget.used() == 0);
}

#if TELAR_DIAGNOSTICS
static void testGraphicsStorageMetrics(SystemAllocator &memory) {
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  PaneMedia media{memory, budget, GraphicsLimits{}, TerminalSize{10, 4, 8, 16}};
  media.noteSharedTransport(true);
  const auto process = [&](std::string_view bytes) {
    media.output(mediaBytes(bytes));
    check(media.seal());
    const auto busy = media.storageMetrics();
    check(busy.busy_panes == 1 && busy.images == 0 && busy.prepared_bytes == 0);
    check(!media.process());
    media.complete();
    return media.storageMetrics();
  };

  auto sample = process("\x1b_Ga=T,f=32,s=1,v=1,i=1,C=1,q=2;/wAA/w==\x1b\\");
  check(sample.images == 1 && sample.placements == 1 && sample.resident_bytes == 4);
  check(sample.prepared_bytes == 4 && sample.staged_bytes == 0 && sample.loading_bytes == 0);
  check(media.batchMetrics().prepared_frames == 1);
  sample = process("\x1b[?1049h\x1b_Ga=T,f=24,s=1,v=1,i=2,C=1,q=2;/wAA\x1b\\\x1b_Ga=t,f=24,s=2,v=1,i=3,m=1,q=2;AAAA\x1b\\");
  check(sample.images == 2 && sample.placements == 2 && sample.resident_bytes == 7);
  check(sample.loading_bytes == 3 && sample.prepared_bytes == 3);
  media.terminal()->refresh();
  const auto image = media.terminal()->graphics.images().front().description;
  check(image.key.image_id == 2);

  auto prepared = media.takeTransfer(image.key, true);
  check(prepared && prepared->byteCount() == 3 && media.storageMetrics().prepared_bytes == 0);
  check(!media.takeTransfer(image.key, false));
  check(media.seal() && !media.process());
  media.complete();
  check(media.storageMetrics().staged_bytes == 3);
  check(media.batchMetrics().prepared_frames == 0);
  auto staged = media.takeTransfer(image.key, false);
  check(staged && staged->byteCount() == 3 && media.storageMetrics().staged_bytes == 0);
  sample = process("\x1b_Gm=0;AAAA\x1b\\");
  check(sample.loading_bytes == 0 && sample.images == 3 && sample.resident_bytes == 13);
  sample = process("\x1b_Ga=d,d=A,q=2;\x1b\\\x1b[?1049l\x1b_Ga=d,d=A,q=2;\x1b\\");
  check(sample.images == 1 && sample.placements == 0 && sample.resident_bytes == 6 && sample.prepared_bytes == 0);
  sample = process("\x1b[?1049h\x1b_Ga=d,d=I,i=3,q=2;\x1b\\\x1b[?1049l");
  check(sample.images == 0 && sample.placements == 0 && sample.resident_bytes == 0);
}
#endif

void testMedia() {
  SystemAllocator memory;
  testBase64();
  testCursorCommands();
  testMediaCursor(memory);
  testMediaBatches(memory);
  testFileInput(memory);
  testFrozenImages(memory);
  testTransferPreparation(memory);
#if TELAR_DIAGNOSTICS
  testGraphicsStorageMetrics(memory);
#endif
}
