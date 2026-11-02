#pragma once

#include "graphics/limits.hpp"
#include "lifetime.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::gui {

using ImageTextureHandle = std::uint32_t;
inline constexpr std::size_t image_texture_capacity = 512;

struct ImageTextureIdentity {
  GraphicsLifetime catalog;
  std::uint32_t image_id = 0;
  std::uint64_t generation = 0;

  bool operator==(const ImageTextureIdentity &) const noexcept = default;

  [[nodiscard]] bool sameImage(const ImageTextureIdentity &other) const noexcept {
    return catalog == other.catalog && image_id == other.image_id;
  }
};

struct ImageTextureSize {
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  bool operator==(const ImageTextureSize &) const noexcept = default;
};

enum class ImageTextureStage : std::uint8_t {
  free,
  uploading,
  ready,
  failed,
  spare,
};

struct ImageTextureState {
  ImageTextureIdentity identity;
  ImageTextureSize size;
  ImageTextureStage stage = ImageTextureStage::free;
  std::uint64_t started_ns = 0;
  std::uint64_t used_ns = 0;
  std::uint64_t used_frame = 0;
  std::size_t bytes = 0;
  bool presented = false;
};

struct ImageAdmission {
  ImageTextureHandle handle = 0;
  bool upload = false;
  bool reuse = false;
};

struct ImageTextureRequest {
  ImageTextureIdentity identity;
  ImageTextureSize size;
  std::size_t retained_bytes = 0;
  std::uint64_t now_ns = 0;
};

struct ImageTextureUse {
  ImageTextureHandle handle = 0;
  std::uint64_t now_ns = 0;
};

template <typename Resources>
concept ImageTextureReleases = requires(Resources &resources, ImageTextureHandle handle) {
  { resources.release(handle) } noexcept -> std::same_as<void>;
};

template <ImageTextureReleases Resources>
class ImageResidency {
public:
  static constexpr std::size_t capacity = image_texture_capacity;
  static constexpr std::size_t byte_capacity = runtime::GraphicsLimits::maximum_global_bytes;
  static constexpr std::uint32_t maximum_side = 16384;
  static constexpr std::size_t maximum_uploads = 4;
  static constexpr std::size_t uploads_per_image = 2;
  static constexpr std::size_t maximum_spares = 4;
  static constexpr std::uint64_t spare_lifetime_ns = 2'000'000'000;
  static constexpr std::uint64_t idle_lifetime_ns = 5'000'000'000;

  explicit ImageResidency(Resources &resources) noexcept
      : resources_(resources) {
    for (std::size_t index = 0; index < capacity; ++index) {
      free_[index] = static_cast<Row>(capacity - 1 - index);
    }
  }

  ~ImageResidency() = default;

  ImageResidency(const ImageResidency &) = delete;
  ImageResidency &operator=(const ImageResidency &) = delete;
  ImageResidency(ImageResidency &&) = delete;
  ImageResidency &operator=(ImageResidency &&) = delete;

  void beginFrame(std::uint64_t now_ns) noexcept {
    ++frame_;
    now_ns_ = now_ns;
    started_this_frame_ = 0;
    std::size_t index = 0;
    while (index < count_) {
      const auto row = occupied_[index];
      const auto deadline = expiry(states_[row]);
      if (deadline && *deadline <= now_ns_ && states_[row].used_frame != frame_) {
        discard(row);
      } else {
        ++index;
      }
    }
  }

  [[nodiscard]] ImageAdmission request(ImageTextureRequest request) noexcept {
    const auto identity = request.identity;
    const auto size = request.size;
    if (!identity.catalog.cacheable() || size.width == 0 || size.height == 0) {
      return {};
    }

    if (const auto handle = find(identity); handle != 0) {
      return {.handle = handle};
    }

    if (uploading_ == maximum_uploads || started_this_frame_ == maximum_uploads || uploadsOf(identity) == uploads_per_image) {
      return {};
    }

    const auto row = takeRow(identity, size, request.retained_bytes);
    if (!row) {
      return {};
    }

    auto &state = states_[*row];
    if (size.width > maximum_side || size.height > maximum_side) {
      return {.handle = handleOf(*row)};
    }

    const bool reuse = state.bytes != 0;
    if (!reuse) {
      state.bytes = byteSize(size);
      resident_bytes_ += state.bytes;
    }

    state.stage = ImageTextureStage::uploading;
    state.started_ns = request.now_ns;
    state.used_ns = request.now_ns;
    ++uploading_;
    ++started_this_frame_;

    return {.handle = handleOf(*row), .upload = true, .reuse = reuse};
  }

  bool complete(ImageTextureHandle handle, bool success, std::uint64_t now_ns) noexcept {
    auto *state = findState(handle);
    if (state == nullptr || state->stage != ImageTextureStage::uploading) {
      return false;
    }

    --uploading_;
    ++revision_;
    if (success) {
      state->stage = ImageTextureStage::ready;
      state->used_ns = now_ns;
    } else {
      state->stage = ImageTextureStage::failed;
      resident_bytes_ -= state->bytes;
      state->bytes = 0;
    }

    return true;
  }

