#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <cstdint>
#include <exception>
#include <atomic>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include "probe_graphics.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstdio>
#include <iostream>
#include <optional>
#include <span>
#include <stdexcept>
#include <vector>

#include "core/memory.hpp"


import telar.gui.graphics.texture_cache;

namespace {

using namespace telar;
using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  snapshot,
  image,
  chunk,
  placement,
  delete_image,
  delete_placement,
  detach,
};

enum class Outcome : std::uint8_t {
  applied,
  resync,
  image_limit,
  placement_limit,
  chunk_limit,
  byte_limit,
  malformed,
};

std::uint64_t checksum(std::span<const Byte> bytes) noexcept {
  constexpr std::uint64_t basis = 14'695'981'039'346'656'037ULL;
  constexpr std::uint64_t prime = 1'099'511'628'211ULL;
  auto hash = basis;
  for (const auto byte : bytes) {
    hash = (hash ^ byte) * prime;
  }

  return hash;
}

class Probe {
public:
  Probe() {
    reset();
  }

  void execute(Operation operation) {
    auto outcome = Outcome::applied;
    try {
      if (operation == Operation::reset) {
        reset();
      } else {
        apply(operation);
      }
    } catch (const GraphicsResyncRequired &) {
      outcome = Outcome::resync;
    } catch (const GraphicsLimitError &error) {
      switch (error.kind()) {
      case GraphicsLimitKind::images:
        outcome = Outcome::image_limit;
        break;
      case GraphicsLimitKind::placements:
        outcome = Outcome::placement_limit;
        break;
      case GraphicsLimitKind::chunks:
        outcome = Outcome::chunk_limit;
        break;
      case GraphicsLimitKind::bytes:
        outcome = Outcome::byte_limit;
        break;
      }
    } catch (const EncodingError &) {
      outcome = Outcome::malformed;
    }

    write(outcome);
  }

private:
  using Store = GraphicsStore<SystemAllocator>;
  static constexpr std::size_t pane_count = 4;

  void reset() {
    for (auto &store : stores_) {
      store.reset();
    }

    for (auto &store : stores_) {
      store.emplace(memory_, budget_);
    }
  }

  void apply(Operation operation) {
    const auto pane_id = probe::read<std::uint8_t>();
    const GraphicsHeader header{.pane_id = pane_id, .revision = probe::read<std::uint64_t>()};
    auto &slot = stores_.at(pane_id - 1);
    if (!slot) {
      throw std::logic_error{"Graphics pane store is not initialized"};
    }

    auto &store = *slot;
    switch (operation) {
    case Operation::snapshot:
      store.snapshot({.header = header, .phase = static_cast<SnapshotPhase>(probe::read<std::uint8_t>())});
      break;
    case Operation::image:
      store.image({.header = header, .image = probe::readImage()});
      break;
    case Operation::chunk: {
      const auto key = probe::readImageKey();
      const auto offset = probe::read<std::uint64_t>();
      const auto bytes = probe::readText(memory_);
      store.chunk({.header = header, .key = key, .offset = offset, .bytes = byteView(bytes)});
      break;
    }
    case Operation::placement:
      store.placement({.header = header, .placement = probe::readPlacement()});
      break;
    case Operation::delete_image:
      store.erase(GraphicsDeleteImage{.header = header, .key = probe::readImageKey()});
      break;
    case Operation::delete_placement: {
      const auto key = probe::readImageKey();
      const auto virtual_id = probe::read<std::uint64_t>();
      store.erase(GraphicsDeletePlacement{.header = header, .key = key, .virtual_id = virtual_id, .placement_id = probe::read<std::uint32_t>()});
      break;
    }
    case Operation::detach:
      store.detach();
      break;
    default:
      throw std::invalid_argument{"Unknown graphics store operation"};
    }
  }

  void write(Outcome outcome) {
    probe::write(static_cast<std::uint8_t>(outcome));
    probe::write(static_cast<std::uint64_t>(budget_.used));
    for (auto &store : stores_) {
      if (!store) {
        throw std::logic_error{"Graphics pane store is not initialized"};
      }

      auto &pane = *store;
      probe::write(pane.takeCredit());
      std::vector<const Store::Image *> images;
      pane.visitImages([&](const Store::Image &image) {
        images.push_back(&image);
      });
      std::ranges::sort(images, [](const auto *left, const auto *right) {
        const auto first = left->description().key;
        const auto second = right->description().key;

        return first.image_id == second.image_id ? first.generation < second.generation : first.image_id < second.image_id;
      });
      probe::write(static_cast<std::uint32_t>(images.size()));
      for (const auto *image : images) {
        probe::writeImage(image->description());
        probe::write(static_cast<std::uint64_t>(image->receivedPixels().size()));
        probe::write(static_cast<std::uint8_t>(image->retired()));
        probe::write(checksum(image->receivedPixels()));
      }

      std::vector placements(pane.placements().begin(), pane.placements().end());
      std::ranges::sort(placements, {}, &GraphicsPlacement::virtual_id);
      probe::write(static_cast<std::uint32_t>(placements.size()));
      for (const auto &placement : placements) {
        probe::writePlacement(placement);
      }
    }
  }

  SystemAllocator memory_;
  GraphicsBudget budget_;
  std::array<std::optional<Store>, pane_count> stores_;
};

}

int main() {
  try {
    Probe probe;
    for (auto value = std::getchar(); value != EOF; value = std::getchar()) {
      probe.execute(static_cast<Operation>(value));
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
