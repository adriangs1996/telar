#include "check.hpp"
#include "graphics/media_terminal.hpp"
#include "telar_base/memory/allocator.hpp"
#include <string>

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> graphicsBytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

class GraphicsLimitFixture {
public:
  explicit GraphicsLimitFixture(SystemAllocator &memory)
      : graphics(memory),
        allocator_(memory) {
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), 20, 8));
    checkGhostty(ghostty_terminal_resize(terminal_.get(), 20, 8, 8, 16));
    const std::uint64_t storage = graphics_screen_bytes;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage));
  }

  void feed(std::string_view text) {
    ghostty_terminal_vt_write(terminal_.get(), reinterpret_cast<const Byte *>(text.data()), text.size());
  }

  void refresh() {
    graphics.update(terminal_.get());
  }

  GhosttyTerminal terminal() noexcept {
    return terminal_.get();
  }

  bool contains(std::uint32_t identity) const noexcept {
    return std::ranges::any_of(graphics.images(), [&](const auto &image) { return image.description.key.image_id == identity; });
  }

  GraphicsStorage<SystemAllocator> graphics;

private:
  GhosttyAllocatorBridge<SystemAllocator> allocator_;
  TerminalHandle terminal_;
};

static std::string transmit(std::uint32_t identity) {
  return "\x1b_Ga=t,f=32,s=1,v=1,i=" + std::to_string(identity) + ",q=2;/wAA/w==\x1b\\";
}

static std::string place(std::uint32_t image, std::uint32_t placement, bool placeholders = false) {
  return "\x1b_Ga=p,i=" + std::to_string(image) + ",p=" + std::to_string(placement) + ",C=1,c=1,r=1,q=2" + (placeholders ? ",U=1;" : ";") + "\x1b\\";
}

