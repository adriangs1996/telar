#include "features/terminal/attachments/sensitive_bytes.hpp"
#include "features/terminal/attachments/types.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <new>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

import telar.testing;
import telar.gui.features.terminal.attachments;
import telar.gui.tests.erasure_allocator;
import telar.gui.foundation.terminal;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::terminal::attachments;

  constexpr AttachmentTarget prompt{.pane_id = 1, .pane_generation = 2};
  constexpr AttachmentTarget other_prompt{.pane_id = 1, .pane_generation = 3};
  constexpr std::byte sensitive{0x5a};
  constexpr std::uint64_t fifth_id = AttachmentLimits::maximum_items + 1;
  constexpr std::uint64_t sixth_id = fifth_id + 1;

  using CheckedMemory = telar::gui::test::ErasureAllocator;

  struct Delivery {
    struct SlotState {
      std::size_t index = 0;
    };

    SlotState create() {
      if (fail) {
        throw std::runtime_error{"DeliveryFailed"};
      }

      return {.index = next++};
    }

    void retire(SlotState state) noexcept {
      retired[state.index] = true;
    }

    [[nodiscard]] bool canRelease(SlotState state) const noexcept {
      return !leased[state.index];
    }

    static constexpr std::size_t resource_capacity = AttachmentLimits::maximum_items * 4;
    std::array<bool, resource_capacity> retired{};
    std::array<bool, resource_capacity> leased{};
    std::size_t next = 0;
    bool fail = false;
  };

  AttachmentCapture<CheckedMemory> capture(CheckedMemory& memory, std::uint64_t id, AttachmentTarget target = prompt) {
    AttachmentCapture<CheckedMemory> result{.request = {.capture = {.id = id, .target = target}}, .png = SensitiveBytes{memory}, .width = 1, .height = 1};
    const std::array bytes{sensitive};

    result.png.append(bytes, AttachmentLimits::maximum_png_bytes);

    return result;
  }

  void sensitiveStoragePreservesItsOwnerAndErasesEveryAllocation() {
    CheckedMemory memory;

    {
      SensitiveBytes bytes{memory};
      const std::array first{sensitive};

      bytes.append(first, AttachmentLimits::maximum_png_bytes);
      const std::array<std::byte, 128> growth{};

      bytes.append(growth, AttachmentLimits::maximum_png_bytes);
      memory.fail = true;
      try {
        const std::array<std::byte, 256> more{};

        bytes.append(more, AttachmentLimits::maximum_png_bytes);
        check(false, "allocation failure must be visible");
      } catch (const std::bad_alloc&) {
        check(bytes.view().front() == sensitive && bytes.size() == first.size() + growth.size(), "failed growth must preserve the original bytes");
      }

      try {
        bytes.append(first, bytes.size());
        check(false, "quota failure must precede allocation");
      } catch (const std::length_error&) {
        check(bytes.view().front() == sensitive, "quota rejection must preserve storage");
      }

      const auto moved = std::move(bytes);

      check(moved.view().front() == sensitive, "moving must transfer one owner");
    }

    check(memory.live == 0 && !memory.dirty_release, "all old and final allocations must be erased and released");
  }

  void slotReuseKeepsIdentityOrderAndExactTargets() {
    CheckedMemory memory;
    Delivery delivery;

    {
      AttachmentCatalog<CheckedMemory, Delivery> catalog{delivery};

      check(catalog.setTarget(prompt), "the first target must change");
      for (std::uint64_t id = 1; id <= AttachmentLimits::maximum_items; ++id) {
        auto incoming = capture(memory, id);

        check(!catalog.adopt(incoming), "the first four previews must fit");
        check(incoming.png.size() == 0, "adoption must take the PNG owner");
      }

      check(catalog.openModal(2), "a visible preview must open");
      check(catalog.remove(2) && !catalog.snapshot().modal, "retirement must close its modal");
      check(catalog.retainedBytes() == AttachmentLimits::maximum_items, "retired storage remains charged before reaping");
      catalog.reapRetired();
      auto fifth = capture(memory, fifth_id);

      check(!catalog.adopt(fifth), "a dismissed free slot does not report eviction");
      const auto reordered = catalog.snapshot();

      check(reordered.count == AttachmentLimits::maximum_items && reordered.items[0].id == 1 && reordered.items[1].id == 3 && reordered.items[3].id == fifth_id, "slot reuse must preserve chronological order");
      auto sixth = capture(memory, sixth_id);

      check(catalog.adopt(sixth) == AttachmentEviction::items && catalog.find(1) == nullptr, "the fifth retained preview must evict the oldest releasable identity");
      check(catalog.ingressVersion() == sixth_id, "only successful adoptions advance ingress");
      check(catalog.setTarget(other_prompt) && catalog.snapshot().count == 0 && !catalog.openModal(3), "another generation must neither expose nor open old previews");
      check(catalog.removeVisible(other_prompt) == 0, "another generation cannot clear these previews");
      check(catalog.setTarget(prompt) && catalog.snapshot().count == AttachmentLimits::maximum_items, "returning to the same prompt restores its previews");
    }

    check(memory.live == 0 && !memory.dirty_release, "catalog destruction must erase PNG storage");
  }

  void renderLeasesBlockReuseAndFailuresRetainCaptureOwnership() {
    CheckedMemory memory;
    Delivery delivery;
    AttachmentCatalog<CheckedMemory, Delivery> catalog{delivery};

    for (std::uint64_t id = 1; id <= AttachmentLimits::maximum_items; ++id) {
      auto incoming = capture(memory, id);

      static_cast<void>(catalog.adopt(incoming));
      delivery.leased[id - 1] = true;
    }

    check(catalog.remove(1), "leased previews may be dismissed");
    catalog.reapRetired();
    check(catalog.retainedBytes() == AttachmentLimits::maximum_items, "a live render lease must retain its PNG");
    auto fifth = capture(memory, fifth_id);

    try {
      static_cast<void>(catalog.adopt(fifth));
      check(false, "all leased slots must reject reuse");
    } catch (const std::runtime_error& error) {
      check(std::string_view{error.what()} == "AttachmentSelfFull" && fifth.png.size() == 1, "failed adoption must retain the caller's capture");
    }

    delivery.leased[0] = false;
    check(!catalog.adopt(fifth), "releasing a dismissed slot must not report eviction");
    delivery.fail = true;
    delivery.leased[1] = false;
    auto sixth = capture(memory, sixth_id);

    try {
      static_cast<void>(catalog.adopt(sixth));
      check(false, "resource creation failure must propagate");
    } catch (const std::runtime_error& error) {
      check(std::string_view{error.what()} == "DeliveryFailed" && sixth.png.size() == 1, "failed presentation creation must retain the new PNG owner");
    }

    delivery.leased.fill(false);
  }

  void learnedNumbersAndDeletionFramesFollowTheOriginalPrompt() {
    CheckedMemory memory;
    Delivery delivery;
    AttachmentCatalog<CheckedMemory, Delivery> catalog{delivery};

    static_cast<void>(catalog.setTarget(prompt));
    for (std::uint64_t id = 1; id <= 2; ++id) {
      auto incoming = capture(memory, id);

      incoming.request.marker_policy = AttachmentMarkerPolicy::stable_number;
      static_cast<void>(catalog.adopt(incoming));
    }

    constexpr std::uint16_t columns = 80;
    std::array<CellValue, columns> cells;
    const auto put = [&](std::string_view text) {
      cells.fill(CellValue{});
      for (std::size_t index = 0; index < text.size(); ++index) {
        cells[index].text[0] = static_cast<std::uint8_t>(text[index]);
      }
    };

    constexpr std::string_view both = "[Image #11] [Image #12] [Image #3]";

    put(both);
    constexpr std::uint16_t second_end = 23;
    const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = 1, .cursor = {.visible = true, .x = second_end}};

    check(catalog.reconcileMarkers(prompt, screen) == 0, "first reconciliation must learn without retiring previews");
    const auto* const first = catalog.find(1);
    const auto* const second = catalog.find(2);

    check(first != nullptr && second != nullptr, "both previews must be retained");
    if (first == nullptr || second == nullptr) {
      throw std::runtime_error{"MissingAttachment"};
    }

    const auto first_marker_value = first->marker;

    check(first_marker_value.has_value(), "the first preview must learn a marker");
    const auto first_marker = *first_marker_value;
    const auto second_marker_value = second->marker;

    check(second_marker_value.has_value(), "the second preview must learn a marker");
    const auto second_marker = *second_marker_value;
    constexpr std::uint16_t first_number = 11;
    constexpr std::uint16_t second_number = 12;

    check(std::get<std::uint16_t>(first_marker) == first_number && std::get<std::uint16_t>(second_marker) == second_number, "oldest previews must pair with the oldest of the newest unclaimed numbers");
    const auto removal = catalog.planMarkerRemoval(1, screen);

    check(removal.removal && removal.removal->steps == 2 && removal.removal->deletions == 1, "navigation must count another placeholder atomically");
    check(catalog.markerAtDeletion(screen, AttachmentMarkerDeletion::backward) == 2, "backspace at the marker boundary must select its exact preview");
    check(catalog.openModal(2), "the learned second preview must open");

    catalog.expectMarkerDeletion(prompt);
    check(catalog.reconcileMarkers(prompt, screen) == 0, "an unrelated committed frame must retain the pending watch");
    put("[Image #11]");
    check(catalog.reconcileMarkers(prompt, screen) == 1 && !catalog.snapshot().modal, "the next committed deletion must retire only the missing learned marker and close its modal");
    catalog.reapRetired();
    catalog.expectMarkerDeletion(prompt);
    for (std::uint8_t frame = 0; frame < AttachmentLimits::deletion_watch_frames; ++frame) {
      check(catalog.reconcileMarkers(prompt, screen) == 0, "three unchanged frames must expire the watch without deleting anything");
    }

    put("");
    check(catalog.reconcileMarkers(prompt, screen) == 0 && catalog.snapshot().count == 1, "later unrelated screen changes must not retire a preview after its watch expired");
    catalog.expectMarkerDeletion(prompt);
    check(catalog.reconcileMarkers(prompt, screen) == 1 && catalog.snapshot().count == 0, "a new accepted deletion must rearm the learned-marker watch");
    catalog.reapRetired();
  }

  const telar::testing::Case case_sensitive_storage_preserves_its_owner_and_erases_every_allocation{"attachment_catalog.sensitive_storage_preserves_its_owner_and_erases_every_allocation", sensitiveStoragePreservesItsOwnerAndErasesEveryAllocation};
  const telar::testing::Case case_slot_reuse_keeps_identity_order_and_exact_targets{"attachment_catalog.slot_reuse_keeps_identity_order_and_exact_targets", slotReuseKeepsIdentityOrderAndExactTargets};
  const telar::testing::Case case_render_leases_block_reuse_and_failures_retain_capture_ownership{"attachment_catalog.render_leases_block_reuse_and_failures_retain_capture_ownership", renderLeasesBlockReuseAndFailuresRetainCaptureOwnership};
  const telar::testing::Case case_learned_numbers_and_deletion_frames_follow_the_original_prompt{"attachment_catalog.learned_numbers_and_deletion_frames_follow_the_original_prompt", learnedNumbersAndDeletionFramesFollowTheOriginalPrompt};

}
