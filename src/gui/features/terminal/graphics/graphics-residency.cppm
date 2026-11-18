module;
#include "tbc/annotations.hpp"

// The textures a window's frames draw images with: which stay resident, how many a frame may
// draw, and the placements a frame keeps when there are more.
export module telar.gui.features.terminal.graphics:residency;

import std;

import :store;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: graphics/image_draw_budget.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    class ImageDrawBudget {
    public:
      static constexpr std::size_t capacity = 2048;

      [[nodiscard]] bool take() noexcept;
      [[nodiscard]] std::size_t used() const noexcept;

    private:
      std::size_t used_ = 0;
    };

  }
}

// Interface: graphics/image_residency.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    using ImageTextureHandle = std::uint32_t;
    inline constexpr std::size_t image_texture_capacity = 512;

    struct ImageTextureIdentity {
      GraphicsLifetime catalog;
      std::uint32_t image_id = 0;
      std::uint64_t generation = 0;

      bool operator==(const ImageTextureIdentity&) const noexcept = default;

      [[nodiscard]] bool sameImage(const ImageTextureIdentity& other) const noexcept;
    };

    struct ImageTextureSize {
      std::uint32_t width = 0;
      std::uint32_t height = 0;

      bool operator==(const ImageTextureSize&) const noexcept = default;
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
    concept ImageTextureReleases = requires(Resources& resources, ImageTextureHandle handle) {
      { resources.release(handle) } noexcept -> std::same_as<void>;
    };

    // The residency rows of ImageResidency. The caller's resources are reached through `release`,
    // so that the work stays in texture_cache.cpp.
    class ImageResidencyTable {
    public:
      static constexpr std::size_t capacity = image_texture_capacity;
      static constexpr std::size_t byte_capacity = runtime::GraphicsLimits::maximum_global_bytes;
      static constexpr std::uint32_t maximum_side = 16384;
      static constexpr std::size_t maximum_uploads = 4;
      static constexpr std::size_t uploads_per_image = 2;
      static constexpr std::size_t maximum_spares = 4;
      static constexpr std::uint64_t spare_lifetime_ns = 2'000'000'000;
      static constexpr std::uint64_t idle_lifetime_ns = 5'000'000'000;

      ImageResidencyTable(const ImageResidencyTable&) = delete;
      ImageResidencyTable& operator=(const ImageResidencyTable&) = delete;
      ImageResidencyTable(ImageResidencyTable&&) = delete;
      ImageResidencyTable& operator=(ImageResidencyTable&&) = delete;

      void beginFrame(std::uint64_t now_ns) noexcept;
      [[nodiscard]] ImageAdmission request(ImageTextureRequest request) noexcept;
      bool complete(ImageTextureHandle handle, bool success, std::uint64_t now_ns) noexcept;
      void abandon() noexcept;
      void clear() noexcept;
      void markNeeded(ImageTextureHandle handle) noexcept;
      void keepWarm(ImageTextureUse use) noexcept;
      void noteDrawn(ImageTextureHandle handle) noexcept;
      void sweep(std::span<const bool, capacity> retained) noexcept;
      [[nodiscard]] ImageTextureHandle find(ImageTextureIdentity identity) const noexcept;
      [[nodiscard]] ImageTextureHandle newestReady(ImageTextureIdentity identity) const noexcept;
      [[nodiscard]] const ImageTextureState* state(ImageTextureHandle handle) const noexcept;
      [[nodiscard]] std::uint32_t wakeupAfter(std::uint64_t now_ns) const noexcept;
      [[nodiscard]] std::size_t residentBytes() const noexcept;
      [[nodiscard]] std::size_t uploading() const noexcept;
      [[nodiscard]] std::size_t uploadsStarted() const noexcept;
      [[nodiscard]] std::size_t spares() const noexcept;
      [[nodiscard]] std::size_t size() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] std::uint64_t frame() const noexcept;
      [[nodiscard]] std::uint64_t presented() const noexcept;
      [[nodiscard]] std::span<const std::uint16_t> rows() const noexcept;

      [[nodiscard]] static constexpr ImageTextureHandle handleOf(std::size_t row) noexcept {
        return static_cast<ImageTextureHandle>(row + 1);
      }

    protected:
      using Release = void (*)(void* resources, ImageTextureHandle handle) noexcept;
      using Retained = bool (*)(const void* context, std::uint16_t row, ImageTextureIdentity identity);

      ImageResidencyTable(void* resources, Release release) noexcept;
      ~ImageResidencyTable() = default;

      // Retires the rows not drawn this frame that `retained` does not keep; it throws what `retained` throws.
      void sweepRows(const void* context, Retained retained);

    private:
      using Row = std::uint16_t;

      [[nodiscard]] static bool validHandle(ImageTextureHandle handle) noexcept;
      [[nodiscard]] ImageTextureState* findState(ImageTextureHandle handle) noexcept;
      [[nodiscard]] static std::size_t byteSize(ImageTextureSize size) noexcept;
      [[nodiscard]] static ds::Option<std::uint64_t> expiry(const ImageTextureState& state) noexcept;
      [[nodiscard]] std::size_t uploadsOf(ImageTextureIdentity identity) const noexcept;
      [[nodiscard]] ds::Option<Row> takeRow(ImageTextureIdentity identity, ImageTextureSize size, std::size_t retained_bytes) noexcept;
      void assign(Row row, ImageTextureIdentity identity) noexcept;
      [[nodiscard]] bool reserve(std::size_t bytes, std::size_t retained_bytes) noexcept;
      [[nodiscard]] bool evictOne() noexcept;
      void retire(Row row) noexcept;
      void discard(Row row) noexcept;

      void* resources_;
      Release release_;
      ds::Array<ImageTextureState, capacity> states_{};
      ds::Array<Row, capacity> occupied_{};
      ds::Array<Row, capacity> position_{};
      ds::Array<Row, capacity> free_{};
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

    // Generic over the caller's texture resources: it only erases them for ImageResidencyTable.
    template <ImageTextureReleases Resources>
    class TBC_GENERIC ImageResidency : public ImageResidencyTable {
    public:
      explicit ImageResidency(Resources& resources) noexcept
          : ImageResidencyTable(&resources, [](void* context, ImageTextureHandle handle) noexcept {
              static_cast<Resources*>(context)->release(handle);
            }) {}

      ~ImageResidency() = default;

      ImageResidency(const ImageResidency&) = delete;
      ImageResidency& operator=(const ImageResidency&) = delete;
      ImageResidency(ImageResidency&&) = delete;
      ImageResidency& operator=(ImageResidency&&) = delete;

      using ImageResidencyTable::sweep;

      template <typename IsRetained>
        requires std::predicate<const IsRetained&, ImageTextureIdentity>
      void sweep(const IsRetained& is_retained) noexcept(noexcept(is_retained(ImageTextureIdentity{}))) {
        sweepRows(&is_retained, [](const void* context, std::uint16_t, ImageTextureIdentity identity) -> bool {
          return (*static_cast<const IsRetained*>(context))(identity);
        });
      }
    };

  }
}

