#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "foundation/core/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <sys/stat.h>
#include <system_error>
#include <tuple>
#include <unistd.h>
#include <utility>
#include <variant>
#include <vector>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.features.terminal.graphics;
import telar.gui.foundation.system;
import telar.platform.graphics;
import telar.wire.graphics;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::application::tests::session_fixture;

  constexpr std::uint32_t image_side = 2;
  constexpr auto pixels = ds::Array<Byte, 16>{0, 255, 127, 0, 255, 1, 128, 255, 229, 191, 17, 152, 40, 80, 120, 128};
  constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};

  ImageDescription description(std::uint64_t generation = 1) {
    constexpr std::uint64_t image_id = 77;

    return {.key = {.image_id = image_id, .generation = generation}, .format = ImageFormat::rgba, .width = image_side, .height = image_side, .byte_len = pixels.size()};
  }

  class PublishedImage {
  public:
    PublishedImage() {
      auto storage = runtime::SharedImageStorage::create(pixels.size());

      check(storage.hasValue(), "the private shared-image fixture must allocate");
      std::ranges::copy(pixels, storage.getMut().mapping().bytes().begin());
      name_ = storage.getMut().takeName();
    }

    ~PublishedImage() {
      ::shm_unlink(name_.data());
    }

    PublishedImage(const PublishedImage&) = delete;
    PublishedImage(PublishedImage&&) = delete;
    PublishedImage& operator=(const PublishedImage&) = delete;
    PublishedImage& operator=(PublishedImage&&) = delete;

    [[nodiscard]] std::string_view name() const noexcept {
      return name_.data();
    }

    [[nodiscard]] runtime::FileDescriptor open() const {
      return runtime::FileDescriptor{::shm_open(name_.data(), O_RDWR, 0)};
    }

  private:
    runtime::SharedImageStorage::Name name_{};
  };

  class ImageTransport final : public telar::gui::application::tests::session_fixture::Transport {
  public:
    bool supportsSharedMemory() const noexcept override {
      return local;
    }

    system::SharedImageSource sharedImage(std::string_view name) const override {
      ++opened;
      return system::SharedImageSource{name};
    }

    void recover(std::string_view reason) override {
      recovery = reason;
    }

    bool local = true;
    mutable unsigned opened = 0;
    std::string recovery;
  };

  void ownedReadPreservesPixelsAndUnlinksTheName() {
    const PublishedImage published;
    const system::SharedImageSource source{published.name()};

    check(!published.open() && errno == ENOENT, "adoption must unlink the runtime-owned name immediately");
    ds::Array<Byte, pixels.size()> output{};

    check(source.read(output.viewMut()) && output == pixels, "shared reads must preserve every color and alpha byte");
    output.fill(0);
    check(source.read(output.viewMut()) && output == pixels, "the adopted descriptor must remain readable after unlink");
  }

  void unavailableAndUndersizedObjectsFailWithoutPublishing() {
    const PublishedImage published;
    const auto writer = published.open();

    check(static_cast<bool>(writer), "the fixture must retain a writer before adoption");
    const system::SharedImageSource source{published.name()};
    struct stat status{};

    check(::fstat(writer.get(), &status) == 0 && status.st_size > 0, "the fixture must report its actual backing extent");
    std::vector<Byte> oversized(static_cast<std::size_t>(status.st_size) + 1);

    check(!source.read(oversized), "a read beyond backing storage must fail before copying pixels");
    ds::Array<Byte, pixels.size()> output{};

#ifdef __APPLE__
    check(::ftruncate(writer.get(), 0) == -1 && errno == EINVAL, "Darwin must refuse to resize an initialized POSIX shared object");
#else
    check(::ftruncate(writer.get(), 0) == 0, "the fixture must truncate the adopted object");
    check(!source.read(output.viewMut()), "truncated storage must fail instead of faulting or returning partial pixels");
#endif
    const system::SharedImageSource missing{published.name()};

    check(!missing.read(output.viewMut()), "a missing shared object must fail without allocating source pixels");
  }

  void nonPrivateObjectsAndMalformedNamesAreRejected() {
    const PublishedImage published;

    check(::shm_unlink(published.name().data()) == 0, "the fixture must release its private object before creating the permission case");
    const auto previous_mask = ::umask(0);
    const runtime::FileDescriptor writer{::shm_open(published.name().data(), O_CREAT | O_EXCL | O_RDWR, 0644)}; // NOLINT(cppcoreguidelines-pro-type-vararg): POSIX declares shm_open variadic, and O_CREAT needs its mode argument

    ::umask(previous_mask);
    check(static_cast<bool>(writer) && ::ftruncate(writer.get(), pixels.size()) == 0, "the fixture must expose an unsafe permission mode");
    const system::SharedImageSource source{published.name()};
    ds::Array<Byte, pixels.size()> output{};

    check(!source.read(output.viewMut()), "public shared storage must not be accepted as private image delivery");
    check(static_cast<bool>(published.open()), "a rejected nonprivate object must not be unlinked");

    for (const auto* const name : {"", "relative", "/nested/path", "/UPPER", "/abcdefghijklmnopqrstuvwxyz123456"}) {
      bool rejected = false;

      try {
        const system::SharedImageSource invalid{name};
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected, "shared-image names must obey the protocol bounds before opening an object");
    }
  }

  void sharedAndInlineStoresHaveEquivalentGenerationsAndCredits() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
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
        image.byte_len = std::size_t{image_side} * image_side * rgb_channels;
      }

      const auto source_pixels = std::span{pixels}.first(static_cast<std::size_t>(image.byte_len));

      inline_store.image({.header = header, .image = image});
      inline_store.chunk({.header = header, .key = image.key, .bytes = source_pixels});
      const PublishedImage published;
      system::SharedImageSource source{published.name()};

      check(shared_store.sharedImage(GraphicsSharedImage{.header = header, .image = image, .name = published.name()}, source), "a complete shared image must invalidate presentation");
      const auto* before = inline_store.readyImage(image.key);
      const auto* after = shared_store.readyImage(image.key);

      check(before != nullptr && after != nullptr && std::ranges::equal(before->pixels(), after->pixels()), "shared and inline images must have identical pixels");
      check(inline_budget.used == shared_budget.used && inline_store.takeCredit() == shared_store.takeCredit(), "replacement must preserve budgets and exact credit release");
    }

    inline_store.erase(GraphicsDeleteImage{.header = header, .key = description(generations).key});
    shared_store.erase(GraphicsDeleteImage{.header = header, .key = description(generations).key});
    check(inline_budget.used == 0 && shared_budget.used == 0 && inline_store.takeCredit() == shared_store.takeCredit(), "deletion must release both image budgets and the same credit");
  }

  void sharedReadsCannotBypassTheGlobalPixelQuota() {
    struct Reader {
      unsigned calls = 0;

      bool read(std::span<Byte> /*unused*/) noexcept {
        ++calls;
        return true;
      }
    } source;

    SystemAllocator system;

    telar::MemoryAdapter adapter{system};

    telar::ConcurrentMemory& memory = adapter;
    GraphicsBudget budget;

    budget.used = GraphicsBudget::global_capacity - pixels.size() + 1;
    GraphicsStore store{memory, budget};
    bool rejected = false;

    try {
      store.sharedImage(GraphicsSharedImage{.header = header, .image = description(), .name = "/unused"}, source);
    } catch (const GraphicsLimitError&) {
      rejected = true;
    }

    check(rejected && source.calls == 0, "shared images must pass the pixel quota before reading any bytes");
  }

  void missingPixelsRequestRecoveryAndReturnCreditAtSnapshot() {
    SystemAllocator memory;
    ImageTransport transport;
    TestSession client{memory, transport};

    telar::gui::application::tests::session_fixture::openFirstPane(client, transport);
    check(transport.last<ConfigureGraphics>().shared, "a capable local transport must request shared graphics");
    const PublishedImage published;

    check(::shm_unlink(published.name().data()) == 0, "the fixture must remove the image before delivery");
    telar::gui::application::tests::session_fixture::deliver(client, GraphicsSharedImage{.header = header, .image = description(), .name = published.name()});
    check(client.ready() && transport.count(ClientTag::request_graphics_snapshot) == 1, "missing pixels must request graphics recovery without destroying the runtime link");
    check(client.findPane(1)->graphics.readyImage(description().key) == nullptr, "failed shared reads must never publish uninitialized pixels");
    telar::gui::application::tests::session_fixture::deliver(client, GraphicsSnapshot{.header = {.pane_id = 1, .revision = 2}, .phase = SnapshotPhase::begin});
    check(transport.last<GraphicsCredit>().bytes == pixels.size(), "the replacement snapshot must return failed-image credit exactly once");
  }

  void ignoredImagesReleaseNamesAndRemoteImagesCannotOpenObjects() {
    SystemAllocator memory;
    ImageTransport local;
    TestSession client{memory, local};

    telar::gui::application::tests::session_fixture::openFirstPane(client, local);
    const PublishedImage ignored;
    constexpr std::uint64_t detached_pane = 99;

    telar::gui::application::tests::session_fixture::deliver(client, GraphicsSharedImage{.header = {.pane_id = detached_pane, .revision = 1}, .image = description(), .name = ignored.name()});
    check(!ignored.open() && errno == ENOENT, "images for detached panes must still release their shared names");

    ImageTransport remote;

    remote.local = false;
    TestSession remote_client{memory, remote};

    telar::gui::application::tests::session_fixture::openFirstPane(remote_client, remote);
    check(!remote.last<ConfigureGraphics>().shared, "remote transports must retain inline delivery");
    const PublishedImage unexpected;
    bool rejected = false;

    try {
      telar::gui::application::tests::session_fixture::deliver(remote_client, GraphicsSharedImage{.header = header, .image = description(), .name = unexpected.name()});
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && remote.opened == 0 && !remote.recovery.empty(), "an unnegotiated shared message must fail before opening a local object");
    check(static_cast<bool>(unexpected.open()), "remote messages must not unlink local shared objects");
  }

  const telar::testing::Case case_owned_read_preserves_pixels_and_unlinks_the_name{"shared_image.owned_read_preserves_pixels_and_unlinks_the_name", ownedReadPreservesPixelsAndUnlinksTheName};
  const telar::testing::Case case_unavailable_and_undersized_objects_fail_without_publishing{"shared_image.unavailable_and_undersized_objects_fail_without_publishing", unavailableAndUndersizedObjectsFailWithoutPublishing};
  const telar::testing::Case case_non_private_objects_and_malformed_names_are_rejected{"shared_image.non_private_objects_and_malformed_names_are_rejected", nonPrivateObjectsAndMalformedNamesAreRejected};
  const telar::testing::Case case_shared_and_inline_stores_have_equivalent_generations_and_credits{"shared_image.shared_and_inline_stores_have_equivalent_generations_and_credits", sharedAndInlineStoresHaveEquivalentGenerationsAndCredits};
  const telar::testing::Case case_shared_reads_cannot_bypass_the_global_pixel_quota{"shared_image.shared_reads_cannot_bypass_the_global_pixel_quota", sharedReadsCannotBypassTheGlobalPixelQuota};
  const telar::testing::Case case_missing_pixels_request_recovery_and_return_credit_at_snapshot{"shared_image.missing_pixels_request_recovery_and_return_credit_at_snapshot", missingPixelsRequestRecoveryAndReturnCreditAtSnapshot};
  const telar::testing::Case case_ignored_images_release_names_and_remote_images_cannot_open_objects{"shared_image.ignored_images_release_names_and_remote_images_cannot_open_objects", ignoredImagesReleaseNamesAndRemoteImagesCannotOpenObjects};

}