  void abandon() noexcept {
    for (const auto row : rows()) {
      auto &state = states_[row];
      if (state.stage == ImageTextureStage::uploading) {
        state.stage = ImageTextureStage::failed;
        --uploading_;
      }
    }
  }

  void clear() noexcept {
    abandon();
    while (count_ != 0) {
      discard(occupied_[0]);
    }
  }

  void markNeeded(ImageTextureHandle handle) noexcept {
    if (auto *state = findState(handle)) {
      state->used_frame = frame_;
      state->used_ns = now_ns_;
    }
  }

  void keepWarm(ImageTextureUse use) noexcept {
    if (auto *state = findState(use.handle); state != nullptr && state->stage == ImageTextureStage::ready) {
      state->used_ns = use.now_ns;
    }
  }

  void noteDrawn(ImageTextureHandle handle) noexcept {
    auto *state = findState(handle);
    if (state == nullptr) {
      return;
    }

    markNeeded(handle);
    if (!state->presented) {
      state->presented = true;
      ++presented_;
    }
  }

  template <typename IsRetained>
    requires std::predicate<const IsRetained &, ImageTextureIdentity>
  void sweep(const IsRetained &is_retained) noexcept(noexcept(is_retained(ImageTextureIdentity{}))) {
    sweepRows([&](std::uint16_t row) noexcept(noexcept(is_retained(ImageTextureIdentity{}))) {
      return is_retained(states_[row].identity);
    });
  }

  void sweep(std::span<const bool, capacity> retained) noexcept {
    sweepRows([retained](std::uint16_t row) noexcept {
      return retained[row];
    });
  }

  [[nodiscard]] ImageTextureHandle find(ImageTextureIdentity identity) const noexcept {
    for (const auto row : rows()) {
      const auto &state = states_[row];
      if (state.stage != ImageTextureStage::spare && state.identity == identity) {
        return handleOf(row);
      }
    }

    return 0;
  }

  [[nodiscard]] ImageTextureHandle newestReady(ImageTextureIdentity identity) const noexcept {
    std::optional<Row> best;
    for (const auto row : rows()) {
      const auto &state = states_[row];
      if (state.stage == ImageTextureStage::ready && state.identity.sameImage(identity) && (!best || states_[*best].identity.generation < state.identity.generation)) {
        best = row;
      }
    }

    return best ? handleOf(*best) : 0;
  }

  [[nodiscard]] const ImageTextureState *state(ImageTextureHandle handle) const noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  [[nodiscard]] std::uint32_t wakeupAfter(std::uint64_t now_ns) const noexcept {
    std::optional<std::uint64_t> earliest;
    for (const auto row : rows()) {
      const auto deadline = expiry(states_[row]);
      if (deadline && (!earliest || *deadline < *earliest)) {
        earliest = deadline;
      }
    }

    if (!earliest) {
      return 0;
    }

    const auto remaining = *earliest > now_ns ? *earliest - now_ns : 0;
    constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
    const auto milliseconds = (remaining / nanoseconds_per_millisecond) + (remaining % nanoseconds_per_millisecond != 0 ? 1 : 0);

    return static_cast<std::uint32_t>(std::clamp<std::uint64_t>(milliseconds, 1, std::numeric_limits<std::uint32_t>::max()));
  }

  [[nodiscard]] bool trimDue(std::uint64_t now_ns) const noexcept {
    return std::ranges::any_of(rows(), [&](Row row) {
      const auto deadline = expiry(states_[row]);
      return deadline && *deadline <= now_ns;
    });
  }

  [[nodiscard]] std::size_t residentBytes() const noexcept {
    return resident_bytes_;
  }

  [[nodiscard]] std::size_t uploading() const noexcept {
    return uploading_;
  }

  [[nodiscard]] std::size_t uploadsStarted() const noexcept {
    return started_this_frame_;
  }

