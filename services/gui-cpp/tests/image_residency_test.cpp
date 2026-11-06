#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <optional>
#include <span>
#include <exception>
#include <iostream>



import telar.gui.graphics.texture_cache;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

struct Releases {
  static constexpr std::size_t release_capacity = 1024;
  std::array<ImageTextureHandle, release_capacity> handles{};
  std::size_t count = 0;

  void release(ImageTextureHandle handle) noexcept {
    handles[count++] = handle;
  }
};

using Residency = ImageResidency<Releases>;
constexpr ImageTextureSize small{.width = 2, .height = 2};
constexpr ImageTextureSize quarter_budget{.width = 8192, .height = 4096};
constexpr std::size_t quarter_bytes = Residency::byte_capacity / 4;

ImageTextureIdentity identity(std::uint32_t image_id, std::uint64_t generation = 1) {
  return {.catalog = {.value = 1}, .image_id = image_id, .generation = generation};
}

ImageTextureHandle ready(Residency &images, ImageTextureIdentity key, ImageTextureSize size = small) {
  const auto admission = images.request({.identity = key, .size = size, .retained_bytes = 0, .now_ns = images.frame()});
  require(admission.upload && images.complete(admission.handle, true, images.frame()), "a valid image must reach ready residency");
  return admission.handle;
}

void retainedPixelsAndTexturesShareAdmission() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto first = images.request({.identity = identity(1), .size = quarter_budget, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 0});
  require(first.upload && images.residentBytes() == quarter_bytes, "CPU pixels and the requested RGBA texture must fit together at the exact quota boundary");
  require(!images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 0}).upload, "an uploading texture cannot be evicted to exceed the shared quota");
  require(images.complete(first.handle, true, 0), "the admitted upload must complete");
  images.markNeeded(first.handle);
  images.beginFrame(1);
  require(!images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 1}).upload, "the previous frame's stand-in remains protected under memory pressure");
  images.beginFrame(2);
  require(images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 2}).upload, "a texture unused for two frames becomes evictable");
  require(releases.count == 1 && releases.handles.front() == first.handle, "eviction must release the actual stable resource handle");
}

void spareReusePreservesItsHandleAndChargedBytes() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto first = ready(images, identity(1));
  const auto charged = images.residentBytes();
  images.beginFrame(1);
  images.sweep([](auto) noexcept {
    return false;
  });
  require(images.spares() == 1 && releases.count == 0, "an unreferenced ready texture becomes a charged spare");
  const auto reused = images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity, .now_ns = 1});
  require(reused.upload && reused.reuse && reused.handle == first, "same-size spare reuse must avoid a new allocation even when no extra budget remains");
  require(images.spares() == 0 && images.residentBytes() == charged, "reusing a spare must neither double-charge nor release it");
}

void evictionUsesAgeAcrossReadyTexturesAndSpares() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto older_ready = ready(images, identity(1));
  const auto newer_spare = ready(images, identity(2));
  images.beginFrame(2);
  images.sweep([](auto key) noexcept {
    return key.image_id == 1;
  });
  images.beginFrame(3);
  const auto admitted = images.request({.identity = identity(3), .size = quarter_budget, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 2});
  require(admitted.upload, "idle resources must make room for a fitting texture");
  require(releases.count == 2 && releases.handles[0] == older_ready && releases.handles[1] == newer_spare, "eviction follows age across both stages rather than unconditionally taking spares first");
}

void uploadsAreBoundedPerImageAndPerFrame() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto first = images.request({.identity = identity(1), .size = small, .retained_bytes = 0, .now_ns = 0});
  const auto next = images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0});
  require(first.upload && next.upload && !images.request({.identity = identity(1, 3), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "only two generations of one logical image may upload concurrently");
  const auto other = images.request({.identity = identity(2), .size = small, .retained_bytes = 0, .now_ns = 0});
  const auto last = images.request({.identity = identity(3), .size = small, .retained_bytes = 0, .now_ns = 0});
  require(other.upload && last.upload && images.uploading() == Residency::maximum_uploads, "four logical uploads share the global in-flight bound");
  require(images.complete(last.handle, true, 0) && !images.request({.identity = identity(4), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "early completion does not admit a fifth upload into the same prepared frame");
  images.beginFrame(1);
  require(images.request({.identity = identity(4), .size = small, .retained_bytes = 0, .now_ns = 1}).upload, "the next frame can use the completed upload's capacity");
}

void failedUploadsKeepTheNewestDrawableStandIn() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto stand_in = ready(images, identity(1));
  const auto newer = images.request({.identity = identity(1, 3), .size = small, .retained_bytes = 0, .now_ns = 0});
  const auto older = images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0});
  require(images.complete(newer.handle, true, 0) && images.complete(older.handle, false, 0), "out-of-order completions must handle success and failure independently");
  require(images.newestReady(identity(1)) == newer.handle && images.newestReady(identity(2)) == 0, "the numerically newest ready generation supplies a stand-in only for the same logical image");
  require(images.residentBytes() == images.state(stand_in)->bytes + images.state(newer.handle)->bytes, "a failed upload must release its charged GPU bytes");
  require(!images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "a failed generation must remain memoized until its identity leaves");
  require(!images.complete(older.handle, true, 0), "a duplicate completion cannot mutate a failed row or decrement in-flight counts twice");
}

