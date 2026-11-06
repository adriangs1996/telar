#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>



import telar.gui.graphics.texture_cache;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  frame,
  request,
  complete,
  needed,
  drawn,
  sweep,
  newest,
  deadline,
};

struct Digest {
  static constexpr std::uint64_t basis = 14'695'981'039'346'656'037ULL;
  static constexpr std::uint64_t prime = 1'099'511'628'211ULL;
  std::uint64_t value = basis;

  void add(std::uint64_t number) noexcept {
    constexpr unsigned bits_per_byte = 8;
    constexpr std::uint64_t byte_mask = 0xFF;
    for (unsigned index = 0; index < sizeof(number); ++index) {
      value = (value ^ (number & byte_mask)) * prime;
      number >>= bits_per_byte;
    }
  }
};

struct Releases {
  Digest digest;
  std::uint64_t count = 0;

  void release(ImageTextureHandle handle) noexcept {
    digest.add(handle);
    ++count;
  }
};

using Residency = ImageResidency<Releases>;

ImageTextureIdentity readIdentity() {
  const auto catalog = probe::read<std::uint64_t>();
  const auto image_id = probe::read<std::uint32_t>();
  return {.catalog = {.value = catalog}, .image_id = image_id, .generation = probe::read<std::uint64_t>()};
}

class Probe {
public:
  Probe() {
    images_.emplace(releases_);
  }

  void execute(Operation operation) {
    ImageAdmission result;
    switch (operation) {
    case Operation::reset:
      releases_ = {};
      images_.emplace(releases_);
      now_ns_ = 0;
      break;
    case Operation::frame:
      now_ns_ = probe::read<std::uint64_t>();
      images().beginFrame(now_ns_);
      break;
    case Operation::request:
      result = request();
      break;
    case Operation::complete:
      result.upload = complete();
      break;
    case Operation::needed:
      images().markNeeded(probe::read<std::uint32_t>());
      break;
    case Operation::drawn:
      images().noteDrawn(probe::read<std::uint32_t>());
      break;
    case Operation::sweep:
      sweep();
      break;
    case Operation::newest:
      result.handle = images().newestReady(readIdentity());
      break;
    case Operation::deadline:
      now_ns_ = probe::read<std::uint64_t>();
      break;
    default:
      throw std::runtime_error{"InvalidResidencyOperation"};
    }

    write(result);
  }

private:
  [[nodiscard]] Residency &images() {
    if (!images_) {
      throw std::logic_error{"The residency probe requires its table"};
    }

    return *images_;
  }

  [[nodiscard]] const Residency &images() const {
    if (!images_) {
      throw std::logic_error{"The residency probe requires its table"};
    }

    return *images_;
  }

  ImageAdmission request() {
    const auto identity = readIdentity();
    const auto width = probe::read<std::uint32_t>();
    const auto height = probe::read<std::uint32_t>();
    const auto retained_bytes = probe::read<std::uint64_t>();
    return images().request({.identity = identity, .size = {.width = width, .height = height}, .retained_bytes = static_cast<std::size_t>(retained_bytes), .now_ns = probe::read<std::uint64_t>()});
  }

  bool complete() {
    const auto handle = probe::read<std::uint32_t>();
    const auto success = probe::read<std::uint8_t>() != 0;
    return images().complete(handle, success, probe::read<std::uint64_t>());
  }

  void sweep() {
    const auto catalogs = probe::read<std::uint64_t>();
    const auto generations = probe::read<std::uint64_t>();
    images().sweep([&](ImageTextureIdentity identity) noexcept {
      constexpr auto mask_bits = 64;
      return ((catalogs >> (identity.catalog.value - 1)) & 1U) != 0 && ((generations >> (identity.generation % mask_bits)) & 1U) != 0;
    });
  }

  [[nodiscard]] Digest digest() const {
    Digest digest;
    for (const auto row : images().rows()) {
      const auto *state = images().state(Residency::handleOf(row));
      if (state == nullptr) {
        throw std::runtime_error{"MissingResidentImage"};
      }

      digest.add(row);
      digest.add(static_cast<std::uint64_t>(state->stage));
      digest.add(state->identity.catalog.value);
      digest.add(state->identity.image_id);
      digest.add(state->identity.generation);
      digest.add(state->size.width);
      digest.add(state->size.height);
      digest.add(state->bytes);
      digest.add(state->started_ns);
      digest.add(state->used_frame);
      digest.add(state->used_ns);
      digest.add(state->presented ? 1 : 0);
    }

    return digest;
  }

  void write(ImageAdmission result) const {
    probe::write(result.handle);
    probe::write(static_cast<std::uint8_t>(result.upload));
    probe::write(static_cast<std::uint8_t>(result.reuse));
    probe::write(images().frame());
    probe::write(images().revision());
    probe::write(images().presented());
    probe::write(static_cast<std::uint64_t>(images().residentBytes()));
    probe::write(static_cast<std::uint64_t>(images().uploading()));
    probe::write(static_cast<std::uint64_t>(images().spares()));
    probe::write(static_cast<std::uint64_t>(images().size()));
    probe::write(digest().value);
    probe::write(releases_.count);
    probe::write(releases_.digest.value);
    probe::write(images().wakeupAfter(now_ns_));
    probe::write(static_cast<std::uint8_t>(images().trimDue(now_ns_)));
  }

  Releases releases_;
  std::optional<Residency> images_;
  std::uint64_t now_ns_ = 0;
};

}

int main() {
  try {
    Probe probe;
    while (true) {
      const auto operation = std::getchar();
      if (operation == EOF) {
        return 0;
      }

      probe.execute(static_cast<Operation>(operation));
    }
  } catch (const std::exception &error) {
    std::cerr << "gui-image-residency-probe: " << error.what() << '\n';
    return 1;
  }
}
