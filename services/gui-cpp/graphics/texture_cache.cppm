module;
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstddef>

#include <cstdint>




#include <cmath>

export module telar.gui.graphics.texture_cache;

import std;

export import telar.gui.core.metrics;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.config;
import telar.gui.core.primitives;

// Interface: graphics/image_draw_budget.cppm
export {
namespace telar::gui {

class ImageDrawBudget {
public:
  static constexpr std::size_t capacity = 2048;

  [[nodiscard]] inline bool take() noexcept {
    if (used_ == capacity) {
      return false;
    }

    ++used_;
    return true;
  }

  [[nodiscard]] inline std::size_t used() const noexcept {
    return used_;
  }

private:
  std::size_t used_ = 0;
};

}
}

// Interface: graphics/lifetime.cppm
export {
namespace telar::gui {

struct GraphicsLifetime {
  std::uint64_t value = 0;

  [[nodiscard]] inline static GraphicsLifetime next() noexcept {
    static std::atomic<std::uint64_t> next_value{1};
    auto candidate = next_value.load(std::memory_order_relaxed);
    while (candidate != std::numeric_limits<std::uint64_t>::max()) {
      if (next_value.compare_exchange_weak(candidate, candidate + 1, std::memory_order_relaxed)) {
        return {.value = candidate};
      }
    }

    return {};
  }

  [[nodiscard]] inline bool cacheable() const noexcept {
    return value != 0;
  }

  bool operator==(const GraphicsLifetime &) const noexcept = default;
};

}
}

