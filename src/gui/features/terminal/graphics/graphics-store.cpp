module telar.gui.features.terminal.graphics;

import std;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.wire.graphics;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::graphics {

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
        images_(memory),
        placements_(memory) {}

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

        placements_.retain([&](const auto& placement) {
          return !sameKey(placement.key, key);
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
        if (&images_[index].get() == previous) {
          eraseImage(index);

          break;
        }
      }
    }

    auto replacement = ds::makeBox<Image>(memory_, memory_, message.image);

    images_.push(std::move(replacement));
    bytes_ += requested;
    budget_.used += requested;

    return false;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::chunk(const GraphicsImageChunk& message) {
    if (!accept(message.header.revision)) {
      return false;
    }

    auto* image = findImageMut(message.key);
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
    const auto placements = placements_.viewMut();
    const auto found = std::ranges::find_if(placements, [&](const auto& entry) {
      return entry.virtual_id == placement.virtual_id;
    });
    if (found != placements.end()) {
      *found = placement;
    } else {
      if (placements_.size() == placement_capacity) {
        reached(GraphicsLimitKind::placements);
      }

      placements_.push(placement);
    }

    ++revision_;

    return true;
  }

  template <Allocator Memory>
  bool GraphicsStore<Memory>::erase(const GraphicsDeleteImage& message) {
    if (!awaiting_snapshot_ && !accept(message.header.revision)) {
      return false;
    }

    auto* image = findImageMut(message.key);
    if (image == nullptr) {
      return false;
    }

    image->retire();
    placements_.retain([&](const auto& placement) {
      return !sameKey(placement.key, message.key);
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

    const auto removed = placements_.retain([&](const auto& placement) {
      return placement.virtual_id != message.virtual_id;
    });
    if (removed == 0) {
      return false;
    }

    collectRetired(message.key.image_id);
    ++revision_;

    return true;
  }

  template <Allocator Memory>
  auto GraphicsStore<Memory>::findImage(ImageKey key) const noexcept -> const Image* {
    const auto found = std::find_if(images_.begin(), images_.end(), [&](const auto& image) {
      return sameKey(image->description().key, key);
    });

    return found == images_.end() ? nullptr : &found->get();
  }

  template <Allocator Memory>
  auto GraphicsStore<Memory>::findImageMut(ImageKey key) noexcept -> Image* {
    const auto images = images_.viewMut();
    const auto found = std::find_if(images.begin(), images.end(), [&](const auto& image) {
      return sameKey(image->description().key, key);
    });

    return found == images.end() ? nullptr : &found->getMut();
  }

  template <Allocator Memory>
  auto GraphicsStore<Memory>::readyImage(ImageKey key) const noexcept -> const Image* {
    if (const auto* image = findImage(key); image != nullptr && image->ready() && !image->retired()) {
      return image;
    }

    const Image* latest = nullptr;

    for (const auto& image : images_) {
      if (image->description().key.image_id == key.image_id && image->ready() && !image->retired() && (latest == nullptr || image->description().key.generation > latest->description().key.generation)) {
        latest = &image.get();
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
    for (auto& image : images_.viewMut()) {
      const auto key = image->description().key;
      if (key.image_id == current.image_id && key.generation != current.generation) {
        image.getMut().retire();
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
    ds::Array<std::uint32_t, image_capacity> identifiers{};
    std::size_t count = 0;

    for (const auto& image : images_) {
      const auto id = image->description().key.image_id;
      const auto known = std::span{identifiers}.first(count);
      if (std::ranges::find(known, id) == known.end()) {
        identifiers.atMut(count++) = id;
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
    static_cast<void>(images_.remove(index));
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
