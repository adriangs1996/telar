module telar.gui.graphics.texture_cache;

import std;

import telar.base.memory.allocators;
import telar.wire.graphics;
import telar.wire.vocabulary;
import telar.gui.foundation.core;

namespace telar::gui {

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

  GraphicsLifetime GraphicsLifetime::next() noexcept {
    static std::atomic<std::uint64_t> next_value{1};
    auto candidate = next_value.load(std::memory_order_relaxed);

    while (candidate != std::numeric_limits<std::uint64_t>::max()) {
      if (next_value.compare_exchange_weak(candidate, candidate + 1, std::memory_order_relaxed)) {
        return {.value = candidate};
      }
    }

    return {};
  }

  bool GraphicsLifetime::cacheable() const noexcept {
    return value != 0;
  }

  bool ImageTextureIdentity::sameImage(const ImageTextureIdentity& other) const noexcept {
    return catalog == other.catalog && image_id == other.image_id;
  }

  ImageResidencyTable::ImageResidencyTable(void* resources, Release release) noexcept
      : resources_(resources),
        release_(release) {
    for (std::size_t index = 0; index < capacity; ++index) {
      free_[index] = static_cast<Row>(capacity - 1 - index);
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

    auto& state = states_[*row];

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
      auto& state = states_[row];
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
    std::optional<Row> best;

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
    return validHandle(handle) && states_[handle - 1].stage != ImageTextureStage::free ? &states_[handle - 1] : nullptr;
  }

  std::size_t ImageResidencyTable::byteSize(ImageTextureSize size) noexcept {
    constexpr std::size_t rgba_channels = 4;

    return static_cast<std::size_t>(size.width) * size.height * rgba_channels;
  }

  std::optional<std::uint64_t> ImageResidencyTable::expiry(const ImageTextureState& state) noexcept {
    if (state.stage != ImageTextureStage::ready && state.stage != ImageTextureStage::spare) {
      return std::nullopt;
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

  std::optional<ImageResidencyTable::Row> ImageResidencyTable::takeRow(ImageTextureIdentity identity, ImageTextureSize size, std::size_t retained_bytes) noexcept {
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

  void ImageResidencyTable::assign(Row row, ImageTextureIdentity identity) noexcept {
    auto& state = states_[row];

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
    std::optional<Row> oldest;

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
    auto& state = states_[row];
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
    auto& state = states_[row];
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

  GraphicsLimitError::GraphicsLimitError(GraphicsLimitKind kind)
      : kind_(kind) {}

  const char* GraphicsLimitError::what() const noexcept {
    return name(kind_);
  }

  GraphicsLimitKind GraphicsLimitError::kind() const noexcept {
    return kind_;
  }

  const char* GraphicsLimitError::name(GraphicsLimitKind kind) noexcept {
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

  void ImagePlacementSelection::begin() noexcept {
    candidate_count_ = 0;
    dropped_ = 0;
  }

  void ImagePlacementSelection::keep(Candidate candidate) noexcept {
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

  bool ImagePlacementSelection::finish() noexcept {
    const auto candidates = std::span{candidates_}.first(candidate_count_);

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
      selected_[index] = candidates_[index].identity;
      images_[index] = imageKey(selected_[index]);
    }

    const auto images = std::span{images_}.first(image_count_);

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

      std::swap(candidates_[index], candidates_[parent]);
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

      std::swap(candidates_[index], candidates_[lowest]);
      index = lowest;
    }
  }

  const char* GraphicsResyncRequired::what() const noexcept {
    return "GraphicsResyncRequired";
  }

  template <Allocator Memory>
  GraphicsStore<Memory>::Image::Image(Memory& memory, ImageDescription description)
      : description_(description),
        allocator_(memory),
        pixels_(allocator_.allocate(static_cast<std::size_t>(description_.byte_len))) {
  }

  template <Allocator Memory>
  GraphicsStore<Memory>::Image::~Image() {
    allocator_.deallocate(pixels_, static_cast<std::size_t>(description_.byte_len));
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::Image::append(std::uint64_t offset, std::span<const Byte> bytes) {
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

  template <Allocator Memory>
  bool GraphicsStore<Memory>::Image::ready() const noexcept {
    return received_ == description_.byte_len;
  }

  template <Allocator Memory>
  std::span<const Byte> GraphicsStore<Memory>::Image::pixels() const noexcept {
    return ready() ? std::span<const Byte>{pixels_, received_} : std::span<const Byte>{};
  }

  template <Allocator Memory>
  const ImageDescription& GraphicsStore<Memory>::Image::description() const noexcept {
    return description_;
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::Image::retire() noexcept {
    retired_ = true;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::Image::retired() const noexcept {
    return retired_;
  }

  template <Allocator Memory>
  GraphicsStore<Memory>::GraphicsStore(Memory& memory, GraphicsBudget& budget)
      : memory_(memory),
        budget_(budget),
        images_(AllocatorRef<Owned<Image, Memory>, Memory>{memory}),
        placements_(AllocatorRef<GraphicsPlacement, Memory>{memory}) {}

  template <Allocator Memory>
  GraphicsStore<Memory>::~GraphicsStore() {
    budget_.used -= bytes_;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::snapshot(const GraphicsSnapshot& message) {
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

        std::erase_if(placements_, [&](const auto& placement) {
          return sameKey(placement.key, key);
        });

        eraseImage(index);
      }
    }

    snapshot_revision_.reset();
    ++revision_;

    return true;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::image(const GraphicsImage& message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    const auto& description = message.image;
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

  template <Allocator Memory>
  bool GraphicsStore<Memory>::chunk(const GraphicsImageChunk& message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    auto* image = findImage(message.key);
    if (image == nullptr) {
      throw EncodingError{"Unknown graphics image"};
    }

    try {
      image->append(message.offset, message.bytes);
    } catch (const GraphicsLimitError&) {
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

  template <Allocator Memory>
  bool GraphicsStore<Memory>::placement(const GraphicsPlacementMessage& message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    const auto& placement = message.placement;

    validatePlacement(placement);
    const auto found = std::find_if(placements_.begin(), placements_.end(), [&](const auto& entry) {
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

  template <Allocator Memory>
  bool GraphicsStore<Memory>::erase(const GraphicsDeleteImage& message) {
    if (!awaiting_snapshot_ && !accept(message.header.revision)) {
      return false;
    }

    auto* image = findImage(message.key);
    if (image == nullptr) {
      return false;
    }

    image->retire();
    std::erase_if(placements_, [&](const auto& placement) {
      return sameKey(placement.key, message.key);
    });

    collectRetired(message.key.image_id);
    ++revision_;

    return true;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::erase(const GraphicsDeletePlacement& message) {
    if (!awaiting_snapshot_ && !accept(message.header.revision)) {
      return false;
    }

    const auto removed = std::erase_if(placements_, [&](const auto& placement) {
      return placement.virtual_id == message.virtual_id;
    });
    if (removed == 0) {
      return false;
    }

    collectRetired(message.key.image_id);
    ++revision_;

    return true;
  }

  template <Allocator Memory>
  auto GraphicsStore<Memory>::findImage(ImageKey key) const noexcept -> Image* {
    const auto found = std::find_if(images_.begin(), images_.end(), [&](const auto& image) {
      return sameKey(image->description().key, key);
    });

    return found == images_.end() ? nullptr : found->get();
  }

  template <Allocator Memory>
  auto GraphicsStore<Memory>::readyImage(ImageKey key) const noexcept -> const Image* {
    if (const auto* image = findImage(key); image != nullptr && image->ready() && !image->retired()) {
      return image;
    }

    const Image* latest = nullptr;

    for (const auto& image : images_) {
      if (image->description().key.image_id == key.image_id && image->ready() && !image->retired() && (latest == nullptr || image->description().key.generation > latest->description().key.generation)) {
        latest = image.get();
      }
    }

    return latest;
  }

  template <Allocator Memory>
  std::span<const GraphicsPlacement> GraphicsStore<Memory>::placements() const noexcept {
    return placements_;
  }

  template <Allocator Memory>
  std::uint64_t GraphicsStore<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  GraphicsLifetime GraphicsStore<Memory>::lifetime() const noexcept {
    return lifetime_;
  }

  template <Allocator Memory>
  std::size_t GraphicsStore<Memory>::globalRetainedBytes() const noexcept {
    return budget_.used;
  }

  template <Allocator Memory>
  std::uint64_t GraphicsStore<Memory>::takeCredit() noexcept {
    return std::exchange(released_bytes_, 0);
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::detach() noexcept {
    clear();
    released_bytes_ = 0;
    latest_revision_ = 0;
    snapshot_revision_.reset();
    awaiting_snapshot_ = false;
    lifetime_ = GraphicsLifetime::next();
    ++revision_;
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::retireOtherGenerations(ImageKey current) noexcept {
    for (auto& image : images_) {
      const auto key = image->description().key;
      if (key.image_id == current.image_id && key.generation != current.generation) {
        image->retire();
      }
    }

    collectRetired(current.image_id);
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::collectRetired(std::uint32_t image_id) noexcept {
    for (auto index = images_.size(); index-- > 0;) {
      const auto& image = *images_[index];
      const auto key = image.description().key;
      if (key.image_id == image_id && image.retired() && !hasPlacementReference(key)) {
        eraseImage(index);
      }
    }
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::requireSnapshot() noexcept {
    awaiting_snapshot_ = true;
    snapshot_revision_.reset();
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::reached(GraphicsLimitKind kind) {
    requireSnapshot();

    throw GraphicsLimitError{kind};
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::containsImageId(std::uint32_t id) const noexcept {
    return std::ranges::any_of(images_, [id](const auto& image) {
      return image->description().key.image_id == id;
    });
  }

  template <Allocator Memory>
  std::size_t GraphicsStore<Memory>::logicalImageCount() const noexcept {
    std::array<std::uint32_t, image_capacity> identifiers{};
    std::size_t count = 0;

    for (const auto& image : images_) {
      const auto id = image->description().key.image_id;
      const auto known = std::span{identifiers}.first(count);
      if (std::ranges::find(known, id) == known.end()) {
        identifiers[count++] = id;
      }
    }

    return count;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::hasPlacementReference(ImageKey key) const noexcept {
    return std::ranges::any_of(placements_, [key](const auto& placement) {
      return sameKey(placement.key, key);
    });
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::validatePlacement(const GraphicsPlacement& placement) const {
    const auto* image = findImage(placement.key);
    if (image == nullptr || placement.virtual_id == 0) {
      throw EncodingError{"Invalid graphics placement image or identity"};
    }

    const auto& description = image->description();
    if (placement.source_x >= description.width || placement.source_y >= description.height || placement.source_width > description.width - placement.source_x || placement.source_height > description.height - placement.source_y) {
      throw EncodingError{"Invalid graphics source rectangle"};
    }
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::sameKey(ImageKey left, ImageKey right) noexcept {
    return left.image_id == right.image_id && left.generation == right.generation;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::accept(std::uint64_t revision) {
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

  template <Allocator Memory>
  void GraphicsStore<Memory>::eraseImage(std::size_t index) noexcept {
    const auto released = images_[index]->description().byte_len;

    bytes_ -= released;
    budget_.used -= released;
    released_bytes_ += released;
    images_.erase(images_.begin() + index);
  }

  template <Allocator Memory>
  void GraphicsStore<Memory>::clear() noexcept {
    budget_.used -= bytes_;
    released_bytes_ += bytes_;
    bytes_ = 0;
    images_.clear();
    placements_.clear();
  }

  template class GraphicsStore<Memory>;
  template class GraphicsStore<ConcurrentMemory>;

}