// Interface: graphics/image_residency.cppm
export {
namespace telar::gui {

using ImageTextureHandle = std::uint32_t;
inline constexpr std::size_t image_texture_capacity = 512;

struct ImageTextureIdentity {
  GraphicsLifetime catalog;
  std::uint32_t image_id = 0;
  std::uint64_t generation = 0;

  bool operator==(const ImageTextureIdentity &) const noexcept = default;

  [[nodiscard]] inline bool sameImage(const ImageTextureIdentity &other) const noexcept {
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

  inline explicit ImageResidency(Resources &resources) noexcept
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

  inline void beginFrame(std::uint64_t now_ns) noexcept {
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

  [[nodiscard]] inline ImageAdmission request(ImageTextureRequest request) noexcept {
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

  inline bool complete(ImageTextureHandle handle, bool success, std::uint64_t now_ns) noexcept {
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

  inline void abandon() noexcept {
    for (const auto row : rows()) {
      auto &state = states_[row];
      if (state.stage == ImageTextureStage::uploading) {
        state.stage = ImageTextureStage::failed;
        --uploading_;
      }
    }
  }

  inline void clear() noexcept {
    abandon();
    while (count_ != 0) {
      discard(occupied_[0]);
    }
  }

  inline void markNeeded(ImageTextureHandle handle) noexcept {
    if (auto *state = findState(handle)) {
      state->used_frame = frame_;
      state->used_ns = now_ns_;
    }
  }

  inline void keepWarm(ImageTextureUse use) noexcept {
    if (auto *state = findState(use.handle); state != nullptr && state->stage == ImageTextureStage::ready) {
      state->used_ns = use.now_ns;
    }
  }

  inline void noteDrawn(ImageTextureHandle handle) noexcept {
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

  inline void sweep(std::span<const bool, capacity> retained) noexcept {
    sweepRows([retained](std::uint16_t row) noexcept {
      return retained[row];
    });
  }

  [[nodiscard]] inline ImageTextureHandle find(ImageTextureIdentity identity) const noexcept {
    for (const auto row : rows()) {
      const auto &state = states_[row];
      if (state.stage != ImageTextureStage::spare && state.identity == identity) {
        return handleOf(row);
      }
    }

    return 0;
  }

  [[nodiscard]] inline ImageTextureHandle newestReady(ImageTextureIdentity identity) const noexcept {
    std::optional<Row> best;
    for (const auto row : rows()) {
      const auto &state = states_[row];
      if (state.stage == ImageTextureStage::ready && state.identity.sameImage(identity) && (!best || states_[*best].identity.generation < state.identity.generation)) {
        best = row;
      }
    }

    return best ? handleOf(*best) : 0;
  }

  [[nodiscard]] inline const ImageTextureState *state(ImageTextureHandle handle) const noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  [[nodiscard]] inline std::uint32_t wakeupAfter(std::uint64_t now_ns) const noexcept {
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

  [[nodiscard]] inline bool trimDue(std::uint64_t now_ns) const noexcept {
    return std::ranges::any_of(rows(), [&](Row row) {
      const auto deadline = expiry(states_[row]);
      return deadline && *deadline <= now_ns;
    });
  }

  [[nodiscard]] inline std::size_t residentBytes() const noexcept {
    return resident_bytes_;
  }

  [[nodiscard]] inline std::size_t uploading() const noexcept {
    return uploading_;
  }

  [[nodiscard]] inline std::size_t uploadsStarted() const noexcept {
    return started_this_frame_;
  }

  [[nodiscard]] inline std::size_t spares() const noexcept {
    return spares_;
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::uint64_t frame() const noexcept {
    return frame_;
  }

  [[nodiscard]] inline std::uint64_t presented() const noexcept {
    return presented_;
  }

  [[nodiscard]] inline std::span<const std::uint16_t> rows() const noexcept {
    return {occupied_.data(), count_};
  }

  [[nodiscard]] static constexpr ImageTextureHandle handleOf(std::size_t row) noexcept {
    return static_cast<ImageTextureHandle>(row + 1);
  }

private:
  using Row = std::uint16_t;

  template <typename IsRetained>
  inline void sweepRows(const IsRetained &is_retained) noexcept(noexcept(is_retained(Row{}))) {
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

  [[nodiscard]] inline static bool validHandle(ImageTextureHandle handle) noexcept {
    return handle != 0 && handle <= capacity;
  }

  [[nodiscard]] inline ImageTextureState *findState(ImageTextureHandle handle) noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  [[nodiscard]] inline static std::size_t byteSize(ImageTextureSize size) noexcept {
    constexpr std::size_t rgba_channels = 4;
    return static_cast<std::size_t>(size.width) * size.height * rgba_channels;
  }

  [[nodiscard]] inline static std::optional<std::uint64_t> expiry(const ImageTextureState &state) noexcept {
    if (state.stage != ImageTextureStage::ready && state.stage != ImageTextureStage::spare) {
      return std::nullopt;
    }

    const auto lifetime = state.stage == ImageTextureStage::spare ? spare_lifetime_ns : idle_lifetime_ns;
    return state.used_ns + std::min(lifetime, std::numeric_limits<std::uint64_t>::max() - state.used_ns);
  }

  [[nodiscard]] inline std::size_t uploadsOf(ImageTextureIdentity identity) const noexcept {
    return uploading_ == 0 ? 0 : static_cast<std::size_t>(std::ranges::count_if(rows(), [&](Row row) {
      const auto &state = states_[row];
      return state.stage == ImageTextureStage::uploading && state.identity.sameImage(identity);
    }));
  }

  [[nodiscard]] inline std::optional<Row> takeRow(ImageTextureIdentity identity, ImageTextureSize size, std::size_t retained_bytes) noexcept {
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

  inline void assign(Row row, ImageTextureIdentity identity) noexcept {
    auto &state = states_[row];
    state.stage = ImageTextureStage::failed;
    state.identity = identity;
    state.used_frame = 0;
    state.presented = false;
  }

  [[nodiscard]] inline bool reserve(std::size_t bytes, std::size_t retained_bytes) noexcept {
    while (retained_bytes > byte_capacity || bytes > byte_capacity - retained_bytes || resident_bytes_ > byte_capacity - retained_bytes - bytes) {
      if (!evictOne()) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] inline bool evictOne() noexcept {
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

  inline void retire(Row row) noexcept {
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

  inline void discard(Row row) noexcept {
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
}

// Interface: graphics/limit.cppm
export {
namespace telar::gui {

enum class GraphicsLimitKind : std::uint8_t {
  images,
  placements,
  chunks,
  bytes,
};

class GraphicsLimitError final : public std::exception {
public:
  inline explicit GraphicsLimitError(GraphicsLimitKind kind)
      : kind_(kind) {}

  [[nodiscard]] inline const char *what() const noexcept override {
    return name(kind_);
  }

  [[nodiscard]] inline GraphicsLimitKind kind() const noexcept {
    return kind_;
  }

  [[nodiscard]] inline static const char *name(GraphicsLimitKind kind) noexcept {
    switch (kind) {
    case GraphicsLimitKind::images:
      return "GraphicsImageLimitExceeded";
    case GraphicsLimitKind::placements:
      return "GraphicsPlacementLimitExceeded";
    case GraphicsLimitKind::chunks:
      return "GraphicsChunkLimitExceeded";
    case GraphicsLimitKind::bytes:
      return "GraphicsQuotaExceeded";
    }

    return "GraphicsQuotaExceeded";
  }

private:
  GraphicsLimitKind kind_;
};

}
}

// Interface: graphics/placement_selection.cppm
export {
namespace telar::gui {

class ImagePlacementSelection {
public:
  static constexpr std::size_t capacity = ImageDrawBudget::capacity;
  static constexpr std::string_view limit_name = "gui.images.placements_per_frame";
  static constexpr std::string_view limit_noun = "image placements";

  enum class Layer : std::uint8_t {
    below_background,
    below_text,
    above_text,
  };

  struct Identity {
    GraphicsLifetime catalog;
    std::uint64_t virtual_id = 0;
    std::uint32_t image_id = 0;

    bool operator==(const Identity &) const noexcept = default;
  };

  struct Candidate {
    Identity identity;
    Layer layer = Layer::above_text;
    std::int32_t z_index = 0;
  };

  inline void begin() noexcept {
    candidate_count_ = 0;
    dropped_ = 0;
  }

  inline void keep(Candidate candidate) noexcept {
    if (candidate_count_ < capacity) {
      candidates_[candidate_count_] = candidate;
      siftUp(candidate_count_++);
      return;
    }

    ++dropped_;
    if (paintsBelow(candidates_.front(), candidate)) {
      candidates_.front() = candidate;
      siftDown();
    }
  }

  [[nodiscard]] inline bool finish() noexcept {
    const auto candidates = std::span{candidates_}.first(candidate_count_);
    std::ranges::sort(candidates, {}, [](const Candidate &candidate) {
      return identityKey(candidate.identity);
    });
    const auto previous = std::span{selected_}.first(selected_count_);
    const bool changed = !std::ranges::equal(candidates, previous, {}, &Candidate::identity);
    if (!changed) {
      return false;
    }

    selected_count_ = candidate_count_;
    image_count_ = candidate_count_;
    for (std::size_t index = 0; index < selected_count_; ++index) {
      selected_[index] = candidates_[index].identity;
      images_[index] = imageKey(selected_[index]);
    }

    const auto images = std::span{images_}.first(image_count_);
    std::ranges::sort(images);
    image_count_ = static_cast<std::size_t>(std::ranges::unique(images).begin() - images.begin());
    ++revision_;

    return true;
  }

  [[nodiscard]] inline bool contains(GraphicsLifetime catalog, std::uint64_t virtual_id) const noexcept {
    const auto selected = std::span{selected_}.first(selected_count_);
    return std::ranges::binary_search(selected, std::tuple{catalog.value, virtual_id}, {}, [](const Identity &identity) {
      return identityKey(identity);
    });
  }

  [[nodiscard]] inline bool containsImage(GraphicsLifetime catalog, std::uint32_t image_id) const noexcept {
    return std::ranges::binary_search(std::span{images_}.first(image_count_), ImageIdentity{catalog.value, image_id});
  }

  [[nodiscard]] inline std::span<const Identity> selected() const noexcept {
    return std::span{selected_}.first(selected_count_);
  }

  [[nodiscard]] inline std::size_t dropped() const noexcept {
    return dropped_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline static Layer layer(const GraphicsPlacement &placement) noexcept {
    if (placement.location == PlacementLocation::placeholders) {
      return Layer::below_text;
    }

    constexpr auto below_background_limit = std::numeric_limits<std::int32_t>::min() / 2;
    if (placement.z_index < below_background_limit) {
      return Layer::below_background;
    }

    return placement.z_index < 0 ? Layer::below_text : Layer::above_text;
  }

private:
  using ImageIdentity = std::tuple<std::uint64_t, std::uint32_t>;
  static constexpr std::size_t heap_children = 2;

  [[nodiscard]] inline static std::tuple<std::uint64_t, std::uint64_t> identityKey(const Identity &identity) noexcept {
    return {identity.catalog.value, identity.virtual_id};
  }

  [[nodiscard]] inline static ImageIdentity imageKey(const Identity &identity) noexcept {
    return {identity.catalog.value, identity.image_id};
  }

  [[nodiscard]] inline static bool paintsBelow(const Candidate &left, const Candidate &right) noexcept {
    return std::tuple{left.layer, left.z_index} < std::tuple{right.layer, right.z_index};
  }

  inline void siftUp(std::size_t index) noexcept {
    while (index > 0) {
      const auto parent = (index - 1) / heap_children;
      if (!paintsBelow(candidates_[index], candidates_[parent])) {
        return;
      }

      std::swap(candidates_[index], candidates_[parent]);
      index = parent;
    }
  }

  inline void siftDown() noexcept {
    std::size_t index = 0;
    while (true) {
      auto lowest = index;
      const auto left = (heap_children * index) + 1;
      const auto right = left + 1;
      if (left < candidate_count_ && paintsBelow(candidates_[left], candidates_[lowest])) {
        lowest = left;
      }

      if (right < candidate_count_ && paintsBelow(candidates_[right], candidates_[lowest])) {
        lowest = right;
      }

      if (lowest == index) {
        return;
      }

      std::swap(candidates_[index], candidates_[lowest]);
      index = lowest;
    }
  }

  std::array<Candidate, capacity> candidates_{};
  std::array<Identity, capacity> selected_{};
  std::array<ImageIdentity, capacity> images_{};
  std::size_t candidate_count_ = 0;
  std::size_t selected_count_ = 0;
  std::size_t image_count_ = 0;
  std::size_t dropped_ = 0;
  std::uint64_t revision_ = 0;
};

}
}

// Interface: graphics/resync_required.cppm
export {
namespace telar::gui {

class GraphicsResyncRequired final : public std::exception {
public:
  [[nodiscard]] inline const char *what() const noexcept override {
    return "GraphicsResyncRequired";
  }
};

}
}

// Interface: graphics/store.cppm
export {
namespace telar::gui {

struct GraphicsBudget {
  static constexpr std::size_t global_capacity = runtime::GraphicsLimits::maximum_global_bytes;
  std::size_t used = 0;
};

template <Allocator Memory>
class GraphicsStore {
public:
  static constexpr std::size_t image_capacity = 64;
  static constexpr std::size_t placement_capacity = 256;
  static constexpr std::size_t byte_capacity = runtime::GraphicsLimits::maximum_pane_bytes;
  static constexpr std::size_t chunk_capacity = runtime::GraphicsLimits::maximum_chunks_per_image;

  class Image {
  public:
    inline Image(Memory &memory, ImageDescription description)
        : description_(description),
          allocator_(memory),
          pixels_(allocator_.allocate(static_cast<std::size_t>(description_.byte_len))) {
    }

    inline ~Image() {
      allocator_.deallocate(pixels_, static_cast<std::size_t>(description_.byte_len));
    }

    Image(const Image &) = delete;
    Image &operator=(const Image &) = delete;
    Image(Image &&) = delete;
    Image &operator=(Image &&) = delete;

    inline void append(std::uint64_t offset, std::span<const Byte> bytes) {
      if (offset != received_) {
        throw EncodingError{"Invalid graphics image chunk"};
      }

      if (chunks_ == chunk_capacity) {
        throw GraphicsLimitError{GraphicsLimitKind::chunks};
      }

      if (bytes.size() > description_.byte_len - received_) {
        throw EncodingError{"Invalid graphics image chunk length"};
      }

      std::ranges::copy(bytes, pixels_ + received_);
      received_ += bytes.size();
      ++chunks_;
    }

    template <typename Source>
    inline bool readShared(Source &source) {
      if (received_ != 0 || chunks_ != 0) {
        throw EncodingError{"Shared image already received pixels"};
      }

      if (!source.read(std::span<Byte>{pixels_, static_cast<std::size_t>(description_.byte_len)})) {
        return false;
      }

      received_ = description_.byte_len;
      return true;
    }

    [[nodiscard]] inline bool ready() const noexcept {
      return received_ == description_.byte_len;
    }

    [[nodiscard]] inline std::span<const Byte> receivedPixels() const noexcept {
      return {pixels_, received_};
    }

    [[nodiscard]] inline std::span<const Byte> pixels() const noexcept {
      return ready() ? std::span<const Byte>{pixels_, received_} : std::span<const Byte>{};
    }

    [[nodiscard]] inline const ImageDescription &description() const noexcept {
      return description_;
    }

    inline void retire() noexcept {
      retired_ = true;
    }

    [[nodiscard]] inline bool retired() const noexcept {
      return retired_;
    }

  private:
    ImageDescription description_;
    AllocatorRef<Byte, Memory> allocator_;
    Byte *pixels_ = nullptr;
    std::size_t received_ = 0;
    std::size_t chunks_ = 0;
    bool retired_ = false;
  };

  inline GraphicsStore(Memory &memory, GraphicsBudget &budget)
      : memory_(memory),
        budget_(budget),
        images_(AllocatorRef<Owned<Image, Memory>, Memory>{memory}),
        placements_(AllocatorRef<GraphicsPlacement, Memory>{memory}) {}

  inline ~GraphicsStore() {
    budget_.used -= bytes_;
  }

  GraphicsStore(const GraphicsStore &) = delete;
  GraphicsStore &operator=(const GraphicsStore &) = delete;
  GraphicsStore(GraphicsStore &&) = delete;
  GraphicsStore &operator=(GraphicsStore &&) = delete;

  inline bool snapshot(const GraphicsSnapshot &message) {
    if (message.phase == SnapshotPhase::begin) {
      clear();
      snapshot_revision_ = message.header.revision;
      latest_revision_ = message.header.revision;
      awaiting_snapshot_ = false;
      ++revision_;

      return true;
    }

    if (awaiting_snapshot_) {
      return false;
    }

    if (!snapshot_revision_ || *snapshot_revision_ != message.header.revision) {
      requireSnapshot();

      throw GraphicsResyncRequired{};
    }

    for (std::size_t index = images_.size(); index-- > 0;) {
      if (!images_[index]->ready()) {
        const auto key = images_[index]->description().key;
        std::erase_if(placements_, [&](const auto &placement) {
          return sameKey(placement.key, key);
        });
        eraseImage(index);
      }
    }

    snapshot_revision_.reset();
    ++revision_;

    return true;
  }

  inline bool image(const GraphicsImage &message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    const auto &description = message.image;
    const bool valid_format = description.format == ImageFormat::rgb || description.format == ImageFormat::rgba;
    if (description.key.image_id == 0 || description.key.generation == 0 || description.width == 0 || description.height == 0 || !valid_format) {
      throw EncodingError{"Invalid graphics image description"};
    }

    BodySchema<ImageDescription>::validate(description);
    retireOtherGenerations(message.image.key);

    const auto previous = findImage(message.image.key);
    const auto previous_bytes = previous == nullptr ? 0 : previous->description().byte_len;
    const auto requested = message.image.byte_len;
    if (!containsImageId(message.image.key.image_id) && logicalImageCount() == image_capacity) {
      reached(GraphicsLimitKind::images);
    }

    if (requested > byte_capacity - (bytes_ - previous_bytes) || requested > GraphicsBudget::global_capacity - (budget_.used - previous_bytes)) {
      reached(GraphicsLimitKind::bytes);
    }

    if (previous != nullptr) {
      for (std::size_t index = 0; index < images_.size(); ++index) {
        if (images_[index].get() == previous) {
          eraseImage(index);

          break;
        }
      }
    }

    auto replacement = makeOwned<Image>(memory_, memory_, message.image);
    images_.push_back(std::move(replacement));
    bytes_ += requested;
    budget_.used += requested;

    return false;
  }

  inline bool chunk(const GraphicsImageChunk &message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    auto *image = findImage(message.key);
    if (image == nullptr) {
      throw EncodingError{"Unknown graphics image"};
    }

    try {
      image->append(message.offset, message.bytes);
    } catch (const GraphicsLimitError &) {
      requireSnapshot();

      throw;
    }
    if (image->ready()) {
      retireOtherGenerations(message.key);
      ++revision_;

      return true;
    }

    return false;
  }

  template <typename Source>
  inline bool sharedImage(const GraphicsSharedImage &message, Source &source) {
    if (!accept(message.header.revision)) {
      return false;
    }

    image(GraphicsImage{.header = message.header, .image = message.image});
    auto *received = findImage(message.image.key);
    if (received == nullptr || !received->readShared(source)) {
      requireSnapshot();

      throw GraphicsResyncRequired{};
    }

    retireOtherGenerations(message.image.key);
    ++revision_;
    return true;
  }

  inline bool placement(const GraphicsPlacementMessage &message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    const auto &placement = message.placement;
    validatePlacement(placement);
    const auto found = std::find_if(placements_.begin(), placements_.end(), [&](const auto &entry) {
      return entry.virtual_id == placement.virtual_id;
    });
    if (found != placements_.end()) {
      *found = placement;
    } else {
      if (placements_.size() == placement_capacity) {
        reached(GraphicsLimitKind::placements);
      }

      placements_.push_back(placement);
    }

    ++revision_;

    return true;
  }

  inline bool erase(const GraphicsDeleteImage &message) {
    if (!awaiting_snapshot_ && !accept(message.header.revision)) {
      return false;
    }

    auto *image = findImage(message.key);
    if (image == nullptr) {
      return false;
    }

    image->retire();
    std::erase_if(placements_, [&](const auto &placement) {
      return sameKey(placement.key, message.key);
    });
    collectRetired(message.key.image_id);
    ++revision_;

    return true;
  }

  inline bool erase(const GraphicsDeletePlacement &message) {
    if (!awaiting_snapshot_ && !accept(message.header.revision)) {
      return false;
    }

    const auto removed = std::erase_if(placements_, [&](const auto &placement) {
      return placement.virtual_id == message.virtual_id;
    });
    if (removed == 0) {
      return false;
    }

    collectRetired(message.key.image_id);
    ++revision_;

    return true;
  }

  [[nodiscard]] inline Image *findImage(ImageKey key) const noexcept {
    const auto found = std::find_if(images_.begin(), images_.end(), [&](const auto &image) {
      return sameKey(image->description().key, key);
    });

    return found == images_.end() ? nullptr : found->get();
  }

  [[nodiscard]] inline const Image *readyImage(ImageKey key) const noexcept {
    if (const auto *image = findImage(key); image != nullptr && image->ready() && !image->retired()) {
      return image;
    }

    const Image *latest = nullptr;
    for (const auto &image : images_) {
      if (image->description().key.image_id == key.image_id && image->ready() && !image->retired() && (latest == nullptr || image->description().key.generation > latest->description().key.generation)) {
        latest = image.get();
      }
    }

    return latest;
  }

  template <typename Visitor>
    requires std::invocable<const Visitor &, const Image &>
  void visitImages(const Visitor &visit) const {
    for (const auto &image : images_) {
      visit(*image);
    }
  }

  [[nodiscard]] inline std::span<const GraphicsPlacement> placements() const noexcept {
    return placements_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline GraphicsLifetime lifetime() const noexcept {
    return lifetime_;
  }

  [[nodiscard]] inline std::size_t globalRetainedBytes() const noexcept {
    return budget_.used;
  }

  inline std::uint64_t takeCredit() noexcept {
    return std::exchange(released_bytes_, 0);
  }

  inline void detach() noexcept {
    clear();
    released_bytes_ = 0;
    latest_revision_ = 0;
    snapshot_revision_.reset();
    awaiting_snapshot_ = false;
    lifetime_ = GraphicsLifetime::next();
    ++revision_;
  }

private:
  inline void retireOtherGenerations(ImageKey current) noexcept {
    for (auto &image : images_) {
      const auto key = image->description().key;
      if (key.image_id == current.image_id && key.generation != current.generation) {
        image->retire();
      }
    }

    collectRetired(current.image_id);
  }

  inline void collectRetired(std::uint32_t image_id) noexcept {
    for (auto index = images_.size(); index-- > 0;) {
      const auto &image = *images_[index];
      const auto key = image.description().key;
      if (key.image_id == image_id && image.retired() && !hasPlacementReference(key)) {
        eraseImage(index);
      }
    }
  }

  inline void requireSnapshot() noexcept {
    awaiting_snapshot_ = true;
    snapshot_revision_.reset();
  }

  [[noreturn]] inline void reached(GraphicsLimitKind kind) {
    requireSnapshot();

    throw GraphicsLimitError{kind};
  }

  [[nodiscard]] inline bool containsImageId(std::uint32_t id) const noexcept {
    return std::ranges::any_of(images_, [id](const auto &image) {
      return image->description().key.image_id == id;
    });
  }

  [[nodiscard]] inline std::size_t logicalImageCount() const noexcept {
    std::array<std::uint32_t, image_capacity> identifiers{};
    std::size_t count = 0;
    for (const auto &image : images_) {
      const auto id = image->description().key.image_id;
      const auto known = std::span{identifiers}.first(count);
      if (std::ranges::find(known, id) == known.end()) {
        identifiers[count++] = id;
      }
    }

    return count;
  }

  [[nodiscard]] inline bool hasPlacementReference(ImageKey key) const noexcept {
    return std::ranges::any_of(placements_, [key](const auto &placement) {
      return sameKey(placement.key, key);
    });
  }

  inline void validatePlacement(const GraphicsPlacement &placement) const {
    const auto *image = findImage(placement.key);
    if (image == nullptr || placement.virtual_id == 0) {
      throw EncodingError{"Invalid graphics placement image or identity"};
    }

    const auto &description = image->description();
    if (placement.source_x >= description.width || placement.source_y >= description.height || placement.source_width > description.width - placement.source_x || placement.source_height > description.height - placement.source_y) {
      throw EncodingError{"Invalid graphics source rectangle"};
    }
  }

  inline static bool sameKey(ImageKey left, ImageKey right) noexcept {
    return left.image_id == right.image_id && left.generation == right.generation;
  }

  inline bool accept(std::uint64_t revision) {
    if (awaiting_snapshot_) {
      return false;
    }

    if (snapshot_revision_ && revision != *snapshot_revision_) {
      requireSnapshot();

      throw GraphicsResyncRequired{};
    }

    if (!snapshot_revision_ && revision < latest_revision_) {
      return false;
    }

    latest_revision_ = revision;

    return true;
  }

  inline void eraseImage(std::size_t index) noexcept {
    const auto released = images_[index]->description().byte_len;
    bytes_ -= released;
    budget_.used -= released;
    released_bytes_ += released;
    images_.erase(images_.begin() + index);
  }

  inline void clear() noexcept {
    budget_.used -= bytes_;
    released_bytes_ += bytes_;
    bytes_ = 0;
    images_.clear();
    placements_.clear();
  }

  Memory &memory_;
  GraphicsBudget &budget_;
  Vector<Owned<Image, Memory>, Memory> images_;
  Vector<GraphicsPlacement, Memory> placements_;
  std::size_t bytes_ = 0;
  std::uint64_t released_bytes_ = 0;
  std::uint64_t latest_revision_ = 0;
  std::uint64_t revision_ = 0;
  GraphicsLifetime lifetime_ = GraphicsLifetime::next();
  std::optional<std::uint64_t> snapshot_revision_;
  bool awaiting_snapshot_ = false;
};

}
}

// Interface: graphics/texture_cache.cppm
export {
namespace telar::gui {

template <typename Resource>
concept TextureResource = std::movable<Resource> && std::is_nothrow_default_constructible_v<Resource> && std::is_nothrow_move_assignable_v<Resource> && requires(const Resource &resource) {
  static_cast<bool>(resource);
};

template <TextureResource Resource, std::size_t Capacity>
class ImageTextureCache {
public:
  struct Entry {
    std::uint32_t image_id = 0;
    std::uint64_t generation = 0;
    Rect bounds;
    Resource resource{};
    std::optional<std::uint64_t> failed_generation = std::nullopt;
    bool needed = false;
    bool resolved_in_frame = false;
  };

  template <Allocator Memory>
  inline void beginFrame(const GraphicsStore<Memory> &store) noexcept {
    const auto lifetime = store.lifetime();
    if (!lifetime.cacheable() || store_lifetime_ != lifetime) {
      entries_ = {};
      store_lifetime_ = lifetime;
    }

    const auto placements = store.placements();
    for (auto &entry : entries_) {
      entry.resolved_in_frame = false;
      entry.needed = entry.image_id != 0 && std::ranges::any_of(placements, [&](const auto &placement) {
                       return placement.key.image_id == entry.image_id;
                     });
    }
  }

  template <Allocator Memory, typename Upload>
    requires std::same_as<std::invoke_result_t<const Upload &, const typename GraphicsStore<Memory>::Image &>, Resource>
  [[nodiscard]] const Entry *resolve(const GraphicsStore<Memory> &store, ImageKey key, const Upload &upload) {
    auto *entry = find(key.image_id);
    if (entry == nullptr) {
      const auto available = std::ranges::find_if(entries_, [](const auto &candidate) {
        return !candidate.needed;
      });
      if (available == entries_.end()) {
        return nullptr;
      }

      entry = available;
      *entry = {};
      entry->image_id = key.image_id;
      entry->needed = true;
    }

    if (entry->resolved_in_frame) {
      return entry->resource ? entry : nullptr;
    }

    entry->resolved_in_frame = true;
    const auto *image = store.readyImage(key);
    if (image != nullptr) {
      const auto &description = image->description();
      const bool newer = !entry->resource || description.key.generation > entry->generation;
      if (newer && entry->failed_generation != description.key.generation) {
        auto resource = upload(*image);
        if (resource) {
          entry->resource = std::move(resource);
          entry->generation = description.key.generation;
          entry->bounds = {.width = static_cast<float>(description.width), .height = static_cast<float>(description.height)};
          entry->failed_generation.reset();
        } else {
          entry->failed_generation = description.key.generation;
        }
      }
    }

    return entry->resource ? entry : nullptr;
  }

  inline void endFrame() noexcept {
    for (auto &entry : entries_) {
      if (!entry.needed) {
        entry = {};
      }
    }
  }

private:
  [[nodiscard]] inline Entry *find(std::uint32_t image_id) noexcept {
    const auto found = std::ranges::find_if(entries_, [image_id](const auto &entry) {
      return entry.image_id == image_id;
    });

    return found == entries_.end() ? nullptr : found;
  }

  std::array<Entry, Capacity> entries_{};
  GraphicsLifetime store_lifetime_;
};

}
}
