#include "attachments/catalog.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "attachments/marker_screen.hpp"
#include "attachments/marker_removal.hpp"
#include "attachments/path_markers.hpp"
#include "terminal/screen.hpp"
#include <variant>
#include "core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t { adopt, invalid_size, excessive_pixels, target, remove, remove_prompt, open_modal, close_modal, reap, lease, fail_delivery, reconcile, expect_deletion, remove_at_cursor, plan_remove, pending_at_cursor, idle, count };
enum class Outcome : std::uint8_t { unchanged, changed, adopted, invalid, pixels, full, delivery };
constexpr std::uint64_t seed = 0x9e3779b97f4a7c15;
constexpr std::uint64_t operation_limit = 16384;
constexpr std::uint64_t selection_domain = 17;
constexpr std::uint32_t pixel_overflow = 65536;
constexpr unsigned first_shift = 13;
constexpr unsigned second_shift = 7;
constexpr unsigned third_shift = 17;
constexpr unsigned selection_shift = 32;

struct Delivery {
  struct SlotState {
    std::size_t index;
  };

  SlotState create() {
    if (fail) {
      throw std::runtime_error{"DeliveryFailed"};
    }

    blocked[next] = false;

    return {.index = next++};
  }

  void retire([[maybe_unused]] SlotState state) noexcept {}

  [[nodiscard]] bool canRelease(SlotState slot) const noexcept {
    return !blocked[slot.index];
  }

  std::array<bool, operation_limit> blocked{};
  std::size_t next = 0;
  bool fail = false;
};

using Catalog = AttachmentCatalog<SystemAllocator, Delivery>;

std::uint64_t randomWord(std::uint64_t &state) {
  state ^= state << first_shift;
  state ^= state >> second_shift;
  state ^= state << third_shift;

  return state;
}

void write(std::uint64_t value) {
  std::array<char, sizeof(value)> bytes{};
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    bytes[index] = static_cast<char>((value >> (index * std::numeric_limits<unsigned char>::digits)) & std::numeric_limits<unsigned char>::max());
  }

  std::cout.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

struct Adoption {
  Outcome outcome = Outcome::unchanged;
  std::uint64_t evicted = 0;
  std::uint64_t extra = 0;
  std::optional<AttachmentMarkerPlan> planned = std::nullopt;
};

Adoption adopt(Catalog &catalog, AttachmentCapture<SystemAllocator> &capture) {
  try {
    const auto evicted = catalog.adopt(capture);

    const auto reason = evicted ? static_cast<std::uint64_t>(*evicted) + 1 : 0;

    return {.outcome = Outcome::adopted, .evicted = reason};
  } catch (const std::invalid_argument &) {
    return {.outcome = Outcome::invalid};
  } catch (const std::length_error &) {
    return {.outcome = Outcome::pixels};
  } catch (const std::runtime_error &error) {
    if (std::string_view{error.what()} == "AttachmentSelfFull") {
      return {.outcome = Outcome::full};
    }

    if (std::string_view{error.what()} == "DeliveryFailed") {
      return {.outcome = Outcome::delivery};
    }

    throw;
  }
}

Outcome apply(Catalog &catalog, Operation operation, AttachmentTarget target, std::uint64_t selected, bool flag) {
  bool changed = false;
  switch (operation) {
  case Operation::target:
    changed = catalog.setTarget(flag ? std::optional{target} : std::nullopt);
    break;
  case Operation::remove:
    changed = catalog.remove(selected);
    break;
  case Operation::remove_prompt:
    changed = catalog.removeVisible(target) != 0;
    break;
  case Operation::open_modal:
    changed = catalog.openModal(selected);
    break;
  case Operation::close_modal:
    changed = catalog.closeModal();
    break;
  case Operation::reap:
    catalog.reapRetired();
    break;
  default:
    break;
  }

  return changed ? Outcome::changed : Outcome::unchanged;
}

struct Frame {
  static constexpr std::uint16_t columns = 256;
  static constexpr std::uint16_t rows = 3;
  std::array<CellValue, static_cast<std::size_t>(columns) * rows> cells;

