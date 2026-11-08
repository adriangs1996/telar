#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <sys/stat.h>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.client_peer;
import telar.runtime.graphics.synchronizer;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

static void feedGraphics(Terminal<SystemAllocator> &terminal, std::string_view bytes) {
  terminal.feed({reinterpret_cast<const Byte *>(bytes.data()), bytes.size()});
}

static void testMediaBudget(SystemAllocator &system) {
  MediaBudget budget{1024};
  MediaAllocator first{system, budget, 768};
  MediaAllocator second{system, budget, 768};
  void *allocation = first.allocate(640, 16);
  check(allocation != nullptr && first.used() == 640 && budget.used() == 640);
  check(first.allocate(129, 16) == nullptr && second.allocate(385, 16) == nullptr);
  void *other = second.allocate(384, 16);
  check(other != nullptr && budget.used() == 1024);
  first.deallocate(allocation, 640, 16);
  second.deallocate(other, 384, 16);
  check(first.used() == 0 && second.used() == 0 && budget.used() == 0);

  BudgetAllocator failing{system, 1};
  MediaAllocator rejected{failing, budget, 768};
  check(rejected.allocate(2, 16) == nullptr && rejected.used() == 0 && budget.used() == 0);
  check(first.reserve(768) && !first.reserve(1));
  first.release(768);

  std::array<std::thread, 4> workers;
  for (auto &worker : workers) {
    worker = std::thread{[&] {
      for (unsigned iteration = 0; iteration < 1000; ++iteration) {
        if (void *bytes = first.allocate(128, 16)) {
          std::memset(bytes, 0xa5, 128);
          first.deallocate(bytes, 128, 16);
        }
      }
    }};
  }
  for (auto &worker : workers) {
    worker.join();
  }
  check(first.used() == 0 && budget.used() == 0);
}

static void testKittyFraming() {
  const auto bytes = [](std::string_view text) { return std::span{reinterpret_cast<const Byte *>(text.data()), text.size()}; };
  const std::string payload = "YWJj" + std::string(124, 'A');
  const std::string command = "before\x1b_Ga=T,i=17;" + payload + "\x1b\\after";
  for (std::size_t split = 0; split <= command.size(); ++split) {
    KittyCommandScanner scanner;
    unsigned found = 0;
    for (const auto part : {std::string_view{command}.substr(0, split), std::string_view{command}.substr(split)}) {
      auto rest = bytes(part);
      while (const auto parsed = scanner.next(rest)) {
        check(parsed->control == "a=T,i=17" && parsed->payload_prefix == std::string_view{payload}.substr(0, 64) && !parsed->truncated);
        rest = rest.subspan(parsed->end);
        ++found;
      }
    }
    check(found == 1);
  }

  for (unsigned terminator = 0; terminator <= UINT8_MAX; ++terminator) {
    const bool ends = terminator == 0x18 || terminator == 0x1a || terminator == 0x1b || (terminator >= 0x80 && terminator <= 0x97) || (terminator >= 0x99 && terminator <= 0x9d);
    for (unsigned offset = 0; offset < 32; ++offset) {
      const auto text = std::string{"\x1b_Gi=1;YWJj"} + std::string(64 + offset, 'A') + static_cast<char>(terminator);
      KittyCommandScanner scanner;
      check(scanner.next(bytes(text)).has_value() == ends);
    }
  }

  KittyCommandScanner bounded;
  const auto long_command = std::string{"\x1b_G"} + std::string(257, 'x') + ";" + std::string(65, 'y') + "\x1b\\";
  const auto parsed = bounded.next(bytes(long_command));
  check(parsed && parsed->truncated && parsed->control.size() == 256 && parsed->payload_prefix.size() == 64);

  KittyFraming framing;
  check(!framing.touches(bytes("ß and plain text")));
  check(!framing.touches(bytes("\x1b_")));
  check(framing.touches(bytes("G")) && framing.inside());
  check(framing.touches(bytes("i=1;YWJj")) && framing.inside());
  check(framing.touches(bytes("\x1b\\")) && !framing.inside());
  check(!framing.touches(bytes("plain")));
}