void idleExpiryUsesTheOriginalDeadlinesAndRounding() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto handle = ready(images, identity(1));
  images.markNeeded(handle);
  constexpr std::uint32_t idle_milliseconds = 5000;
  require(images.wakeupAfter(1) == idle_milliseconds && !images.trimDue(Residency::idle_lifetime_ns - 1), "the idle deadline rounds upwards to milliseconds and expires only at its boundary");
  require(images.trimDue(Residency::idle_lifetime_ns) && images.wakeupAfter(Residency::idle_lifetime_ns) == 1, "a due texture schedules a nonzero wakeup");
  images.beginFrame(Residency::idle_lifetime_ns);
  require(images.state(handle) == nullptr && images.residentBytes() == 0 && images.wakeupAfter(0) == 0, "an idle texture leaves the table and releases its resource");
  const auto spare = ready(images, identity(2));
  images.sweep([](auto) noexcept {
    return false;
  });
  images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns - 1);
  require(images.state(spare) != nullptr, "a spare survives until its shorter deadline");
  images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns);
  require(images.state(spare) == nullptr, "an unused spare expires after two seconds");
}

void unsupportedTexturesConsumeRowsWithoutPixelCharges() {
  Releases releases;
  Residency images{releases};
  const ImageTextureSize oversized{.width = Residency::maximum_side + 1, .height = 1};
  images.beginFrame(0);
  for (std::uint32_t index = 1; index <= Residency::capacity; ++index) {
    const auto admission = images.request({.identity = identity(index), .size = oversized, .retained_bytes = Residency::byte_capacity, .now_ns = 0});
    require(admission.handle == index && !admission.upload, "unsupported dimensions must occupy a stable failed row without attempting an upload");
  }

  require(images.residentBytes() == 0 && images.uploading() == 0 && !images.request({.identity = identity(static_cast<std::uint32_t>(Residency::capacity + 1)), .size = oversized, .retained_bytes = 0, .now_ns = 0}).upload, "failed rows are bounded and never treated as evictable ready textures");
  images.sweep([](auto) noexcept {
    return false;
  });
  require(images.size() == 0 && releases.count == Residency::capacity, "sweeping a full table must visit rows moved into removed slots");
}

void catalogLifetimesAndClockExtremesStayDistinct() {
  Releases releases;
  Residency images{releases};
  constexpr auto latest_clock = std::numeric_limits<std::uint64_t>::max();
  images.beginFrame(latest_clock - 1);
  const auto first = ready(images, identity(1));
  require(!images.complete(first, true, latest_clock - 1), "an already-ready row cannot accept another completion");
  auto other_catalog = identity(1);
  other_catalog.catalog.value = 2;
  require(images.newestReady(other_catalog) == 0, "the same image key in another catalog lifetime cannot share pixels");
  require(!images.request({.identity = {.catalog = {.value = 0}, .image_id = 1, .generation = 1}, .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "an exhausted lifetime identity cannot enter the reusable table");
  images.markNeeded(first);
  require(!images.trimDue(latest_clock - 1) && images.trimDue(latest_clock), "deadline arithmetic saturates without wrapping into the past");
}

void contextCleanupAbandonsUploadsAndReleasesEveryHandle() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto first = ready(images, identity(1));
  const auto pending = images.request({.identity = identity(2), .size = small});
  require(pending.upload, "cleanup must include an upload whose pixels may still be in use by the backend");
  std::array<bool, Residency::capacity> retained{};
  retained[first - 1] = true;
  images.sweep(std::span{retained});
  require(images.state(first)->stage == ImageTextureStage::ready, "indexed retention must preserve the requested stable row");
  images.clear();
  require(images.size() == 0 && images.uploading() == 0 && images.spares() == 0 && images.residentBytes() == 0 && releases.count == 2, "context cleanup must return every charge and handle after abandoning pending uploads");
  require(!images.complete(pending.handle, true, 0), "a completion from the old context cannot revive a cleared row");
}

void keepingVisiblePixelsWarmDoesNotProtectDeletedPlacements() {
  Releases releases;
  Residency images{releases};
  images.beginFrame(0);
  const auto handle = ready(images, identity(1));
  images.markNeeded(handle);
  images.keepWarm({.handle = handle, .now_ns = Residency::idle_lifetime_ns});
  images.beginFrame(Residency::idle_lifetime_ns);
  require(images.state(handle) != nullptr && images.state(handle)->stage == ImageTextureStage::ready, "visible pixels must survive an idle wakeup without another texture allocation");
  images.sweep([](auto) noexcept {
    return false;
  });
  require(images.spares() == 1, "refreshing the idle clock must not claim that a deleted placement drew in the new frame");
  images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns);
  require(images.size() == 0 && releases.count == 1, "the retired texture must still expire at its spare deadline");
}

}

int main() {
  try {
    retainedPixelsAndTexturesShareAdmission();
    spareReusePreservesItsHandleAndChargedBytes();
    evictionUsesAgeAcrossReadyTexturesAndSpares();
    uploadsAreBoundedPerImageAndPerFrame();
    failedUploadsKeepTheNewestDrawableStandIn();
    idleExpiryUsesTheOriginalDeadlinesAndRounding();
    unsupportedTexturesConsumeRowsWithoutPixelCharges();
    catalogLifetimesAndClockExtremesStayDistinct();
    contextCleanupAbandonsUploadsAndReleasesEveryHandle();
    keepingVisiblePixelsWarmDoesNotProtectDeletedPlacements();
    std::cout << "gui-image-residency: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-image-residency: " << error.what() << '\n';
    return 1;
  }
}