// Interface: graphics/placement_selection.cppm
export {
  namespace telar::gui::features::terminal::graphics {

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

        bool operator==(const Identity&) const noexcept = default;
      };

      struct Candidate {
        Identity identity;
        Layer layer = Layer::above_text;
        std::int32_t z_index = 0;
      };

      void begin() noexcept;
      void keep(Candidate candidate) noexcept;
      [[nodiscard]] bool finish() noexcept;
      [[nodiscard]] bool contains(GraphicsLifetime catalog, std::uint64_t virtual_id) const noexcept;
      [[nodiscard]] bool containsImage(GraphicsLifetime catalog, std::uint32_t image_id) const noexcept;
      [[nodiscard]] std::span<const Identity> selected() const noexcept;
      [[nodiscard]] std::size_t dropped() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] static Layer layer(const GraphicsPlacement& placement) noexcept;

    private:
      using ImageIdentity = std::tuple<std::uint64_t, std::uint32_t>;
      static constexpr std::size_t heap_children = 2;

      [[nodiscard]] static std::tuple<std::uint64_t, std::uint64_t> identityKey(const Identity& identity) noexcept;
      [[nodiscard]] static ImageIdentity imageKey(const Identity& identity) noexcept;
      [[nodiscard]] static bool paintsBelow(const Candidate& left, const Candidate& right) noexcept;
      void siftUp(std::size_t index) noexcept;
      void siftDown() noexcept;

      ds::Array<Candidate, capacity> candidates_{};
      ds::Array<Identity, capacity> selected_{};
      ds::Array<ImageIdentity, capacity> images_{};
      std::size_t candidate_count_ = 0;
      std::size_t selected_count_ = 0;
      std::size_t image_count_ = 0;
      std::size_t dropped_ = 0;
      std::uint64_t revision_ = 0;
    };

  }
}
