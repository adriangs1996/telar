module;
#include "telar_platform/trace_macro.hpp"

#include "telar_base/diagnostics/config.hpp"

module telar.runtime.graphics.prepared_images;

import telar.sys.posix;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.base.ds;

namespace telar::runtime {

  FrozenImage::FrozenImage(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget, std::span<const std::uint8_t> pixels, bool shared)
      : memory_(&memory),
        budget_(&budget) {
    TELAR_TRACE("media.freezeImage");
    if (!budget_->reserve(pixels.size())) {
      throw std::bad_alloc{};
    }

    byte_count_ = pixels.size();
    reserved_bytes_ = pixels.size();

    try {
      if (shared && freezeShared(pixels)) {
        return;
      }

      pixels_ = static_cast<std::uint8_t*>(memory_->allocate(byte_count_, alignof(std::uint8_t)));
      if (pixels_ == nullptr) {
        throw std::bad_alloc{};
      }

      std::memcpy(pixels_, pixels.data(), pixels.size());
    } catch (...) {
      reset();
      throw;
    }
  }

  FrozenImage::~FrozenImage() {
    reset();
  }

  FrozenImage::FrozenImage(FrozenImage&& other) noexcept {
    take(other);
  }

  auto FrozenImage::operator=(FrozenImage&& other) noexcept -> FrozenImage& {
    if (this != &other) {
      reset();
      take(other);
    }

    return *this;
  }

  std::span<const std::uint8_t> FrozenImage::pixels() const noexcept {
    return {pixels_, pixels_ == nullptr ? 0 : byte_count_};
  }

  std::size_t FrozenImage::byteCount() const noexcept {
    return byte_count_;
  }

  std::string_view FrozenImage::name() const noexcept {
    return name_.data();
  }

  void FrozenImage::published() noexcept {
    owns_name_ = false;
  }

  auto FrozenImage::adoptSharedName(SharedImageStorage::Name name, std::size_t byte_count) noexcept -> FrozenImage {
    FrozenImage image;

    image.name_ = name;
    image.owns_name_ = true;
    image.byte_count_ = byte_count;
    return image;
  }

  bool FrozenImage::freezeShared(std::span<const std::uint8_t> pixels) noexcept {
    auto shared = SharedImageStorage::create(pixels.size());
    if (!shared) {
      return false;
    }

    std::memcpy(shared.getMut().mapping().bytes().data(), pixels.data(), pixels.size());
    name_ = shared.getMut().takeName();
    owns_name_ = true;
    return true;
  }

  void FrozenImage::removeName() noexcept {
    if (owns_name_) {
      ::shm_unlink(name_.data());
    }

    name_.atMut(0) = '\0';
    owns_name_ = false;
  }

  void FrozenImage::reset() noexcept {
    removeName();
    if (pixels_ != nullptr) {
      memory_->deallocate(pixels_, byte_count_, alignof(std::uint8_t));
      pixels_ = nullptr;
    }

    if (reserved_bytes_ != 0) {
      budget_->release(std::exchange(reserved_bytes_, 0));
    }

    byte_count_ = 0;
  }

  void FrozenImage::take(FrozenImage& other) noexcept {
    memory_ = other.memory_;
    budget_ = other.budget_;
    pixels_ = std::exchange(other.pixels_, nullptr);
    byte_count_ = std::exchange(other.byte_count_, 0);
    reserved_bytes_ = std::exchange(other.reserved_bytes_, 0);
    name_ = other.name_;
    other.name_.atMut(0) = '\0';
    owns_name_ = std::exchange(other.owns_name_, false);
  }