  AttachmentMarkerScreen prepare(std::uint64_t word) {
    cells.fill(CellValue{});
    constexpr unsigned variant_shift = 20;
    constexpr std::array<std::string_view, 9> texts{
        "[Image #1] [Image #2] [Image #3]",
        "[Image #11] [Image #12] [Image #3]",
        "[Image #11]",
        "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png /tmp/pi-clipboard-87654321-4321-DCBA-4321-cba987654321.png",
        "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
        "",
        "[Image #1]",
        "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
        "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png",
    };
    const auto variant = (word >> variant_shift) % texts.size();
    const auto text = texts[variant];
    for (std::size_t index = 0; index < text.size(); ++index) {
      cells[((index / (columns - 1)) * columns) + (index % (columns - 1))].text[0] = static_cast<std::uint8_t>(text[index]);
    }

    constexpr std::size_t distant_number_variant = 6;
    auto cursor = (word & 4U) != 0 ? text.size() : 0;
    if (variant == distant_number_variant) {
      cursor = columns - 1;
    }

    return {.cells = cells, .columns = columns, .rows = rows, .cursor = {.visible = (word & 2U) != 0, .x = static_cast<std::uint16_t>(variant == distant_number_variant ? cursor : cursor % (columns - 1)), .y = static_cast<std::uint16_t>(variant == distant_number_variant ? 0 : cursor / (columns - 1))}};
  }
};

void observeMarkers(const Catalog &catalog, Adoption result) {
  write(result.extra);
  const auto visible = catalog.snapshot();
  for (std::size_t index = 0; index < visible.count; ++index) {
    const auto *const slot = catalog.find(visible.items[index].id);
    if (slot == nullptr) {
      throw std::logic_error{"MissingProbeSlot"};
    }

    const auto *const number = slot->marker ? std::get_if<std::uint16_t>(&*slot->marker) : nullptr;
    const auto *const path = slot->marker ? std::get_if<AttachmentPathUuid>(&*slot->marker) : nullptr;
    write(number != nullptr ? *number : 0);
    write(path != nullptr ? 1U : 0U);
    if (path != nullptr) {
      for (const auto byte : *path) {
        write(byte);
      }
    }
  }

  if (!result.planned) {
    write(0);
  } else if (result.planned->limit) {
    write(2);
    write(static_cast<std::uint64_t>(*result.planned->limit));
    write(result.planned->requested ? static_cast<std::uint64_t>(*result.planned->requested) : std::numeric_limits<std::uint64_t>::max());
  } else if (result.planned->removal) {
    const auto removal = *result.planned->removal;
    write(3);
    write(static_cast<std::uint64_t>(removal.direction));
    write(removal.steps);
    write(static_cast<std::uint64_t>(removal.deletion));
    write(removal.deletions);
    write(removal.keyCount());
  } else {
    write(1);
  }
}

void observe(const Catalog &catalog, std::uint64_t index, Operation operation, std::uint64_t selected, Adoption result) {
  const auto visible = catalog.snapshot();
  const auto active = catalog.target().value_or(AttachmentTarget{});
  for (const auto value : std::array{index, static_cast<std::uint64_t>(operation), selected, static_cast<std::uint64_t>(result.outcome), result.evicted, active.pane_id, active.pane_generation, visible.modal.value_or(0), static_cast<std::uint64_t>(catalog.retainedBytes()), catalog.ingressVersion(), static_cast<std::uint64_t>(visible.count), static_cast<std::uint64_t>(catalog.cleanupPending())}) {
    write(value);
  }

  for (std::size_t slot = 0; slot < AttachmentLimits::maximum_items; ++slot) {
    write(slot < visible.count ? visible.items[slot].id : 0);
  }
}


struct Step {
  Operation operation = Operation::idle;
  AttachmentTarget target;
  std::uint64_t selected = 0;
  bool flag = false;
  AttachmentMarkerPolicy policy = AttachmentMarkerPolicy::ordered;
  AttachmentMarkerScreen screen;
};

Adoption adoptCapture(Catalog &catalog, SystemAllocator &memory, const Step &step, std::uint64_t &next_id) {
  const auto width = step.operation == Operation::excessive_pixels ? pixel_overflow : 1U;
  AttachmentCapture<SystemAllocator> capture{
      .request = {.capture = {.id = next_id++, .target = step.target}, .marker_policy = step.policy},
      .png = SensitiveBytes{memory},
      .width = step.operation == Operation::invalid_size ? 0U : width,
      .height = step.operation == Operation::excessive_pixels ? pixel_overflow : 1U,
  };
  constexpr std::array bytes{std::byte{0x5a}};
  capture.png.append(bytes, AttachmentLimits::maximum_png_bytes);

  return adopt(catalog, capture);
}