static void testImageEviction(SystemAllocator &memory) {
  GraphicsLimitFixture fixture{memory};
  for (unsigned identity = 1; identity <= 80; ++identity) {
    fixture.feed(transmit(identity));
  }
  fixture.refresh();
  check(fixture.graphics.images().size() == graphics_image_count && fixture.graphics.takeTrimmedImages() == 80);
  for (unsigned identity = 1; identity <= 80; ++identity) {
    check(fixture.contains(identity) == (identity >= 49));
  }

  fixture.feed(transmit(49) + transmit(81));
  fixture.refresh();
  check(fixture.contains(49) && fixture.contains(81) && !fixture.contains(50));

  fixture.feed("\x1b[?1049h");
  for (unsigned identity = 101; identity <= 180; ++identity) {
    fixture.feed(transmit(identity));
  }
  fixture.feed("\x1b[?1049l");
  fixture.refresh();
  check(fixture.contains(49) && fixture.graphics.takeTrimmedImages() == 80);

  const auto alternate = GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
  checkGhostty(ghostty_terminal_set(fixture.terminal(), GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &alternate));
  fixture.refresh();
  check(fixture.graphics.images().size() == graphics_image_count);
  for (unsigned identity = 101; identity <= 180; ++identity) {
    check(fixture.contains(identity) == (identity >= 149));
  }
  GhosttyTerminalScreen restored;
  checkGhostty(ghostty_terminal_get(fixture.terminal(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &restored));
  check(restored == GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
}

static void testPlacementEviction(SystemAllocator &memory) {
  GraphicsLimitFixture fixture{memory};
  fixture.feed(transmit(1) + transmit(2));
  for (unsigned placement = 1; placement <= 128; ++placement) {
    fixture.feed(place(1, placement, true));
  }
  fixture.feed(place(2, 129) + "\x1b[8;1H\n\n\n\n\n\n\n\n");
  fixture.refresh();
  check(fixture.graphics.placements().size() == graphics_placement_count && fixture.graphics.takeTrimmedPlacements() == 129);
  check(std::ranges::all_of(fixture.graphics.placements(), [](const auto &placement) { return placement.key.image_id == 1 && placement.location == PlacementLocation::placeholders; }));

  fixture.feed(place(2, 130));
  fixture.refresh();
  check(fixture.graphics.placements().size() == graphics_placement_count);
  check(std::ranges::count_if(fixture.graphics.placements(), [](const auto &placement) { return placement.key.image_id == 2; }) == 1);

  GraphicsLimitFixture overlap{memory};
  overlap.feed(transmit(1) + transmit(2));
  overlap.feed("\x1b_Ga=p,i=2,p=1,C=1,c=1,r=4,q=2;\x1b\\\x1b[8;1H\n\n");
  for (unsigned placement = 1; placement <= 128; ++placement) {
    overlap.feed(place(1, placement));
  }
  overlap.refresh();
  check(overlap.graphics.placements().size() == graphics_placement_count);
  check(std::ranges::count_if(overlap.graphics.placements(), [](const auto &placement) { return placement.key.image_id == 2 && placement.y == -2; }) == 1);
}

static void testIncompleteUploads(SystemAllocator &memory) {
  GraphicsLimitFixture fixture{memory};
  GraphicsUploadLimits limits{6, 2};
  const auto feed = [&](std::string_view bytes) {
    const auto observation = limits.observe(fixture.terminal(), graphicsBytes(bytes));
    fixture.feed(bytes);
    return limits.enforce(fixture.terminal(), observation);
  };
  check(!feed("\x1b_Ga=t,f=32,s=3,v=1,i=7,m=1,q=2;AAAA\x1b\\"));
  check(!feed("\x1b_Gm=1;AAAA\x1b\\"));
  check(feed("\x1b_Gm=1;AAAA\x1b\\") == 7);
  auto reached = limits.takeReached();
  check(reached.chunks && !reached.bytes);

  check(feed("\x1b_Ga=t,f=32,s=3,v=1,i=8,m=1,q=2;AAAAAAAAAAAA\x1b\\") == 8);
  reached = limits.takeReached();
  check(!reached.chunks && reached.bytes);

  check(!feed("\x1b_Ga=t,f=24,s=1,v=1,i=9,m=1,q=2;AAAA\x1b\\"));
  check(!feed("\x1b_Gm=1;\x1b\\"));
  check(feed("\x1b_Gm=0;\x1b\\") == 9);
  fixture.refresh();
  check(!fixture.contains(9) && limits.takeReached().chunks);

  check(!feed("\x1b_Ga=t,f=24,s=1,v=1,i=10,m=1,q=2;AA"));
  check(!feed("AA\x1b"));
  check(!feed("\\\x1b_Gm=0;\x1b\\"));
  fixture.refresh();
  check(fixture.contains(10));
}

static void testUploadResponse(SystemAllocator &memory) {
  MediaTerminal terminal{memory, TerminalSize{20, 8, 8, 16}, GraphicsLimits{.pane_bytes = 12}};
  terminal.feed(graphicsBytes("\x1b_Ga=t,f=32,s=3,v=1,i=81,m=1,q=2;AAAAAAAAAAAA\x1b\\"));
  const auto response = terminal.responses();
  check(std::string_view{reinterpret_cast<const char *>(response.data()), response.size()} == "\x1b_Gi=81;ENOMEM: graphics upload limit exceeded\x1b\\");
  check(terminal.takeUploadLimits().bytes);
}

static void testGeneratedChunkFraming(SystemAllocator &memory) {
  GraphicsLimitFixture fixture{memory};
  const auto generated = std::string{"\x1b_Ga=t,f=32,s=64,v=64,i=7,m=1,q=2;"} + std::string(4096, 'A') + "\x1b\\";
  for (const std::string_view prefix : {"", "plain text", "\x1b", "\x1b_", "\x1b_G", "\x1b_Gm=1;AAAA", "\x1b_X", "\x1b_Xother"}) {
    GraphicsUploadLimits scanned{graphics_screen_bytes};
    GraphicsUploadLimits encoded{graphics_screen_bytes};
    scanned.observe(fixture.terminal(), graphicsBytes(prefix));
    encoded.observe(fixture.terminal(), graphicsBytes(prefix));
    auto expected = scanned.observe(fixture.terminal(), graphicsBytes(generated));
    auto actual = encoded.observeEncodedChunk(fixture.terminal());
    check(actual.completed_commands == expected.completed_commands && actual.loading_image == expected.loading_image);

    constexpr std::string_view following = "\x1b_Gm=0;\x1b\\\x1b_Ga=q,i=99;\x1b\\";
    expected = scanned.observe(fixture.terminal(), graphicsBytes(following));
    actual = encoded.observe(fixture.terminal(), graphicsBytes(following));
    check(actual.completed_commands == expected.completed_commands && actual.loading_image == expected.loading_image);
  }
}

void testGraphicsLimits() {
  SystemAllocator memory;
  testImageEviction(memory);
  testPlacementEviction(memory);
  testIncompleteUploads(memory);
  testUploadResponse(memory);
  testGeneratedChunkFraming(memory);
}