static void testGraphicsProjection(SystemAllocator &memory) {
  Terminal terminal{memory, TerminalSize{.cols = 80,
                                         .rows = 24,
                                         .cell_width_px = 8,
                                         .cell_height_px = 16}};
  feedGraphics(terminal, "\x1b_Ga=T,f=32,s=1,v=1,i=17,p=5,q=2;/wAA/w==\x1b\\");
  check(terminal.graphics.images().size() == 1);
  const auto &image = terminal.graphics.images().front();
  check(image.description.key.image_id == 17 && image.description.format == ImageFormat::rgba);
  check(image.pixels.size() == 4 && image.pixels[0] == 255 && image.pixels[3] == 255);
  check(terminal.graphics.placements().size() == 1);
  const auto placement = terminal.graphics.placements().front();
  check(placement.placement_id == 5 && placement.virtual_id == (std::uint64_t{1} << 32) + 6);
  check(placement.source_width == 1 && placement.source_height == 1);
  const auto revision = terminal.graphics.revision();
  feedGraphics(terminal, "ordinary text");
  check(terminal.graphics.revision() == revision);
  feedGraphics(terminal, "\x1b_Ga=p,i=17,p=6,U=1,c=2,r=3,q=2;\x1b\\");
  check(terminal.graphics.placements().size() == 2);
  check(std::ranges::any_of(terminal.graphics.placements(), [](const auto &value) { return value.placement_id == 6 && value.location == PlacementLocation::placeholders && value.columns == 2 && value.rows == 3; }));
  feedGraphics(terminal, "\x1b_Ga=d,d=I,i=17,q=2;\x1b\\");
  check(terminal.graphics.images().empty() && terminal.graphics.placements().empty());

  for (unsigned identity = 1; identity <= 40; ++identity) {
    std::array<char, 128> command;
    const int length = std::snprintf(command.data(), command.size(), "\x1b_Ga=t,f=24,s=1,v=1,i=%u,q=2;/wAA\x1b\\", identity);
    feedGraphics(terminal, {command.data(), static_cast<std::size_t>(length)});
  }
  check(terminal.graphics.images().size() == graphics_image_count);
  check(std::ranges::none_of(terminal.graphics.images(), [](const auto &value) { return value.description.key.image_id <= 8; }));
}

static void testGraphicsTransfer(SystemAllocator &memory, bool shared) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  ClientPeer peer{memory, model, clients, ClientRole::control};
  auto media = std::allocate_shared<PaneMedia<SystemAllocator>>(AllocatorRef<PaneMedia<SystemAllocator>, SystemAllocator>{memory}, memory, model.media_budget, model.graphics_limits, TerminalSize{80, 24, 8, 16});
  auto &terminal = *media->terminal();
  GraphicsSynchronizer sync{peer.session().graphics_credit, 42, media};
  const auto feed = [&](std::string_view text) {
    media->output({reinterpret_cast<const Byte *>(text.data()), text.size()});
    check(media->seal() && !media->process());
    media->complete();
  };
  const auto publish = [&] {
    const bool pending = sync.publish(peer.session().connection, terminal.graphics);
    if (!pending && media->seal()) {
      check(!media->process());
      media->complete();
      return sync.publish(peer.session().connection, terminal.graphics);
    }
    return pending;
  };
  sync.configure(shared);
  feed("\x1b_Ga=T,f=32,s=1,v=1,i=1,p=1,q=2;/wAA/w==\x1b\\");
  check(publish());
  check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::begin);
  TELAR_DIAGNOSTIC(check(sync.transferBytes() == 0));
  check(publish());
  TELAR_DIAGNOSTIC(check(sync.transferBytes() == 4));
  if (shared) {
    const auto message = peer.receive<GraphicsSharedImage>();
    std::array<char, 32> name{};
    std::copy(message.name.begin(), message.name.end(), name.begin());
    FileDescriptor descriptor{::shm_open(name.data(), O_RDONLY, 0)};
    check(static_cast<bool>(descriptor));
    struct stat status{};
    check(::fstat(descriptor.get(), &status) == 0 && status.st_size >= 4);
    const auto *mapping = static_cast<const Byte *>(::mmap(nullptr, 4, PROT_READ, MAP_SHARED, descriptor.get(), 0));
    check(mapping != MAP_FAILED && mapping[0] == 255 && mapping[3] == 255);
    ::munmap(const_cast<Byte *>(mapping), 4);
    check(::shm_unlink(name.data()) == 0);
    sync.returnCredit(5);
    check(peer.session().graphics_credit.used() == 4);
    sync.returnCredit(4);
    check(peer.session().graphics_credit.used() == 0);
    check(::shm_open(name.data(), O_RDONLY, 0) == -1 && errno == ENOENT);
  } else {
    check(peer.receive<GraphicsImage>().image.byte_len == 4);
    check(publish());
    const auto chunk = peer.receive<GraphicsImageChunk>();
    check(chunk.offset == 0 && chunk.bytes.size() == 4 && chunk.bytes[0] == 255);
    sync.returnCredit(4);
  }
  check(publish());
  check(peer.receive<GraphicsPlacementMessage>().placement.placement_id == 1);
  peer.session().connection.send(HistoryResults{.request_id = 7});
  publish();
  check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::end);
  check(peer.receive<HistoryResults>().request_id == 7);
  TELAR_DIAGNOSTIC(check(sync.transferBytes() == 0));
  check(!publish());

  feed("\x1b_Ga=d,d=I,i=1,q=2;\x1b\\");
  check(publish());
  check(peer.receive<GraphicsDeleteImage>().key.image_id == 1);
  check(!publish());
  sync.requestSnapshot();
  check(publish());
  check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::begin);
  check(!publish());
  check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::end);