  PreparedImages::PreparedImages(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  void PreparedImages::prepare(std::span<const GraphicsImageView> images) noexcept {
    TELAR_TRACE("media.prepareShared");
    retain(images);
    for (const auto& image : images) {
      if (covered(image.description.key)) {
        continue;
      }

      auto* slot = availableSlot(image.description.key.image_id);
      if (slot == nullptr) {
        continue;
      }

      slot->reset();
      try {
        FrozenImage frozen{memory_, budget_, image.pixels, true};
        if (frozen.name().empty()) {
          continue;
        }

        slot->emplace(Entry{image.description.key, std::move(frozen)});
        remember(image.description.key);
        TELAR_DIAGNOSTIC(diagnostics::accumulate(prepared_count_));
      } catch (...) {
      }
    }
  }

  ds::Option<FrozenImage> PreparedImages::take(ImageKey key) noexcept {
    for (auto& slot : entries_.viewMut()) {
      if (slot && sameImage(slot->key, key)) {
        auto frozen = std::move(slot.getMut().frozen);

        slot.reset();
        return frozen;
      }
    }

    return ds::none;
  }

  bool PreparedImages::put(ImageKey key, FrozenImage&& image) noexcept {
    auto* slot = availableSlot(key.image_id);
    if (slot == nullptr) {
      return false;
    }

    slot->emplace(Entry{key, std::move(image)});
    remember(key);
    return true;
  }

  void PreparedImages::clear() noexcept {
    for (auto& slot : entries_.viewMut()) {
      slot.reset();
    }

    frozen_.fill({});
  }

#if TELAR_DIAGNOSTICS
  std::uint64_t PreparedImages::takePreparedCount() noexcept {
    return std::exchange(prepared_count_, 0);
  }
#endif

#if TELAR_DIAGNOSTICS
  std::size_t PreparedImages::storedBytes() const noexcept {
    std::size_t bytes = 0;

    for (const auto& entry : entries_) {
      if (entry) {
        bytes += entry->frozen.byteCount();
      }
    }

    return bytes;
  }
#endif

  void PreparedImages::retain(std::span<const GraphicsImageView> images) noexcept {
    for (auto& slot : entries_.viewMut()) {
      if (slot && std::ranges::none_of(images, [&](const auto& image) {
            return sameImage(slot->key, image.description.key);
          })) {
        slot.reset();
      }
    }

    for (auto& key : frozen_.viewMut()) {
      if (key.image_id != 0 && std::ranges::none_of(images, [&](const auto& image) {
            return key.image_id == image.description.key.image_id;
          })) {
        key = {};
      }
    }
  }

  bool PreparedImages::covered(ImageKey key) const noexcept {
    return std::ranges::any_of(frozen_, [&](auto known) {
      return known.image_id == key.image_id && known.generation >= key.generation;
    });
  }

  auto PreparedImages::availableSlot(std::uint32_t identity) noexcept -> ds::Option<Entry>* {
    ds::Option<Entry>* free = nullptr;

    for (auto& slot : entries_.viewMut()) {
      if (slot && slot->key.image_id == identity) {
        return &slot;
      }

      if (!slot && free == nullptr) {
        free = &slot;
      }
    }

    return free;
  }

  void PreparedImages::remember(ImageKey key) noexcept {
    const auto frozen = frozen_.viewMut();
    auto found = std::ranges::find_if(frozen, [&](auto known) {
      return known.image_id == key.image_id;
    });
    if (found == frozen.end()) {
      found = std::ranges::find_if(frozen, [](auto known) {
        return known.image_id == 0;
      });
    }

    if (found != frozen.end()) {
      *found = key;
    }
  }

  TransferRequests::TransferRequests(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  bool TransferRequests::request(ImageKey key, bool shared) noexcept {
    ds::Option<Entry>* free = nullptr;

    for (auto& entry : entries_.viewMut()) {
      if (entry && entry->shared == shared && sameImage(entry->key, key)) {
        return false;
      }

      if (!entry && free == nullptr) {
        free = &entry;
      }
    }

    if (free == nullptr) {
      return false;
    }

    free->emplace(Entry{.key = key, .shared = shared});
    return true;
  }

  ds::Option<FrozenImage> TransferRequests::take(ImageKey key, bool shared) {
    for (auto& entry : entries_.viewMut()) {
      if (!entry || entry->shared != shared || !sameImage(entry->key, key) || entry->state == State::pending) {
        continue;
      }

      const bool failed = entry->state == State::failed;
      auto frozen = std::move(entry.getMut().frozen);

      entry.reset();
      if (failed) {
        throw std::bad_alloc{};
      }

      return frozen;
    }

    return ds::none;
  }

  void TransferRequests::process(std::span<const GraphicsImageView> images) noexcept {
    TELAR_TRACE("media.prepareTransfers");
    for (auto& entry : entries_.viewMut()) {
      if (!entry) {
        continue;
      }

      const auto image = std::ranges::find_if(images, [&](const auto& image) {
        return sameImage(entry->key, image.description.key);
      });
      if (image == images.end()) {
        entry.reset();
        continue;
      }

      if (entry->state != State::pending) {
        continue;
      }

      try {
        const bool shared = entry->shared;

        entry.getMut().frozen.emplace(memory_, budget_, image->pixels, shared);
        entry.getMut().state = State::ready;
      } catch (...) {
        entry.getMut().state = State::failed;
      }
    }
  }

  void TransferRequests::clear() noexcept {
    for (auto& entry : entries_.viewMut()) {
      entry.reset();
    }
  }

#if TELAR_DIAGNOSTICS
  std::size_t TransferRequests::storedBytes() const noexcept {
    std::size_t bytes = 0;

    for (const auto& entry : entries_) {
      if (entry) {
        bytes += entry->frozen ? entry->frozen->byteCount() : 0;
      }
    }

    return bytes;
  }
#endif

}
