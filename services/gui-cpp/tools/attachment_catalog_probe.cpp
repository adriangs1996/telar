#include <cstddef>
#include <cstdint>

import std;
import telar.gui.attachments.catalog;
import telar.gui.core.primitives;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t { adopt, invalid_size, excessive_pixels, target, remove, remove_prompt, open_modal, close_modal, reap, lease, fail_delivery, count };
enum class Outcome : std::uint8_t { unchanged, changed, adopted, invalid, pixels, full, delivery };
constexpr std::uint64_t seed = 0x9e3779b97f4a7c15;
constexpr std::uint64_t operation_limit = 16384;
constexpr std::uint64_t target_domain = 4;
constexpr std::uint64_t selection_domain = 17;
constexpr std::uint32_t pixel_overflow = 65536;
constexpr unsigned first_shift = 13;
constexpr unsigned second_shift = 7;
constexpr unsigned third_shift = 17;
constexpr unsigned pane_shift = 8;
constexpr unsigned generation_shift = 16;
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

}

int main() try {
  SystemAllocator memory;
  Delivery delivery;
  Catalog catalog{delivery};
  std::uint64_t random = seed;
  std::uint64_t next_id = 1;
  for (std::uint64_t index = 0; index < operation_limit; ++index) {
    const auto word = randomWord(random);
    const auto operation = static_cast<Operation>(word % static_cast<std::uint64_t>(Operation::count));
    const AttachmentTarget target{.pane_id = (word >> pane_shift) % target_domain, .pane_generation = (word >> generation_shift) % target_domain};
    const auto selected = (word >> selection_shift) % selection_domain;
    const bool flag = (word & 1U) != 0;
    Adoption result;
    if (operation == Operation::adopt || operation == Operation::invalid_size || operation == Operation::excessive_pixels) {
      const auto width = operation == Operation::excessive_pixels ? pixel_overflow : 1U;
      AttachmentCapture<SystemAllocator> capture{
          .request = {.capture = {.id = next_id++, .target = target}},
          .png = SensitiveBytes{memory},
          .width = operation == Operation::invalid_size ? 0U : width,
          .height = operation == Operation::excessive_pixels ? pixel_overflow : 1U,
      };
      constexpr std::array bytes{std::byte{0x5a}};
      capture.png.append(bytes, AttachmentLimits::maximum_png_bytes);
      result = adopt(catalog, capture);
    } else if (operation == Operation::lease) {
      delivery.blocked.fill(flag);
    } else if (operation == Operation::fail_delivery) {
      delivery.fail = flag;
    } else {
      result.outcome = apply(catalog, operation, target, selected, flag);
    }

    observe(catalog, index, operation, selected, result);
  }

  delivery.blocked.fill(false);

  return std::cout.good() ? 0 : 1;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