#if TELAR_DIAGNOSTICS
  model.metrics.graphics.merge(sync.takeCounters());
  check(model.metrics.graphics.messages == (shared ? 7 : 8));
  check(model.metrics.graphics.images == 1 && model.metrics.graphics.placements == 1);
  check(model.metrics.graphics.bytes > 4);
#endif
}

static void testIdleBoundaryTransfer(SystemAllocator &memory, bool shared, std::size_t placement_count) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  ClientPeer peer{memory, model, clients, ClientRole::control};
  auto media = std::allocate_shared<PaneMedia<SystemAllocator>>(AllocatorRef<PaneMedia<SystemAllocator>, SystemAllocator>{memory}, memory, model.media_budget, model.graphics_limits, TerminalSize{80, 24, 8, 16});
  GraphicsSynchronizer sync{peer.session().graphics_credit, 42, media};
  using StageResult = decltype(sync)::StageResult;
  sync.configure(shared);

  auto &storage = media->terminal()->graphics;
  if (shared) {
    check(sync.publish(peer.session().connection, storage));
    check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::begin);
    check(!sync.publish(peer.session().connection, storage));
    check(peer.receive<GraphicsSnapshot>().phase == SnapshotPhase::end);
  } else {
    check(!sync.publish(peer.session().connection, storage));
  }

  const auto feed = [&](std::string_view bytes) {
    media->output({reinterpret_cast<const Byte *>(bytes.data()), bytes.size()});
    check(media->seal() && !media->process());
    media->complete();
  };
  feed("\x1b_Ga=T,f=32,s=1,v=1,i=1,p=7,C=1,q=2;/wAA/w==\x1b\\");
  for (std::size_t index = 1; index < placement_count; ++index) {
    feed("\x1b_Ga=p,i=1,p=" + std::to_string(index + 7) + ",C=1,q=2;\x1b\\");
  }
  check(storage.placements().size() == placement_count);

  const auto key = storage.images().front().description.key;
  const std::vector<GraphicsPlacement> placements{storage.placements().begin(), storage.placements().end()};
  const auto revision = storage.revision();
  auto &credit = peer.session().graphics_credit;
  check(credit.acquire(GraphicsCreditBudget::limit));
  check(sync.stage(storage) == StageResult::blocked);
  check(peer.session().connection.queuedBytes() == 0);
  credit.release(GraphicsCreditBudget::limit);

  sync.stageAtMediaBoundary(storage);
  if (!shared) {
    check(credit.used() == 0);
    check(media->seal() && !media->process());
    media->complete();
    sync.stageAtMediaBoundary(storage);
  }
  check(credit.used() == 4);
  TELAR_DIAGNOSTIC(model.metrics.graphics.merge(sync.takeCounters()));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.transfers_staged == 1));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.transfers_adopted == 0));
  sync.stageAtMediaBoundary(storage);
  check(credit.used() == 4 && peer.session().connection.queuedBytes() == 0);
  TELAR_DIAGNOSTIC(model.metrics.graphics.merge(sync.takeCounters()));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.transfers_staged == 1));

  const std::string_view replacement = "\x1b_Ga=T,f=32,s=1,v=1,i=1,p=8,C=1,q=2;AAD//w==\x1b\\";
  media->output({reinterpret_cast<const Byte *>(replacement.data()), replacement.size()});
  check(media->seal());
  std::thread next_batch{[&] { check(!media->process()); }};
  check(media->busy());
  check(sync.advanceTransfer(peer.session().connection));
  if (shared) {
    const auto message = peer.receive<GraphicsSharedImage>();
    check(sameImage(message.image.key, key) && message.header.revision == revision);
    const std::string name{message.name};
    FileDescriptor descriptor{::shm_open(name.c_str(), O_RDONLY, 0)};
    check(static_cast<bool>(descriptor));
    MappedRegion mapping{descriptor.get(), 4, PROT_READ};
    check(mapping && std::ranges::equal(mapping.bytes(), std::array<Byte, 4>{255, 0, 0, 255}));
    check(::shm_unlink(name.c_str()) == 0);
  } else {
    const auto message = peer.receive<GraphicsImage>();
    check(sameImage(message.image.key, key) && message.header.revision == revision);
    check(sync.advanceTransfer(peer.session().connection));
    const auto chunk = peer.receive<GraphicsImageChunk>();
    check(chunk.bytes.size() == 4 && chunk.bytes[0] == 255 && chunk.bytes[2] == 0);
  }

  for (const auto &expected : placements) {
    check(sync.advanceTransfer(peer.session().connection));
    const auto placement = peer.receive<GraphicsPlacementMessage>();
    check(samePlacement(placement.placement, expected));
  }
  sync.advanceTransfer(peer.session().connection);
  check(!sync.advanceTransfer(peer.session().connection));
  sync.returnCredit(4);
  check(credit.used() == 0);
  TELAR_DIAGNOSTIC(model.metrics.graphics.merge(sync.takeCounters()));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.transfers_adopted == 1));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.stage_blocked == 1));
  TELAR_DIAGNOSTIC(check(model.metrics.graphics.stage_deferred == 1));
  next_batch.join();
  media->complete();
  check(!sameImage(storage.images().front().description.key, key));
}

