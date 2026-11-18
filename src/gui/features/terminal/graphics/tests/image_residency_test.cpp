#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>

import telar.testing;
import telar.gui.features.terminal.graphics;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::terminal::graphics;

  struct Releases {
    static constexpr std::size_t release_capacity = 1024;
    telar::ds::Array<ImageTextureHandle, release_capacity> handles{};
    std::size_t count = 0;

    void release(ImageTextureHandle handle) noexcept {
      handles.atMut(count++) = handle;
    }
  };

  using Residency = ImageResidency<Releases>;
  constexpr ImageTextureSize small{.width = 2, .height = 2};
  constexpr ImageTextureSize quarter_budget{.width = 8192, .height = 4096};
  constexpr std::size_t quarter_bytes = Residency::byte_capacity / 4;

  ImageTextureIdentity identity(std::uint32_t image_id, std::uint64_t generation = 1) {
    return {.catalog = {.value = 1}, .image_id = image_id, .generation = generation};
  }

  ImageTextureHandle ready(Residency& images, ImageTextureIdentity key, ImageTextureSize size = small) {
    const auto admission = images.request({.identity = key, .size = size, .retained_bytes = 0, .now_ns = images.frame()});

    check(admission.upload && images.complete(admission.handle, true, images.frame()), "a valid image must reach ready residency");
    return admission.handle;
  }

  void retainedPixelsAndTexturesShareAdmission() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto first = images.request({.identity = identity(1), .size = quarter_budget, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 0});

    check(first.upload && images.residentBytes() == quarter_bytes, "CPU pixels and the requested RGBA texture must fit together at the exact quota boundary");
    check(!images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 0}).upload, "an uploading texture cannot be evicted to exceed the shared quota");
    check(images.complete(first.handle, true, 0), "the admitted upload must complete");
    images.markNeeded(first.handle);
    images.beginFrame(1);
    check(!images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 1}).upload, "the previous frame's stand-in remains protected under memory pressure");
    images.beginFrame(2);
    check(images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity - quarter_bytes, .now_ns = 2}).upload, "a texture unused for two frames becomes evictable");
    check(releases.count == 1 && releases.handles.front() == first.handle, "eviction must release the actual stable resource handle");
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

    check(images.spares() == 1 && releases.count == 0, "an unreferenced ready texture becomes a charged spare");
    const auto reused = images.request({.identity = identity(2), .size = small, .retained_bytes = Residency::byte_capacity, .now_ns = 1});

    check(reused.upload && reused.reuse && reused.handle == first, "same-size spare reuse must avoid a new allocation even when no extra budget remains");
    check(images.spares() == 0 && images.residentBytes() == charged, "reusing a spare must neither double-charge nor release it");
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

    check(admitted.upload, "idle resources must make room for a fitting texture");
    check(releases.count == 2 && releases.handles[0] == older_ready && releases.handles[1] == newer_spare, "eviction follows age across both stages rather than unconditionally taking spares first");
  }

  void uploadsAreBoundedPerImageAndPerFrame() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto first = images.request({.identity = identity(1), .size = small, .retained_bytes = 0, .now_ns = 0});
    const auto next = images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0});

    check(first.upload && next.upload && !images.request({.identity = identity(1, 3), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "only two generations of one logical image may upload concurrently");
    const auto other = images.request({.identity = identity(2), .size = small, .retained_bytes = 0, .now_ns = 0});
    const auto last = images.request({.identity = identity(3), .size = small, .retained_bytes = 0, .now_ns = 0});

    check(other.upload && last.upload && images.uploading() == Residency::maximum_uploads, "four logical uploads share the global in-flight bound");
    check(images.complete(last.handle, true, 0) && !images.request({.identity = identity(4), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "early completion does not admit a fifth upload into the same prepared frame");
    images.beginFrame(1);
    check(images.request({.identity = identity(4), .size = small, .retained_bytes = 0, .now_ns = 1}).upload, "the next frame can use the completed upload's capacity");
  }

  void failedUploadsKeepTheNewestDrawableStandIn() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto stand_in = ready(images, identity(1));
    const auto newer = images.request({.identity = identity(1, 3), .size = small, .retained_bytes = 0, .now_ns = 0});
    const auto older = images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0});

    check(images.complete(newer.handle, true, 0) && images.complete(older.handle, false, 0), "out-of-order completions must handle success and failure independently");
    check(images.newestReady(identity(1)) == newer.handle && images.newestReady(identity(2)) == 0, "the numerically newest ready generation supplies a stand-in only for the same logical image");
    check(images.residentBytes() == images.state(stand_in)->bytes + images.state(newer.handle)->bytes, "a failed upload must release its charged GPU bytes");
    check(!images.request({.identity = identity(1, 2), .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "a failed generation must remain memoized until its identity leaves");
    check(!images.complete(older.handle, true, 0), "a duplicate completion cannot mutate a failed row or decrement in-flight counts twice");
  }

  void idleExpiryUsesTheOriginalDeadlinesAndRounding() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto handle = ready(images, identity(1));

    images.markNeeded(handle);
    constexpr std::uint32_t idle_milliseconds = 5000;

    check(images.wakeupAfter(1) == idle_milliseconds, "the idle deadline rounds upwards to milliseconds");
    check(images.wakeupAfter(Residency::idle_lifetime_ns) == 1, "a due texture schedules a nonzero wakeup");
    images.beginFrame(Residency::idle_lifetime_ns);
    check(images.state(handle) == nullptr && images.residentBytes() == 0 && images.wakeupAfter(0) == 0, "an idle texture leaves the table and releases its resource");
    const auto spare = ready(images, identity(2));

    images.sweep([](auto) noexcept {
      return false;
    });

    images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns - 1);
    check(images.state(spare) != nullptr, "a spare survives until its shorter deadline");
    images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns);
    check(images.state(spare) == nullptr, "an unused spare expires after two seconds");
  }

  void unsupportedTexturesConsumeRowsWithoutPixelCharges() {
    Releases releases;
    Residency images{releases};
    const ImageTextureSize oversized{.width = Residency::maximum_side + 1, .height = 1};

    images.beginFrame(0);
    for (std::uint32_t index = 1; index <= Residency::capacity; ++index) {
      const auto admission = images.request({.identity = identity(index), .size = oversized, .retained_bytes = Residency::byte_capacity, .now_ns = 0});

      check(admission.handle == index && !admission.upload, "unsupported dimensions must occupy a stable failed row without attempting an upload");
    }

    check(images.residentBytes() == 0 && images.uploading() == 0 && !images.request({.identity = identity(static_cast<std::uint32_t>(Residency::capacity + 1)), .size = oversized, .retained_bytes = 0, .now_ns = 0}).upload, "failed rows are bounded and never treated as evictable ready textures");
    images.sweep([](auto) noexcept {
      return false;
    });

    check(images.size() == 0 && releases.count == Residency::capacity, "sweeping a full table must visit rows moved into removed slots");
  }

  void catalogLifetimesAndClockExtremesStayDistinct() {
    Releases releases;
    Residency images{releases};
    constexpr auto latest_clock = std::numeric_limits<std::uint64_t>::max();

    images.beginFrame(latest_clock - 1);
    const auto first = ready(images, identity(1));

    check(!images.complete(first, true, latest_clock - 1), "an already-ready row cannot accept another completion");
    auto other_catalog = identity(1);

    other_catalog.catalog.value = 2;
    check(images.newestReady(other_catalog) == 0, "the same image key in another catalog lifetime cannot share pixels");
    check(!images.request({.identity = {.catalog = {.value = 0}, .image_id = 1, .generation = 1}, .size = small, .retained_bytes = 0, .now_ns = 0}).upload, "an exhausted lifetime identity cannot enter the reusable table");
    images.markNeeded(first);
  }

  void contextCleanupAbandonsUploadsAndReleasesEveryHandle() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto first = ready(images, identity(1));
    const auto pending = images.request({.identity = identity(2), .size = small});

    check(pending.upload, "cleanup must include an upload whose pixels may still be in use by the backend");
    telar::ds::Array<bool, Residency::capacity> retained{};

    retained.atMut(first - 1) = true;
    images.sweep(retained.viewMut());
    check(images.state(first)->stage == ImageTextureStage::ready, "indexed retention must preserve the requested stable row");
    images.clear();
    check(images.size() == 0 && images.uploading() == 0 && images.spares() == 0 && images.residentBytes() == 0 && releases.count == 2, "context cleanup must return every charge and handle after abandoning pending uploads");
    check(!images.complete(pending.handle, true, 0), "a completion from the old context cannot revive a cleared row");
  }

  void keepingVisiblePixelsWarmDoesNotProtectDeletedPlacements() {
    Releases releases;
    Residency images{releases};

    images.beginFrame(0);
    const auto handle = ready(images, identity(1));

    images.markNeeded(handle);
    images.keepWarm({.handle = handle, .now_ns = Residency::idle_lifetime_ns});
    images.beginFrame(Residency::idle_lifetime_ns);
    check(images.state(handle) != nullptr && images.state(handle)->stage == ImageTextureStage::ready, "visible pixels must survive an idle wakeup without another texture allocation");
    images.sweep([](auto) noexcept {
      return false;
    });

    check(images.spares() == 1, "refreshing the idle clock must not claim that a deleted placement drew in the new frame");
    images.beginFrame(Residency::idle_lifetime_ns + Residency::spare_lifetime_ns);
    check(images.size() == 0 && releases.count == 1, "the retired texture must still expire at its spare deadline");
  }

  const telar::testing::Case case_retained_pixels_and_textures_share_admission{"image_residency.retained_pixels_and_textures_share_admission", retainedPixelsAndTexturesShareAdmission};
  const telar::testing::Case case_spare_reuse_preserves_its_handle_and_charged_bytes{"image_residency.spare_reuse_preserves_its_handle_and_charged_bytes", spareReusePreservesItsHandleAndChargedBytes};
  const telar::testing::Case case_eviction_uses_age_across_ready_textures_and_spares{"image_residency.eviction_uses_age_across_ready_textures_and_spares", evictionUsesAgeAcrossReadyTexturesAndSpares};
  const telar::testing::Case case_uploads_are_bounded_per_image_and_per_frame{"image_residency.uploads_are_bounded_per_image_and_per_frame", uploadsAreBoundedPerImageAndPerFrame};
  const telar::testing::Case case_failed_uploads_keep_the_newest_drawable_stand_in{"image_residency.failed_uploads_keep_the_newest_drawable_stand_in", failedUploadsKeepTheNewestDrawableStandIn};
  const telar::testing::Case case_idle_expiry_uses_the_original_deadlines_and_rounding{"image_residency.idle_expiry_uses_the_original_deadlines_and_rounding", idleExpiryUsesTheOriginalDeadlinesAndRounding};
  const telar::testing::Case case_unsupported_textures_consume_rows_without_pixel_charges{"image_residency.unsupported_textures_consume_rows_without_pixel_charges", unsupportedTexturesConsumeRowsWithoutPixelCharges};
  const telar::testing::Case case_catalog_lifetimes_and_clock_extremes_stay_distinct{"image_residency.catalog_lifetimes_and_clock_extremes_stay_distinct", catalogLifetimesAndClockExtremesStayDistinct};
  const telar::testing::Case case_context_cleanup_abandons_uploads_and_releases_every_handle{"image_residency.context_cleanup_abandons_uploads_and_releases_every_handle", contextCleanupAbandonsUploadsAndReleasesEveryHandle};
  const telar::testing::Case case_keeping_visible_pixels_warm_does_not_protect_deleted_placements{"image_residency.keeping_visible_pixels_warm_does_not_protect_deleted_placements", keepingVisiblePixelsWarmDoesNotProtectDeletedPlacements};

}
