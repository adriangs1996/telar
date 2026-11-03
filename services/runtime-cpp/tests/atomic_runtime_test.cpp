#include "check.hpp"
#include "graphics/pane_media.hpp"
#include "terminal/terminal.hpp"
#include <filesystem>

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> inputBytes(std::string_view bytes) {
  return {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()};
}

class AtomicImageFixture {
public:
  explicit AtomicImageFixture(GraphicsInputMedium medium, Byte value)
      : medium_(medium) {
    pixels.fill(value);
    if (medium_ == GraphicsInputMedium::shared_memory) {
      auto shared = SharedImageStorage::create(pixels.size());
      check(shared.has_value());
      std::ranges::copy(pixels, shared->mapping().bytes().begin());
      name_ = shared->takeName().data();
    } else {
      std::array<char, 64> path;
      std::strcpy(path.data(), "/tmp/telar-atomic-test-XXXXXX");
      FileDescriptor descriptor{::mkstemp(path.data())};
      check(descriptor && ::write(descriptor.get(), pixels.data(), pixels.size()) == static_cast<ssize_t>(pixels.size()));
      name_ = path.data();
    }

    encoded_.resize((name_.size() + 2) / 3 * 4);
    check(base64::encode(inputBytes(name_), encoded_) == encoded_.size());
  }

  ~AtomicImageFixture() {
    if (medium_ == GraphicsInputMedium::shared_memory) {
      ::shm_unlink(name_.c_str());
    } else {
      ::unlink(name_.c_str());
    }
  }

  std::string frame(bool wrapped = false) const {
    const auto medium = medium_ == GraphicsInputMedium::shared_memory ? "s" : "f";
    auto bytes = std::string{AtomicFrame::prefix} + "a=T,t=" + medium + ",f=32,s=2,v=3,i=1,p=2,C=1,q=2;" + encoded_ + std::string{AtomicFrame::suffix};
    return wrapped ? std::string{AtomicFrame::cursor_save} + bytes + std::string{AtomicFrame::cursor_restore} : bytes;
  }

  std::string query() const {
    return "\x1b_Ga=q,t=f,f=32,s=2,v=3,i=9;" + encoded_ + "\x1b\\";
  }

  void checkConsumed() const {
    if (medium_ == GraphicsInputMedium::shared_memory) {
      FileDescriptor descriptor{::shm_open(name_.c_str(), O_RDONLY, 0)};
      check(!descriptor && errno == ENOENT);
    } else {
      check(std::filesystem::exists(name_));
    }
  }

  std::array<Byte, 24> pixels;

private:
  GraphicsInputMedium medium_;
  std::string name_;
  std::string encoded_;
};

static void process(PaneMedia<SystemAllocator> &media, std::string_view bytes) {
  media.output(inputBytes(bytes));
  check(media.seal());
  check(!media.process());
  media.complete();
}