static void testPng(SystemAllocator &memory) {
  Terminal terminal{memory, TerminalSize{.cols = 80,
                                         .rows = 24,
                                         .cell_width_px = 8,
                                         .cell_height_px = 16}};
  feedGraphics(terminal, "\x1b_Ga=t,f=100,i=42,q=2;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
  check(terminal.graphics.images().size() == 1);
  const auto pixels = terminal.graphics.images().front().pixels;
  check(pixels.size() == 4 && pixels[0] == 255 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255);
  feedGraphics(terminal, "\x1b_Ga=t,f=100,i=43,q=2;aW52YWxpZA==\x1b\\");
  check(terminal.graphics.images().size() == 1);
  feedGraphics(terminal, "\x1b_Ga=T,f=8,s=1,v=1,i=44,q=2;AQ==\x1b\\");
  check(terminal.graphics.images().size() == 1);
}

static void testGraphicsCredit() {
  GraphicsCreditBudget first_client;
  GraphicsCreditBudget second_client;
  {
    GraphicsCreditLedger first_pane{first_client};
    GraphicsCreditLedger second_pane{first_client};
    GraphicsCreditLedger third_pane{first_client};
    GraphicsCreditLedger other_client_pane{second_client};
    check(first_pane.reserve(graphics_credit_bytes));
    check(second_pane.reserve(graphics_credit_bytes));
    check(!third_pane.reserve(1));
    check(other_client_pane.reserve(1));
    check(!first_pane.returnBytes(0) && !first_pane.returnBytes(graphics_credit_bytes + 1));
    check(first_pane.returnBytes(100));
    for (unsigned image = 0; image < 100; ++image) {
      check(third_pane.reserve(1));
    }
    check(first_client.used() == GraphicsCreditBudget::limit && second_client.used() == 1);
  }
  check(first_client.used() == 0 && second_client.used() == 0);
}

void testGraphics() {
  SystemAllocator memory;
  testMediaBudget(memory);
  testKittyFraming();
  testGraphicsCredit();
  installPngDecoder();
  testPng(memory);
  testGraphicsProjection(memory);
  testGraphicsTransfer(memory, false);
  testGraphicsTransfer(memory, true);
  for (const auto placement_count : {std::size_t{1}, graphics_placement_count}) {
    testIdleBoundaryTransfer(memory, false, placement_count);
    testIdleBoundaryTransfer(memory, true, placement_count);
  }
}