Adoption execute(Catalog &catalog, Delivery &delivery, SystemAllocator &memory, Step &step, std::uint64_t &next_id) {
  const auto focused = catalog.target().value_or(step.target);
  const auto deletion = step.flag ? AttachmentMarkerDeletion::backward : AttachmentMarkerDeletion::forward;
  switch (step.operation) {
  case Operation::reconcile:
    return {.extra = catalog.reconcileMarkers(focused, step.screen)};
  case Operation::expect_deletion:
    catalog.expectMarkerDeletion(focused);
    return {};
  case Operation::remove_at_cursor:
    if (const auto id = catalog.markerAtDeletion(step.screen, deletion)) {
      return {.outcome = catalog.remove(*id) ? Outcome::changed : Outcome::unchanged, .extra = *id};
    }
    return {};
  case Operation::plan_remove: {
    const auto visible = catalog.snapshot();
    if (visible.count != 0) {
      step.selected = visible.items[step.selected % visible.count].id;
    }
    return {.planned = catalog.planMarkerRemoval(step.selected, step.screen)};
  }
  case Operation::pending_at_cursor:
    return {.extra = catalog.pendingMarkerAtDeletion(step.screen, step.policy, deletion) ? 1U : 0U};
  case Operation::adopt:
  case Operation::invalid_size:
  case Operation::excessive_pixels:
    return adoptCapture(catalog, memory, step, next_id);
  case Operation::lease:
    delivery.blocked.fill(step.flag);
    return {};
  case Operation::fail_delivery:
    delivery.fail = step.flag;
    return {};
  default:
    return {.outcome = apply(catalog, step.operation, step.target, step.selected, step.flag)};
  }
}

struct Prelude {
  Operation operation = Operation::idle;
  AttachmentMarkerPolicy policy = AttachmentMarkerPolicy::ordered;
  std::uint64_t variant = 6;
};
constexpr std::array prelude{
    Prelude{.operation = Operation::target},
    Prelude{.operation = Operation::adopt},
    Prelude{.operation = Operation::plan_remove},
    Prelude{.operation = Operation::remove_prompt},
    Prelude{.operation = Operation::adopt, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 7},
    Prelude{.operation = Operation::reconcile, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 7},
    Prelude{.operation = Operation::plan_remove, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 7},
    Prelude{.operation = Operation::remove_prompt},
    Prelude{.operation = Operation::adopt, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 8},
    Prelude{.operation = Operation::reconcile, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 8},
    Prelude{.operation = Operation::plan_remove, .policy = AttachmentMarkerPolicy::pasted_path, .variant = 8},
};

}

int main() try {
  SystemAllocator memory;
  Delivery delivery;
  Catalog catalog{delivery};
  std::uint64_t random = seed;
  std::uint64_t next_id = 1;
  Frame frame;
  for (std::uint64_t index = 0; index < operation_limit; ++index) {
    auto word = randomWord(random);
    const bool controlled = index < prelude.size();
    constexpr unsigned variant_shift = 20;
    constexpr std::uint64_t visible_end_and_flag = 7;
    if (controlled) {
      word = (prelude[index].variant << variant_shift) | visible_end_and_flag;
    }

    constexpr unsigned target_shift = 40;
    constexpr unsigned policy_shift = 24;
    const bool alternate = controlled || (word & (std::uint64_t{1} << target_shift)) != 0;
    Step step{
        .operation = controlled ? prelude[index].operation : static_cast<Operation>(word % static_cast<std::uint64_t>(Operation::count)),
        .target = {.pane_id = alternate ? 1U : 2U, .pane_generation = alternate ? 2U : 3U},
        .selected = (word >> selection_shift) % selection_domain,
        .flag = (word & 1U) != 0,
        .policy = controlled ? prelude[index].policy : static_cast<AttachmentMarkerPolicy>((word >> policy_shift) % 3),
        .screen = frame.prepare(word),
    };
    const auto result = execute(catalog, delivery, memory, step, next_id);
    observe(catalog, index, step.operation, step.selected, result);
    observeMarkers(catalog, result);
  }

  delivery.blocked.fill(false);

  return std::cout.good() ? 0 : 1;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
