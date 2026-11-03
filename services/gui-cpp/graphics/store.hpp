#pragma once

#include "core/memory.hpp"
#include "lifetime.hpp"
#include "limit.hpp"
#include "resync_required.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>

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
    Image(Memory &memory, ImageDescription description)
        : description_(description),
          allocator_(memory),
          pixels_(allocator_.allocate(static_cast<std::size_t>(description_.byte_len))) {
    }

    ~Image() {
      allocator_.deallocate(pixels_, static_cast<std::size_t>(description_.byte_len));
    }

    Image(const Image &) = delete;
    Image &operator=(const Image &) = delete;
    Image(Image &&) = delete;
    Image &operator=(Image &&) = delete;

    void append(std::uint64_t offset, std::span<const Byte> bytes) {
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
    bool readShared(Source &source) {
      if (received_ != 0 || chunks_ != 0) {
        throw EncodingError{"Shared image already received pixels"};
      }

      if (!source.read(std::span<Byte>{pixels_, static_cast<std::size_t>(description_.byte_len)})) {
        return false;
      }

      received_ = description_.byte_len;
      return true;
    }

    [[nodiscard]] bool ready() const noexcept {
      return received_ == description_.byte_len;
    }

    [[nodiscard]] std::span<const Byte> receivedPixels() const noexcept {
      return {pixels_, received_};
    }

    [[nodiscard]] std::span<const Byte> pixels() const noexcept {
      return ready() ? std::span<const Byte>{pixels_, received_} : std::span<const Byte>{};
    }

    [[nodiscard]] const ImageDescription &description() const noexcept {
      return description_;
    }

    void retire() noexcept {
      retired_ = true;
    }

    [[nodiscard]] bool retired() const noexcept {
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

  GraphicsStore(Memory &memory, GraphicsBudget &budget)
      : memory_(memory),
        budget_(budget),
        images_(AllocatorRef<Owned<Image, Memory>, Memory>{memory}),
        placements_(AllocatorRef<GraphicsPlacement, Memory>{memory}) {}

  ~GraphicsStore() {
    budget_.used -= bytes_;
  }

  GraphicsStore(const GraphicsStore &) = delete;
  GraphicsStore &operator=(const GraphicsStore &) = delete;
  GraphicsStore(GraphicsStore &&) = delete;
  GraphicsStore &operator=(GraphicsStore &&) = delete;

  bool snapshot(const GraphicsSnapshot &message) {
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

  bool image(const GraphicsImage &message) {
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

  bool chunk(const GraphicsImageChunk &message) {
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
  bool sharedImage(const GraphicsSharedImage &message, Source &source) {
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

  bool placement(const GraphicsPlacementMessage &message) {
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

  bool erase(const GraphicsDeleteImage &message) {
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

  bool erase(const GraphicsDeletePlacement &message) {
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

  [[nodiscard]] Image *findImage(ImageKey key) const noexcept {
    const auto found = std::find_if(images_.begin(), images_.end(), [&](const auto &image) {
      return sameKey(image->description().key, key);
    });

    return found == images_.end() ? nullptr : found->get();
  }

  [[nodiscard]] const Image *readyImage(ImageKey key) const noexcept {
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

  [[nodiscard]] std::span<const GraphicsPlacement> placements() const noexcept {
    return placements_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] GraphicsLifetime lifetime() const noexcept {
    return lifetime_;
  }

  [[nodiscard]] std::size_t globalRetainedBytes() const noexcept {
    return budget_.used;
  }

  std::uint64_t takeCredit() noexcept {
    return std::exchange(released_bytes_, 0);
  }

  void detach() noexcept {
    clear();
    released_bytes_ = 0;
    latest_revision_ = 0;
    snapshot_revision_.reset();
    awaiting_snapshot_ = false;
    lifetime_ = GraphicsLifetime::next();
    ++revision_;
  }

private:
  void retireOtherGenerations(ImageKey current) noexcept {
    for (auto &image : images_) {
      const auto key = image->description().key;
      if (key.image_id == current.image_id && key.generation != current.generation) {
        image->retire();
      }
    }

    collectRetired(current.image_id);
  }

  void collectRetired(std::uint32_t image_id) noexcept {
    for (auto index = images_.size(); index-- > 0;) {
      const auto &image = *images_[index];
      const auto key = image.description().key;
      if (key.image_id == image_id && image.retired() && !hasPlacementReference(key)) {
        eraseImage(index);
      }
    }
  }

  void requireSnapshot() noexcept {
    awaiting_snapshot_ = true;
    snapshot_revision_.reset();
  }

  [[noreturn]] void reached(GraphicsLimitKind kind) {
    requireSnapshot();

    throw GraphicsLimitError{kind};
  }

  [[nodiscard]] bool containsImageId(std::uint32_t id) const noexcept {
    return std::ranges::any_of(images_, [id](const auto &image) {
      return image->description().key.image_id == id;
    });
  }

  [[nodiscard]] std::size_t logicalImageCount() const noexcept {
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

  [[nodiscard]] bool hasPlacementReference(ImageKey key) const noexcept {
    return std::ranges::any_of(placements_, [key](const auto &placement) {
      return sameKey(placement.key, key);
    });
  }

  void validatePlacement(const GraphicsPlacement &placement) const {
    const auto *image = findImage(placement.key);
    if (image == nullptr || placement.virtual_id == 0) {
      throw EncodingError{"Invalid graphics placement image or identity"};
    }

    const auto &description = image->description();
    if (placement.source_x >= description.width || placement.source_y >= description.height || placement.source_width > description.width - placement.source_x || placement.source_height > description.height - placement.source_y) {
      throw EncodingError{"Invalid graphics source rectangle"};
    }
  }

  static bool sameKey(ImageKey left, ImageKey right) noexcept {
    return left.image_id == right.image_id && left.generation == right.generation;
  }

  bool accept(std::uint64_t revision) {
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

  void eraseImage(std::size_t index) noexcept {
    const auto released = images_[index]->description().byte_len;
    bytes_ -= released;
    budget_.used -= released;
    released_bytes_ += released;
    images_.erase(images_.begin() + index);
  }

  void clear() noexcept {
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
