module telar.gui.features.terminal.graphics;

import std;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::graphics {

  bool ImageDrawBudget::take() noexcept {
    if (used_ == capacity) {
      return false;
    }

    ++used_;
    return true;
  }

  std::size_t ImageDrawBudget::used() const noexcept {
    return used_;
  }

  bool ImageTextureIdentity::sameImage(const ImageTextureIdentity& other) const noexcept {
    return catalog == other.catalog && image_id == other.image_id;
  }

  ImageResidencyTable::ImageResidencyTable(void* resources, Release release) noexcept
      : resources_(resources),
        release_(release) {
    for (std::size_t index = 0; index < capacity; ++index) {
      free_.atMut(index) = static_cast<Row>(capacity - 1 - index);
    }
  }

  void ImageResidencyTable::beginFrame(std::uint64_t now_ns) noexcept {
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

  ImageAdmission ImageResidencyTable::request(ImageTextureRequest request) noexcept {
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

    auto& state = states_.atMut(*row);

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

  bool ImageResidencyTable::complete(ImageTextureHandle handle, bool success, std::uint64_t now_ns) noexcept {
    auto* state = findState(handle);
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

  void ImageResidencyTable::abandon() noexcept {
    for (const auto row : rows()) {
      auto& state = states_.atMut(row);
      if (state.stage == ImageTextureStage::uploading) {
        state.stage = ImageTextureStage::failed;
        --uploading_;
      }
    }
  }

  void ImageResidencyTable::clear() noexcept {
    abandon();
    while (count_ != 0) {
      discard(occupied_[0]);
    }
  }

  void ImageResidencyTable::markNeeded(ImageTextureHandle handle) noexcept {
    if (auto* state = findState(handle)) {
      state->used_frame = frame_;
      state->used_ns = now_ns_;
    }
  }

  void ImageResidencyTable::keepWarm(ImageTextureUse use) noexcept {
    if (auto* state = findState(use.handle); state != nullptr && state->stage == ImageTextureStage::ready) {
      state->used_ns = use.now_ns;
    }
  }

  void ImageResidencyTable::noteDrawn(ImageTextureHandle handle) noexcept {
    auto* state = findState(handle);
    if (state == nullptr) {
      return;
    }

    markNeeded(handle);
    if (!state->presented) {
      state->presented = true;
      ++presented_;
    }
  }

  void ImageResidencyTable::sweep(std::span<const bool, capacity> retained) noexcept {
    sweepRows(&retained, [](const void* context, std::uint16_t row, ImageTextureIdentity) -> bool {
      return (*static_cast<const std::span<const bool, capacity>*>(context))[row];
    });
  }

  ImageTextureHandle ImageResidencyTable::find(ImageTextureIdentity identity) const noexcept {
    for (const auto row : rows()) {
      const auto& state = states_[row];
      if (state.stage != ImageTextureStage::spare && state.identity == identity) {
        return handleOf(row);
      }
    }

    return 0;
  }

  ImageTextureHandle ImageResidencyTable::newestReady(ImageTextureIdentity identity) const noexcept {
    ds::Option<Row> best;

    for (const auto row : rows()) {
      const auto& state = states_[row];
      if (state.stage == ImageTextureStage::ready && state.identity.sameImage(identity) && (!best || states_[*best].identity.generation < state.identity.generation)) {
        best = row;
      }
    }

    return best ? handleOf(*best) : 0;
  }

  const ImageTextureState* ImageResidencyTable::state(ImageTextureHandle handle) const noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  std::uint32_t ImageResidencyTable::wakeupAfter(std::uint64_t now_ns) const noexcept {
    ds::Option<std::uint64_t> earliest;

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

  std::size_t ImageResidencyTable::residentBytes() const noexcept {
    return resident_bytes_;
  }

  std::size_t ImageResidencyTable::uploading() const noexcept {
    return uploading_;
  }

  std::size_t ImageResidencyTable::uploadsStarted() const noexcept {
    return started_this_frame_;
  }

  std::size_t ImageResidencyTable::spares() const noexcept {
    return spares_;
  }

  std::size_t ImageResidencyTable::size() const noexcept {
    return count_;
  }

  std::uint64_t ImageResidencyTable::revision() const noexcept {
    return revision_;
  }

  std::uint64_t ImageResidencyTable::frame() const noexcept {
    return frame_;
  }

  std::uint64_t ImageResidencyTable::presented() const noexcept {
    return presented_;
  }

  std::span<const std::uint16_t> ImageResidencyTable::rows() const noexcept {
    return {occupied_.data(), count_};
  }

  void ImageResidencyTable::sweepRows(const void* context, Retained retained) {
    std::size_t index = 0;

    while (index < count_) {
      const auto row = occupied_[index];
      const auto& state = states_[row];
      if ((state.stage == ImageTextureStage::ready || state.stage == ImageTextureStage::failed) && state.used_frame != frame_ && !retained(context, row, state.identity)) {
        retire(row);
        if (states_[row].stage == ImageTextureStage::free) {
          continue;
        }
      }

      ++index;
    }
  }

  bool ImageResidencyTable::validHandle(ImageTextureHandle handle) noexcept {
    return handle != 0 && handle <= capacity;
  }

  ImageTextureState* ImageResidencyTable::findState(ImageTextureHandle handle) noexcept {
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_.atMut(handle - 1) : nullptr;
  }

  std::size_t ImageResidencyTable::byteSize(ImageTextureSize size) noexcept {
    constexpr std::size_t rgba_channels = 4;

    return static_cast<std::size_t>(size.width) * size.height * rgba_channels;
  }

  ds::Option<std::uint64_t> ImageResidencyTable::expiry(const ImageTextureState& state) noexcept {
    if (state.stage != ImageTextureStage::ready && state.stage != ImageTextureStage::spare) {
      return ds::none;
    }

    const auto lifetime = state.stage == ImageTextureStage::spare ? spare_lifetime_ns : idle_lifetime_ns;

    return state.used_ns + std::min(lifetime, std::numeric_limits<std::uint64_t>::max() - state.used_ns);
  }

  std::size_t ImageResidencyTable::uploadsOf(ImageTextureIdentity identity) const noexcept {
    return uploading_ == 0 ? 0 : static_cast<std::size_t>(std::ranges::count_if(rows(), [&](Row row) {
      const auto& state = states_[row];

      return state.stage == ImageTextureStage::uploading && state.identity.sameImage(identity);
    }));
  }

  ds::Option<ImageResidencyTable::Row> ImageResidencyTable::takeRow(ImageTextureIdentity identity, ImageTextureSize size, std::size_t retained_bytes) noexcept {
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
      return ds::none;
    }

    if (free_count_ == 0 && !evictOne()) {
      return ds::none;
    }

    const auto row = free_[--free_count_];

    position_.atMut(row) = static_cast<Row>(count_);
    occupied_.atMut(count_++) = row;
    assign(row, identity);
    states_.atMut(row).size = size;
    states_.atMut(row).bytes = 0;

    return row;
  }

  void ImageResidencyTable::assign(Row row, ImageTextureIdentity identity) noexcept {
    auto& state = states_.atMut(row);

    state.stage = ImageTextureStage::failed;
    state.identity = identity;
    state.used_frame = 0;
    state.presented = false;
  }

  bool ImageResidencyTable::reserve(std::size_t bytes, std::size_t retained_bytes) noexcept {
    while (retained_bytes > byte_capacity || bytes > byte_capacity - retained_bytes || resident_bytes_ > byte_capacity - retained_bytes - bytes) {
      if (!evictOne()) {
        return false;
      }
    }

    return true;
  }

  bool ImageResidencyTable::evictOne() noexcept {
    ds::Option<Row> oldest;

    for (const auto row : rows()) {
      const auto& state = states_[row];
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

  void ImageResidencyTable::retire(Row row) noexcept {
    auto& state = states_.atMut(row);
    if (state.stage == ImageTextureStage::ready && spares_ < maximum_spares) {
      state.stage = ImageTextureStage::spare;
      ++spares_;
      state.used_ns = now_ns_;
      ++revision_;
    } else {
      discard(row);
    }
  }

  void ImageResidencyTable::discard(Row row) noexcept {
    release_(resources_, handleOf(row));
    auto& state = states_.atMut(row);
    if (state.stage == ImageTextureStage::spare) {
      --spares_;
    }

    resident_bytes_ -= state.bytes;
    state.stage = ImageTextureStage::free;
    state.bytes = 0;
    const auto index = position_[row];
    const auto last = occupied_[--count_];

    occupied_.atMut(index) = last;
    position_.atMut(last) = index;
    free_.atMut(free_count_++) = row;
    ++revision_;
  }

  void ImagePlacementSelection::begin() noexcept {
    candidate_count_ = 0;
    dropped_ = 0;
  }

  void ImagePlacementSelection::keep(Candidate candidate) noexcept {
    if (candidate_count_ < capacity) {
      candidates_.atMut(candidate_count_) = candidate;
      siftUp(candidate_count_++);
      return;
    }

    ++dropped_;
    if (paintsBelow(candidates_.front(), candidate)) {
      candidates_.atMut(0) = candidate;
      siftDown();
    }
  }

  bool ImagePlacementSelection::finish() noexcept {
    const auto candidates = candidates_.viewMut().first(candidate_count_);

    std::ranges::sort(candidates, {}, [](const Candidate& candidate) {
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
      selected_.atMut(index) = candidates_[index].identity;
      images_.atMut(index) = imageKey(selected_[index]);
    }

    const auto images = images_.viewMut().first(image_count_);

    std::ranges::sort(images);
    image_count_ = static_cast<std::size_t>(std::ranges::unique(images).begin() - images.begin());
    ++revision_;

    return true;
  }

  bool ImagePlacementSelection::contains(GraphicsLifetime catalog, std::uint64_t virtual_id) const noexcept {
    const auto selected = std::span{selected_}.first(selected_count_);

    return std::ranges::binary_search(selected, std::tuple{catalog.value, virtual_id}, {}, [](const Identity& identity) {
      return identityKey(identity);
    });
  }

  bool ImagePlacementSelection::containsImage(GraphicsLifetime catalog, std::uint32_t image_id) const noexcept {
    return std::ranges::binary_search(std::span{images_}.first(image_count_), ImageIdentity{catalog.value, image_id});
  }

  std::span<const ImagePlacementSelection::Identity> ImagePlacementSelection::selected() const noexcept {
    return std::span{selected_}.first(selected_count_);
  }

  std::size_t ImagePlacementSelection::dropped() const noexcept {
    return dropped_;
  }

  std::uint64_t ImagePlacementSelection::revision() const noexcept {
    return revision_;
  }

  ImagePlacementSelection::Layer ImagePlacementSelection::layer(const GraphicsPlacement& placement) noexcept {
    if (placement.location == PlacementLocation::placeholders) {
      return Layer::below_text;
    }

    constexpr auto below_background_limit = std::numeric_limits<std::int32_t>::min() / 2;
    if (placement.z_index < below_background_limit) {
      return Layer::below_background;
    }

    return placement.z_index < 0 ? Layer::below_text : Layer::above_text;
  }

  std::tuple<std::uint64_t, std::uint64_t> ImagePlacementSelection::identityKey(const Identity& identity) noexcept {
    return {identity.catalog.value, identity.virtual_id};
  }

  ImagePlacementSelection::ImageIdentity ImagePlacementSelection::imageKey(const Identity& identity) noexcept {
    return {identity.catalog.value, identity.image_id};
  }

  bool ImagePlacementSelection::paintsBelow(const Candidate& left, const Candidate& right) noexcept {
    return std::tuple{left.layer, left.z_index} < std::tuple{right.layer, right.z_index};
  }

  void ImagePlacementSelection::siftUp(std::size_t index) noexcept {
    while (index > 0) {
      const auto parent = (index - 1) / heap_children;
      if (!paintsBelow(candidates_[index], candidates_[parent])) {
        return;
      }

      std::swap(candidates_.atMut(index), candidates_.atMut(parent));
      index = parent;
    }
  }

  void ImagePlacementSelection::siftDown() noexcept {
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

      std::swap(candidates_.atMut(index), candidates_.atMut(lowest));
      index = lowest;
    }
  }

}