  [[nodiscard]] std::size_t spares() const noexcept {
    return spares_;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::uint64_t frame() const noexcept {
    return frame_;
  }

  [[nodiscard]] std::uint64_t presented() const noexcept {
    return presented_;
  }

  [[nodiscard]] std::span<const std::uint16_t> rows() const noexcept {
    return {occupied_.data(), count_};
  }

  [[nodiscard]] static constexpr ImageTextureHandle handleOf(std::size_t row) noexcept {
    return static_cast<ImageTextureHandle>(row + 1);
  }

private:
  using Row = std::uint16_t;

  template <typename IsRetained>
  void sweepRows(const IsRetained &is_retained) noexcept(noexcept(is_retained(Row{}))) {
    std::size_t index = 0;
    while (index < count_) {
      const auto row = occupied_[index];
      const auto &state = states_[row];
      if ((state.stage == ImageTextureStage::ready || state.stage == ImageTextureStage::failed) && state.used_frame != frame_ && !is_retained(row)) {
        retire(row);
        if (states_[row].stage == ImageTextureStage::free) {
          continue;
        }
      }

      ++index;
    }
  }

  [[nodiscard]] static bool validHandle(ImageTextureHandle handle) noexcept {
    return handle != 0 && handle <= capacity;
  }

  [[nodiscard]] ImageTextureState *findState(ImageTextureHandle handle) noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  [[nodiscard]] static std::size_t byteSize(ImageTextureSize size) noexcept {
    constexpr std::size_t rgba_channels = 4;
    return static_cast<std::size_t>(size.width) * size.height * rgba_channels;
  }

  [[nodiscard]] static std::optional<std::uint64_t> expiry(const ImageTextureState &state) noexcept {
    if (state.stage != ImageTextureStage::ready && state.stage != ImageTextureStage::spare) {
      return std::nullopt;
    }

    const auto lifetime = state.stage == ImageTextureStage::spare ? spare_lifetime_ns : idle_lifetime_ns;
    return state.used_ns + std::min(lifetime, std::numeric_limits<std::uint64_t>::max() - state.used_ns);
  }

  [[nodiscard]] std::size_t uploadsOf(ImageTextureIdentity identity) const noexcept {
    return uploading_ == 0 ? 0 : static_cast<std::size_t>(std::ranges::count_if(rows(), [&](Row row) {
      const auto &state = states_[row];
      return state.stage == ImageTextureStage::uploading && state.identity.sameImage(identity);
    }));
  }

  [[nodiscard]] std::optional<Row> takeRow(ImageTextureIdentity identity, ImageTextureSize size, std::size_t retained_bytes) noexcept {
    if (spares_ != 0) {
      for (const auto row : rows()) {
        if (states_[row].stage == ImageTextureStage::spare && states_[row].size == size) {
          --spares_;
          assign(row, identity);
          return row;
        }
      }
    }

    if (size.width <= maximum_side && size.height <= maximum_side && !reserve(byteSize(size), retained_bytes)) {
      return std::nullopt;
    }

    if (free_count_ == 0 && !evictOne()) {
      return std::nullopt;
    }

    const auto row = free_[--free_count_];
    position_[row] = static_cast<Row>(count_);
    occupied_[count_++] = row;
    assign(row, identity);
    states_[row].size = size;
    states_[row].bytes = 0;

    return row;
  }

  void assign(Row row, ImageTextureIdentity identity) noexcept {
    auto &state = states_[row];
    state.stage = ImageTextureStage::failed;
    state.identity = identity;
    state.used_frame = 0;
    state.presented = false;
  }

  [[nodiscard]] bool reserve(std::size_t bytes, std::size_t retained_bytes) noexcept {
    while (retained_bytes > byte_capacity || bytes > byte_capacity - retained_bytes || resident_bytes_ > byte_capacity - retained_bytes - bytes) {
      if (!evictOne()) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] bool evictOne() noexcept {
    std::optional<Row> oldest;
    for (const auto row : rows()) {
      const auto &state = states_[row];
      const bool evictable = state.stage == ImageTextureStage::spare || (state.stage == ImageTextureStage::ready && state.used_frame + 1 < frame_);
      if (evictable && (!oldest || state.used_ns < states_[*oldest].used_ns)) {
        oldest = row;
      }
    }

    if (!oldest) {
      return false;
    }

    discard(*oldest);
    return true;
  }

  void retire(Row row) noexcept {
    auto &state = states_[row];
    if (state.stage == ImageTextureStage::ready && spares_ < maximum_spares) {
      state.stage = ImageTextureStage::spare;
      ++spares_;
      state.used_ns = now_ns_;
      ++revision_;
    } else {
      discard(row);
    }
  }

  void discard(Row row) noexcept {
    resources_.release(handleOf(row));
    auto &state = states_[row];
    if (state.stage == ImageTextureStage::spare) {
      --spares_;
    }

    resident_bytes_ -= state.bytes;
    state.stage = ImageTextureStage::free;
    state.bytes = 0;
    const auto index = position_[row];
    const auto last = occupied_[--count_];
    occupied_[index] = last;
    position_[last] = index;
    free_[free_count_++] = row;
    ++revision_;
  }

  Resources &resources_;
  std::array<ImageTextureState, capacity> states_{};
  std::array<Row, capacity> occupied_{};
  std::array<Row, capacity> position_{};
  std::array<Row, capacity> free_{};
  std::size_t count_ = 0;
  std::size_t free_count_ = capacity;
  std::size_t resident_bytes_ = 0;
  std::size_t uploading_ = 0;
  std::size_t started_this_frame_ = 0;
  std::size_t spares_ = 0;
  std::uint64_t now_ns_ = 0;
  std::uint64_t frame_ = 0;
  std::uint64_t revision_ = 1;
  std::uint64_t presented_ = 0;
};

}