static void testAtomicPipeline(SystemAllocator &memory, GraphicsInputMedium medium, bool shared_transport) {
  MediaBudget budget{GraphicsLimits::maximum_global_bytes};
  {
    auto responses = std::make_shared<PtyResponseQueue>();
    Terminal queries{memory, TerminalSize{80, 24, 8, 16}, TerminalPurpose::separate_media, responses};
    PaneMedia media{memory, budget, GraphicsLimits{}, TerminalSize{80, 24, 8, 16}, responses};
    if (shared_transport) {
      media.noteSharedTransport(true);
    }
    AtomicImageFixture first{medium, 17};
    AtomicImageFixture newest{medium, 33};
    const std::string query = medium == GraphicsInputMedium::file ? newest.query() : "";
    process(media, "\x1b[4;6H" + first.frame(true) + query + newest.frame() + "\x1b"
                                                                              "8\x1b_Ga=p,i=1,p=9,C=1,q=2\x1b\\");
    first.checkConsumed();
    newest.checkConsumed();
#if TELAR_DIAGNOSTICS
    const auto &metrics = media.batchMetrics();
    constexpr std::uint64_t input_frame_count = 2;
    const std::uint64_t discarded_frames = query.empty() ? 1 : 0;
    const auto forwarded_frames = input_frame_count - discarded_frames;
    check(metrics.discarded_frames == discarded_frames && metrics.forwarded_frames == forwarded_frames && metrics.unavailable_frames == 0);
    check(metrics.direct_frames == forwarded_frames && metrics.file_frames == (medium == GraphicsInputMedium::file ? forwarded_frames : 0));
    check(metrics.ingest.count == 1 && metrics.failures == 0);
    const auto storage = media.storageMetrics();
    check(storage.images == 1 && storage.placements == 2 && storage.resident_bytes == newest.pixels.size());
    check(storage.prepared_bytes == (shared_transport ? newest.pixels.size() : 0));
#endif

    auto &terminal = *media.terminal();
    check(terminal.graphics.images().size() == 1);
    const auto image = terminal.graphics.images().front();
    check(image.description.byte_len == newest.pixels.size() && std::ranges::equal(image.pixels, newest.pixels));
    check(terminal.graphics.placements().size() == 2);
    for (const auto &placement : terminal.graphics.placements()) {
      check(placement.x == (placement.placement_id == 9 ? 5 : 0));
      check(placement.y == (placement.placement_id == 9 ? 3 : 0));
    }
    if (medium == GraphicsInputMedium::file) {
      check(terminal.responses().empty());
      queries.feed(inputBytes(query));
      check(std::ranges::equal(terminal.responses(), inputBytes("\x1b_Gi=9;OK\x1b\\")));
      queries.consumeResponses(queries.responses().size());
    }

    if (shared_transport) {
      const auto used = budget.used();
      auto transfer = media.takeTransfer(image.description.key, true);
      check(transfer && !transfer->name().empty() && budget.used() == used);
      const std::string name{transfer->name()};
      FileDescriptor descriptor{::shm_open(name.c_str(), O_RDONLY, 0)};
      struct stat metadata{};
      check(descriptor && ::fstat(descriptor.get(), &metadata) == 0 && (metadata.st_mode & 0777) == 0600);
      MappedRegion pixels{descriptor.get(), newest.pixels.size(), PROT_READ};
      check(pixels && std::ranges::equal(pixels.bytes(), newest.pixels));
      transfer.reset();
      check(::shm_open(name.c_str(), O_RDONLY, 0) == -1 && errno == ENOENT);
      check(budget.used() == used && std::ranges::equal(image.pixels, newest.pixels));
    }

    AtomicImageFixture replacement{medium, 49};
    process(media, replacement.frame());
    check(media.terminal()->graphics.images().front().description.key.generation > image.description.key.generation);
    check(std::ranges::equal(media.terminal()->graphics.images().front().pixels, replacement.pixels));
    process(media, "\x1b_Ga=d,d=I,i=1,q=2;\x1b\\");
    check(media.terminal()->graphics.images().empty());
  }
  check(budget.used() == 0);
}

static void testMappingOwnership(SystemAllocator &memory) {
  MediaBudget budget{8192};
  MediaAllocator allocator{memory, budget, 8192};
  {
    ImageAllocation rejected{allocator, 8192};
    check(!rejected && budget.used() == 0);
    ImageAllocation reserved{allocator, 24};
    check(reserved && budget.used() == 25);
  }
  check(budget.used() == 0);

  std::array<const Byte *, 64> placeholders;
  for (auto &placeholder : placeholders) {
    ImageAllocation allocation{allocator, 24};
    auto storage = SharedImageStorage::create(24);
    check(storage.has_value());
    std::ranges::fill(storage->mapping().bytes(), 42);
    check(storage->mapping().protect(PROT_READ));
    check(allocation.adopt(storage->mapping()) && !storage->mapping());
    placeholder = allocation.placeholder().data();
    check(allocator.imagePixels(allocation.placeholder()).size() == 24);
    check(allocator.imagePixels(allocation.placeholder())[0] == 42);
    allocation.release();
  }
  check(budget.used() == placeholders.size() * 25);
  {
    ImageAllocation overflow{allocator, 24};
    auto storage = SharedImageStorage::create(24);
    check(storage && !overflow.adopt(storage->mapping()) && storage->mapping());
  }
  check(budget.used() == placeholders.size() * 25);

  for (const auto *placeholder : placeholders) {
    allocator.deallocate(const_cast<Byte *>(placeholder), 1, alignof(Byte));
  }
  check(budget.used() == 0);
}

void testAtomicRuntime() {
  SystemAllocator memory;
  testMappingOwnership(memory);
  for (const auto medium : {GraphicsInputMedium::file, GraphicsInputMedium::shared_memory}) {
    for (const bool shared : {false, true}) {
      testAtomicPipeline(memory, medium, shared);
    }
  }
}
