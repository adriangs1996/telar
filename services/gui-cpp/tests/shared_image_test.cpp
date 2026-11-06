#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstddef>
#include <limits>
#include <string_view>
#include <array>
#include <span>
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "assertions.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "session_fixture.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <cerrno>
#include <iostream>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>



import telar.gui.application.session;
import telar.gui.graphics.texture_cache;
import telar.gui.platform.profile_file;
import telar.platform;

namespace {

using namespace telar;
using namespace telar::gui;
using test::require;

constexpr std::uint32_t image_side = 2;
constexpr auto pixels = std::to_array<Byte>({0, 255, 127, 0, 255, 1, 128, 255, 229, 191, 17, 152, 40, 80, 120, 128});
constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};

ImageDescription description(std::uint64_t generation = 1) {
  return {.key = {.image_id = 77, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixels.size()};
}

class PublishedImage {
public:
  PublishedImage() {
    auto storage = runtime::SharedImageStorage::create(pixels.size());
    require(storage.has_value(), "the private shared-image fixture must allocate");
    std::ranges::copy(pixels, storage->mapping().bytes().begin());
    name_ = storage->takeName();
  }

  ~PublishedImage() {
    ::shm_unlink(name_.data());
  }

  PublishedImage(const PublishedImage &) = delete;
  PublishedImage &operator=(const PublishedImage &) = delete;

  std::string_view name() const noexcept {
    return name_.data();
  }

  runtime::FileDescriptor open() const {
    return runtime::FileDescriptor{::shm_open(name_.data(), O_RDWR, 0)};
  }

private:
  runtime::SharedImageStorage::Name name_{};
};

class ImageTransport : public test::Transport {
public:
  bool supportsSharedMemory() const noexcept {
    return local;
  }

  platform::SharedImageSource sharedImage(std::string_view name) {
    ++opened;
    return platform::SharedImageSource{name};
  }

  void recover(std::string_view reason) {
    recovery = reason;
  }

  bool local = true;
  unsigned opened = 0;
  std::string recovery;
};

void ownedReadPreservesPixelsAndUnlinksTheName() {
  PublishedImage published;
  platform::SharedImageSource source{published.name()};
  require(!published.open() && errno == ENOENT, "adoption must unlink the runtime-owned name immediately");
  std::array<Byte, pixels.size()> output{};
  require(source.read(output) && output == pixels, "shared reads must preserve every color and alpha byte");
  output.fill(0);
  require(source.read(output) && output == pixels, "the adopted descriptor must remain readable after unlink");
}

void unavailableAndUndersizedObjectsFailWithoutPublishing() {
  PublishedImage published;
  auto writer = published.open();
  require(static_cast<bool>(writer), "the fixture must retain a writer before adoption");
  platform::SharedImageSource source{published.name()};
  struct stat status{};
  require(::fstat(writer.get(), &status) == 0 && status.st_size > 0, "the fixture must report its actual backing extent");
  std::vector<Byte> oversized(static_cast<std::size_t>(status.st_size) + 1);
  require(!source.read(oversized), "a read beyond backing storage must fail before copying pixels");
  std::array<Byte, pixels.size()> output{};
#if defined(__APPLE__)
  require(::ftruncate(writer.get(), 0) == -1 && errno == EINVAL, "Darwin must refuse to resize an initialized POSIX shared object");
#else
  require(::ftruncate(writer.get(), 0) == 0, "the fixture must truncate the adopted object");
  require(!source.read(output), "truncated storage must fail instead of faulting or returning partial pixels");
#endif
  platform::SharedImageSource missing{published.name()};
  require(!missing.read(output), "a missing shared object must fail without allocating source pixels");
}

void nonPrivateObjectsAndMalformedNamesAreRejected() {
  PublishedImage published;
  require(::shm_unlink(published.name().data()) == 0, "the fixture must release its private object before creating the permission case");
  const auto previous_mask = ::umask(0);
  runtime::FileDescriptor writer{::shm_open(published.name().data(), O_CREAT | O_EXCL | O_RDWR, 0644)};
  ::umask(previous_mask);
  require(static_cast<bool>(writer) && ::ftruncate(writer.get(), pixels.size()) == 0, "the fixture must expose an unsafe permission mode");
  platform::SharedImageSource source{published.name()};
  std::array<Byte, pixels.size()> output{};
  require(!source.read(output), "public shared storage must not be accepted as private image delivery");
  require(static_cast<bool>(published.open()), "a rejected nonprivate object must not be unlinked");

  for (const auto name : {"", "relative", "/nested/path", "/UPPER", "/abcdefghijklmnopqrstuvwxyz123456"}) {
    bool rejected = false;
    try {
      platform::SharedImageSource invalid{name};
    } catch (const EncodingError &) {
      rejected = true;
    }
    require(rejected, "shared-image names must obey the protocol bounds before opening an object");
  }
}

void sharedAndInlineStoresHaveEquivalentGenerationsAndCredits() {
  SystemAllocator memory;
  GraphicsBudget inline_budget;
  GraphicsBudget shared_budget;
  GraphicsStore inline_store{memory, inline_budget};
  GraphicsStore shared_store{memory, shared_budget};

  constexpr std::uint64_t generations = 6;
  for (std::uint64_t generation = 1; generation <= generations; ++generation) {
    auto image = description(generation);
    if (generation > generations / 2) {
      constexpr std::size_t rgb_channels = 3;
      image.format = ImageFormat::rgb;
      image.byte_len = image_side * image_side * rgb_channels;
    }
    const auto source_pixels = std::span{pixels}.first(static_cast<std::size_t>(image.byte_len));
    inline_store.image({.header = header, .image = image});
    inline_store.chunk({.header = header, .key = image.key, .bytes = source_pixels});
    PublishedImage published;
    platform::SharedImageSource source{published.name()};
    require(shared_store.sharedImage(GraphicsSharedImage{.header = header, .image = image, .name = published.name()}, source), "a complete shared image must invalidate presentation");
    const auto *before = inline_store.readyImage(image.key);
    const auto *after = shared_store.readyImage(image.key);
    require(before != nullptr && after != nullptr && std::ranges::equal(before->pixels(), after->pixels()), "shared and inline images must have identical pixels");
    require(inline_budget.used == shared_budget.used && inline_store.takeCredit() == shared_store.takeCredit(), "replacement must preserve budgets and exact credit release");
  }

  inline_store.erase(GraphicsDeleteImage{.header = header, .key = description(generations).key});
  shared_store.erase(GraphicsDeleteImage{.header = header, .key = description(generations).key});
  require(inline_budget.used == 0 && shared_budget.used == 0 && inline_store.takeCredit() == shared_store.takeCredit(), "deletion must release both image budgets and the same credit");
}

void sharedReadsCannotBypassTheGlobalPixelQuota() {
  struct Reader {
    unsigned calls = 0;

    bool read(std::span<Byte>) noexcept {
      ++calls;
      return true;
    }
  } source;

  SystemAllocator memory;
  GraphicsBudget budget{.used = GraphicsBudget::global_capacity - pixels.size() + 1};
  GraphicsStore store{memory, budget};
  bool rejected = false;
  try {
    store.sharedImage(GraphicsSharedImage{.header = header, .image = description(), .name = "/unused"}, source);
  } catch (const GraphicsLimitError &) {
    rejected = true;
  }
  require(rejected && source.calls == 0, "shared images must pass the pixel quota before reading any bytes");
}

void missingPixelsRequestRecoveryAndReturnCreditAtSnapshot() {
  SystemAllocator memory;
  ImageTransport transport;
  Session<SystemAllocator, ImageTransport> client{memory, transport};
  test::openFirstPane(client, transport);
  require(transport.last<ConfigureGraphics>().shared, "a capable local transport must request shared graphics");
  PublishedImage published;
  require(::shm_unlink(published.name().data()) == 0, "the fixture must remove the image before delivery");
  test::deliver(client, GraphicsSharedImage{.header = header, .image = description(), .name = published.name()});
  require(client.ready() && transport.count(ClientTag::request_graphics_snapshot) == 1, "missing pixels must request graphics recovery without destroying the runtime link");
  require(client.findPane(1)->graphics.readyImage(description().key) == nullptr, "failed shared reads must never publish uninitialized pixels");
  test::deliver(client, GraphicsSnapshot{.header = {.pane_id = 1, .revision = 2}, .phase = SnapshotPhase::begin});
  require(transport.last<GraphicsCredit>().bytes == pixels.size(), "the replacement snapshot must return failed-image credit exactly once");
}

void ignoredImagesReleaseNamesAndRemoteImagesCannotOpenObjects() {
  SystemAllocator memory;
  ImageTransport local;
  Session<SystemAllocator, ImageTransport> client{memory, local};
  test::openFirstPane(client, local);
  PublishedImage ignored;
  test::deliver(client, GraphicsSharedImage{.header = {.pane_id = 99, .revision = 1}, .image = description(), .name = ignored.name()});
  require(!ignored.open() && errno == ENOENT, "images for detached panes must still release their shared names");

  ImageTransport remote;
  remote.local = false;
  Session<SystemAllocator, ImageTransport> remote_client{memory, remote};
  test::openFirstPane(remote_client, remote);
  require(!remote.last<ConfigureGraphics>().shared, "remote transports must retain inline delivery");
  PublishedImage unexpected;
  bool rejected = false;
  try {
    test::deliver(remote_client, GraphicsSharedImage{.header = header, .image = description(), .name = unexpected.name()});
  } catch (const EncodingError &) {
    rejected = true;
  }
  require(rejected && remote.opened == 0 && !remote.recovery.empty(), "an unnegotiated shared message must fail before opening a local object");
  require(static_cast<bool>(unexpected.open()), "remote messages must not unlink local shared objects");
}

}

int main() try {
  ownedReadPreservesPixelsAndUnlinksTheName();
  unavailableAndUndersizedObjectsFailWithoutPublishing();
  nonPrivateObjectsAndMalformedNamesAreRejected();
  sharedAndInlineStoresHaveEquivalentGenerationsAndCredits();
  sharedReadsCannotBypassTheGlobalPixelQuota();
  missingPixelsRequestRecoveryAndReturnCreditAtSnapshot();
  ignoredImagesReleaseNamesAndRemoteImagesCannotOpenObjects();
  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';
  return 1;
}
