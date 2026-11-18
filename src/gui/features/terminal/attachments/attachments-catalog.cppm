module;
#include "features/terminal/attachments/capture.hpp"
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

// The images attached to a pane's prompt: the shelf's catalog of them, and the markers the
// prompt shows for each and how deleting one plans the keys.
export module telar.gui.features.terminal.attachments:catalog;

import std;
import telar.gui.foundation.terminal;
import telar.wire.vocabulary;
import telar.base.ds;

// The capture types stay textual because the Objective-C++ clipboard source
// shares them, in telar::gui; importers reach their names through these
// declarations instead of including them. Markers and the catalog are module
// code: they read the terminal screen and cells through their owner modules.
export namespace telar::gui::features::terminal::attachments {
  using telar::gui::AttachmentCapture;
  using telar::gui::AttachmentLimits;
  using telar::gui::AttachmentMarkerPolicy;
  using telar::gui::AttachmentTarget;
  using telar::gui::ClipboardCapture;
  using telar::gui::ClipboardCaptureRequest;
  using telar::gui::eraseSensitiveBytes;
  using telar::gui::SensitiveBytes;
}

export namespace telar::gui::features::terminal::attachments {

  struct AttachmentMarkerScreen {
    std::span<const CellValue> cells;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    Cursor cursor;

    template <Allocator Memory>
    [[nodiscard]] static AttachmentMarkerScreen from(const Screen<Memory>& screen) noexcept;

    [[nodiscard]] const CellValue* cell(CellPosition point) const noexcept;

    [[nodiscard]] bool matches(CellPosition point, std::string_view literal) const noexcept;

    [[nodiscard]] static bool blank(const CellValue& cell) noexcept;

    [[nodiscard]] bool isolatedInverse(CellPosition point) const noexcept;

    [[nodiscard]] ds::Option<CellPosition> editorCursor() const noexcept;

    [[nodiscard]] bool promptContinues() const noexcept;

  private:
    [[nodiscard]] static bool inverse(const CellValue& cell) noexcept;
  };

  extern template AttachmentMarkerScreen AttachmentMarkerScreen::from<telar::Memory>(const Screen<telar::Memory>& screen) noexcept;
  extern template AttachmentMarkerScreen AttachmentMarkerScreen::from<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen) noexcept;

  struct NumericAttachmentMarker {
    std::uint16_t number = 0;
    CellPosition start;
    CellPosition end;
  };

  class NumericAttachmentMarkers {
  public:
    explicit NumericAttachmentMarkers(AttachmentMarkerScreen screen) noexcept;

    [[nodiscard]] ds::Option<NumericAttachmentMarker> next() noexcept;

    [[nodiscard]] static ds::Option<NumericAttachmentMarker> parse(AttachmentMarkerScreen screen, CellPosition point) noexcept;

    [[nodiscard]] static ds::Option<NumericAttachmentMarker> closest(AttachmentMarkerScreen screen, std::uint16_t number) noexcept;

    [[nodiscard]] static bool present(AttachmentMarkerScreen screen, std::uint16_t number) noexcept;

    [[nodiscard]] static ds::Option<std::uint16_t> steps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept;

  private:
    static constexpr std::string_view head = "[Image";
    static constexpr std::string_view separator = " #";
    static constexpr std::uint16_t decimal_base = 10;

    [[nodiscard]] static ds::Option<NumericAttachmentMarker> tail(AttachmentMarkerScreen screen, CellPosition start, CellPosition point) noexcept;

    [[nodiscard]] static bool blankTail(AttachmentMarkerScreen screen, CellPosition point) noexcept;

    [[nodiscard]] static ds::Option<CellPosition> firstInk(AttachmentMarkerScreen screen, std::uint32_t row) noexcept;

    AttachmentMarkerScreen screen_;
    CellPosition position_;
  };

  inline constexpr std::size_t attachment_uuid_bytes = 36;
  using AttachmentPathUuid = std::array<std::uint8_t, attachment_uuid_bytes>;

  struct PathAttachmentMarker {
    AttachmentPathUuid uuid{};
    CellPosition start;
    CellPosition end;
    ds::Option<std::uint16_t> cells;
  };

  class PathAttachmentMarkers {
  public:
    static constexpr std::uint16_t maximum_cells = 512;

    [[nodiscard]] static ds::Option<PathAttachmentMarker> find(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept;

    [[nodiscard]] static std::size_t collect(AttachmentMarkerScreen screen, std::span<PathAttachmentMarker> output) noexcept;

    [[nodiscard]] static ds::Option<std::uint16_t> cursorOnRow(AttachmentMarkerScreen screen, std::uint16_t row) noexcept;

    [[nodiscard]] static bool cursorAt(AttachmentMarkerScreen screen, CellPosition point) noexcept;

  private:
    static constexpr std::string_view prefix = "pi-clipboard-";
    static constexpr std::array<std::string_view, 4> extensions{"png", "jpg", "webp", "gif"};
    static constexpr std::array<std::size_t, 4> dash_positions{8, 13, 18, 23};

    class Scan {
    public:
      explicit Scan(AttachmentMarkerScreen screen, CellPosition point = {}) noexcept;

      [[nodiscard]] ds::Option<CellPosition> position() noexcept;

      [[nodiscard]] CellPosition rawPosition() const noexcept;

      void step() noexcept;

      [[nodiscard]] bool expect(std::uint8_t byte) noexcept;

    private:
      AttachmentMarkerScreen screen_;
      CellPosition point_;
    };

    [[nodiscard]] static bool single(const CellValue& cell) noexcept;

    [[nodiscard]] static bool blank(const CellValue& cell) noexcept;

    [[nodiscard]] static bool hex(std::uint8_t byte) noexcept;

    [[nodiscard]] static bool alphanumeric(std::uint8_t byte) noexcept;

    [[nodiscard]] static ds::Option<CellPosition> matchExtension(Scan scan) noexcept;

    [[nodiscard]] static ds::Option<PathAttachmentMarker> parseHead(AttachmentMarkerScreen screen, CellPosition start) noexcept;

    [[nodiscard]] static bool rowForceWrapped(AttachmentMarkerScreen screen, std::uint32_t row) noexcept;

    [[nodiscard]] static CellPosition pathStart(AttachmentMarkerScreen screen, CellPosition marker) noexcept;

    [[nodiscard]] static ds::Option<std::uint16_t> countCells(AttachmentMarkerScreen screen, CellPosition start, CellPosition end) noexcept;

    [[nodiscard]] static PathAttachmentMarker extend(AttachmentMarkerScreen screen, PathAttachmentMarker head) noexcept;
  };

  enum class AttachmentMarkerDeletion : std::uint8_t {
    backward,
    forward,
  };
  enum class AttachmentMarkerDirection : std::uint8_t {
    left,
    right,
  };
  enum class AttachmentMarkerReach : std::uint8_t {
    navigation = 1,
    path_cells = 2,
    keys = 3,
  };

  struct AttachmentMarkerRemoval {
    AttachmentMarkerDirection direction = AttachmentMarkerDirection::left;
    std::uint16_t steps = 0;
    AttachmentMarkerDeletion deletion = AttachmentMarkerDeletion::backward;
    std::uint16_t deletions = 1;

    [[nodiscard]] std::uint32_t keyCount() const noexcept;
  };

  struct AttachmentMarkerPlan {
    ds::Option<AttachmentMarkerRemoval> removal;
    ds::Option<AttachmentMarkerReach> limit;
    ds::Option<std::uint32_t> requested;
  };

  class AttachmentMarkerPlanning {
  public:
    [[nodiscard]] static AttachmentMarkerPlan placeholder(AttachmentMarkerScreen screen, std::uint16_t number) noexcept;

    [[nodiscard]] static AttachmentMarkerPlan path(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept;

  private:
    [[nodiscard]] static ds::Option<std::uint16_t> plainSteps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept;
  };

  enum class AttachmentEviction : std::uint8_t {
    items,
    retained_bytes,
  };

  struct AttachmentItem {
    std::uint64_t id = ClipboardCapture::invalid_id;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
  };

  struct AttachmentSnapshot {
    std::array<AttachmentItem, AttachmentLimits::maximum_items> items{};
    std::size_t count = 0;
    ds::Option<std::uint64_t> modal;
  };

  // Delivery owns presentation resources. A retired slot remains charged until
  // its last render lease is released; eviction may only reuse releasable slots.
  // Generic over the caller's delivery and its slot state, so it stays whole for each importer.
  template <Allocator Memory, typename Delivery>
  class TBC_GENERIC AttachmentCatalog {
  public:
    struct Slot {
      AttachmentCapture<Memory> capture;
      Delivery::SlotState delivery;
      bool retired = false;
      ds::Option<std::variant<std::uint16_t, AttachmentPathUuid>> marker = ds::none;

      [[nodiscard]] bool owns(AttachmentTarget target) const noexcept {
        return !retired && capture.request.capture.target == target;
      }
    };

    explicit AttachmentCatalog(Delivery& delivery) noexcept
        : delivery_(delivery) {}

    AttachmentCatalog(const AttachmentCatalog&) = delete;
    AttachmentCatalog& operator=(const AttachmentCatalog&) = delete;
    AttachmentCatalog(AttachmentCatalog&&) = delete;
    AttachmentCatalog& operator=(AttachmentCatalog&&) = delete;

    ~AttachmentCatalog() {
      for ([[maybe_unused]] const auto& slot : slots_) {
        TELAR_ASSERT(!slot || delivery_.canRelease(slot->delivery));
      }
    }

    [[nodiscard]] std::size_t retainedBytes() const noexcept {
      return total_bytes_;
    }

    [[nodiscard]] std::uint64_t ingressVersion() const noexcept {
      return ingress_version_;
    }

    [[nodiscard]] const ds::Option<AttachmentTarget>& target() const noexcept {
      return target_;
    }

    bool setTarget(ds::Option<AttachmentTarget> target) noexcept {
      if (target_ == target) {
        return false;
      }

      target_ = target;
      deletion_pending_.reset();
      modal_.reset();

      return true;
    }

    [[nodiscard]] AttachmentSnapshot snapshot() const noexcept {
      AttachmentSnapshot result;

      for (const auto& slot : slots_) {
        if (slot && target_ && slot->owns(*target_)) {
          result.items[result.count++] = {.id = slot->capture.request.capture.id, .width = slot->capture.width, .height = slot->capture.height};
        }
      }

      std::sort(result.items.begin(), result.items.begin() + static_cast<std::ptrdiff_t>(result.count), [](const auto& left, const auto& right) {
        return left.id < right.id;
      });

      for (std::size_t index = 0; index < result.count; ++index) {
        if (result.items[index].id == modal_) {
          result.modal = modal_;
        }
      }

      return result;
    }

    [[nodiscard]] const Slot* find(std::uint64_t id) const noexcept {
      for (const auto& slot : slots_) {
        if (slot && slot->capture.request.capture.id == id) {
          return &*slot;
        }
      }

      return nullptr;
    }

    [[nodiscard]] ds::Option<AttachmentEviction> adopt(AttachmentCapture<Memory>& capture) {
      validate(capture);
      ds::Option<AttachmentEviction> evicted;

      while (const auto reach = evictionReach(capture.png.size())) {
        const auto oldest = oldestReleasable();
        if (!oldest) {
          throw std::runtime_error{"AttachmentSelfFull"};
        }

        auto& slot = slots_[*oldest];
        if (!slot) {
          throw std::logic_error{"MissingAttachmentSlot"};
        }

        if (!slot->retired && !evicted) {
          evicted = reach;
        }

        delivery_.retire(slot.getMut().delivery);
        free(*oldest);
      }

      auto resource = delivery_.create();
      const auto index = freeIndex();
      if (!index) {
        throw std::logic_error{"MissingAttachmentSlot"};
      }

      total_bytes_ += capture.png.size();
      slots_[*index].emplace(Slot{.capture = std::move(capture), .delivery = std::move(resource)});
      ++ingress_version_;

      return evicted;
    }

    bool remove(std::uint64_t id) noexcept {
      for (std::size_t index = 0; index < slots_.size(); ++index) {
        const auto& slot = slots_[index];
        if (slot && slot->capture.request.capture.id == id && !slot->retired) {
          retire(index);

          return true;
        }
      }

      return false;
    }

    std::size_t removeVisible(AttachmentTarget target) noexcept {
      std::size_t count = 0;

      for (std::size_t index = 0; index < slots_.size(); ++index) {
        const auto& slot = slots_[index];
        if (slot && slot->owns(target)) {
          retire(index);
          ++count;
        }
      }

      if (deletion_pending_ && deletion_pending_->target == target) {
        deletion_pending_.reset();
      }

      return count;
    }

    [[nodiscard]] AttachmentMarkerPlan planMarkerRemoval(std::uint64_t id, AttachmentMarkerScreen screen) const noexcept {
      const auto visible = snapshot();
      const auto* const slot = find(id);
      if (slot == nullptr) {
        return {};
      }

      for (std::size_t index = 0; index < visible.count; ++index) {
        if (visible.items[index].id != id) {
          continue;
        }

        AttachmentMarkerPlan plan;

        if (slot->capture.request.marker_policy == AttachmentMarkerPolicy::pasted_path) {
          const auto* const path = markerPath(*slot);
          if (path != nullptr) {
            plan = AttachmentMarkerPlanning::path(screen, *path);
          }
        } else {
          const auto number = markerNumber(*slot).valueOr(static_cast<std::uint16_t>(index + 1));

          plan = AttachmentMarkerPlanning::placeholder(screen, number);
        }

        if (plan.removal && plan.removal->keyCount() > AttachmentLimits::maximum_removal_keys) {
          return {.removal = ds::none, .limit = AttachmentMarkerReach::keys, .requested = plan.removal->keyCount()};
        }

        return plan;
      }

      return {};
    }

    [[nodiscard]] ds::Option<std::uint64_t> markerAtDeletion(AttachmentMarkerScreen screen, AttachmentMarkerDeletion deletion) const noexcept {
      const auto visible = snapshot();

      for (std::size_t index = 0; index < visible.count; ++index) {
        const auto* const slot = find(visible.items[index].id);
        if (slot == nullptr) {
          continue;
        }

        if (touches(*slot, screen, {static_cast<std::uint16_t>(index + 1), deletion})) {
          return visible.items[index].id;
        }
      }

      return ds::none;
    }

    void expectMarkerDeletion(AttachmentTarget target) noexcept {
      for (const auto& slot : slots_) {
        if (slot && slot->owns(target) && slot->capture.request.marker_policy != AttachmentMarkerPolicy::ordered) {
          deletion_pending_ = PendingDeletion{.target = target, .frames = AttachmentLimits::deletion_watch_frames};

          return;
        }
      }
    }

    std::size_t reconcileMarkers(AttachmentTarget target, AttachmentMarkerScreen screen) noexcept {
      learnMarkers(target, screen);
      if (!deletion_pending_ || deletion_pending_->target != target) {
        return 0;
      }

      std::size_t removed = 0;

      for (std::size_t index = 0; index < slots_.size(); ++index) {
        const auto& slot = slots_[index];
        if (slot && slot->marker && slot->owns(target) && !markerPresent(*slot, screen)) {
          retire(index);
          ++removed;
        }
      }

      if (deletion_pending_) {
        --deletion_pending_.getMut().frames;
        if (removed != 0 || deletion_pending_->frames == 0) {
          deletion_pending_.reset();
        }
      }

      return removed;
    }

    [[nodiscard]] bool pendingMarkerAtDeletion(AttachmentMarkerScreen screen, AttachmentMarkerPolicy policy, AttachmentMarkerDeletion deletion) const noexcept {
      const auto visible = snapshot();
      if (visible.count >= AttachmentLimits::maximum_items) {
        return false;
      }

      if (policy != AttachmentMarkerPolicy::pasted_path) {
        return numericTouches(screen, static_cast<std::uint16_t>(visible.count + 1), deletion);
      }

      if (!target_) {
        return false;
      }

      std::array<PathAttachmentMarker, AttachmentLimits::maximum_items * 2> paths{};
      const auto count = PathAttachmentMarkers::collect(screen, paths);

      for (std::size_t index = 0; index < count; ++index) {
        const auto& path = paths[index];
        if (!pathClaimed(*target_, path.uuid) && PathAttachmentMarkers::cursorAt(screen, deletion == AttachmentMarkerDeletion::backward ? path.end : path.start)) {
          return true;
        }
      }

      return false;
    }

    void removeAll() noexcept {
      deletion_pending_.reset();
      modal_.reset();
      for (std::size_t index = 0; index < slots_.size(); ++index) {
        if (slots_[index] && !slots_[index]->retired) {
          retire(index);
        }
      }

      reapRetired();
    }

    void reapRetired() noexcept {
      for (std::size_t index = 0; index < slots_.size(); ++index) {
        const auto& slot = slots_[index];
        if (slot && slot->retired && delivery_.canRelease(slot->delivery)) {
          free(index);
        }
      }
    }

    bool openModal(std::uint64_t id) noexcept {
      const auto* const slot = find(id);
      if (slot == nullptr || !target_ || !slot->owns(*target_) || modal_ == id) {
        return false;
      }

      modal_ = id;

      return true;
    }

    bool closeModal() noexcept {
      return std::exchange(modal_, ds::none).hasValue();
    }

  private:
    struct PendingDeletion {
      AttachmentTarget target;
      std::uint8_t frames = 0;
    };

    struct MarkerBoundary {
      std::uint16_t ordinal;
      AttachmentMarkerDeletion deletion;
    };

    [[nodiscard]] static ds::Option<std::uint16_t> markerNumber(const Slot& slot) noexcept {
      const auto* const value = slot.marker ? std::get_if<std::uint16_t>(&*slot.marker) : nullptr;

      return value != nullptr ? ds::Option{*value} : ds::none;
    }

    [[nodiscard]] static const AttachmentPathUuid* markerPath(const Slot& slot) noexcept {
      return slot.marker ? std::get_if<AttachmentPathUuid>(&*slot.marker) : nullptr;
    }

    [[nodiscard]] static bool numericTouches(AttachmentMarkerScreen screen, std::uint16_t number, AttachmentMarkerDeletion deletion) noexcept {
      if (!screen.cursor.visible) {
        return false;
      }

      NumericAttachmentMarkers scan{screen};
      const CellPosition cursor{.x = screen.cursor.x, .y = screen.cursor.y};

      while (const auto marker = scan.next()) {
        if (marker->number == number && (deletion == AttachmentMarkerDeletion::backward ? marker->end : marker->start) == cursor) {
          return true;
        }
      }

      return false;
    }

    [[nodiscard]] static bool touches(const Slot& slot, AttachmentMarkerScreen screen, MarkerBoundary boundary) noexcept {
      if (slot.capture.request.marker_policy != AttachmentMarkerPolicy::pasted_path) {
        return numericTouches(screen, markerNumber(slot).valueOr(boundary.ordinal), boundary.deletion);
      }

      const auto* const uuid = markerPath(slot);
      const auto path = uuid != nullptr ? PathAttachmentMarkers::find(screen, *uuid) : ds::none;

      return path && PathAttachmentMarkers::cursorAt(screen, boundary.deletion == AttachmentMarkerDeletion::backward ? path->end : path->start);
    }

    [[nodiscard]] static bool markerPresent(const Slot& slot, AttachmentMarkerScreen screen) noexcept {
      if (const auto number = markerNumber(slot)) {
        return NumericAttachmentMarkers::present(screen, *number);
      }

      const auto* const path = markerPath(slot);

      return path != nullptr && PathAttachmentMarkers::find(screen, *path).hasValue();
    }

    [[nodiscard]] bool numberClaimed(AttachmentTarget target, std::uint16_t number) const noexcept {
      return std::ranges::any_of(slots_, [&](const auto& slot) {
        return slot && slot->owns(target) && markerNumber(*slot) == number;
      });
    }

    [[nodiscard]] bool pathClaimed(AttachmentTarget target, const AttachmentPathUuid& uuid) const noexcept {
      return std::ranges::any_of(slots_, [&](const auto& slot) {
        const auto* const path = slot ? markerPath(*slot) : nullptr;

        return slot && slot->owns(target) && path != nullptr && *path == uuid;
      });
    }

    [[nodiscard]] std::size_t unpaired(AttachmentTarget target, AttachmentMarkerPolicy policy) const noexcept {
      return static_cast<std::size_t>(std::ranges::count_if(slots_, [&](const auto& slot) {
        return slot && slot->owns(target) && slot->capture.request.marker_policy == policy && !slot->marker;
      }));
    }

    [[nodiscard]] ds::Option<std::uint16_t> nextNumber(AttachmentTarget target, AttachmentMarkerScreen screen) const noexcept {
      std::array<std::uint16_t, AttachmentLimits::maximum_items> candidates{};
      std::size_t count = 0;
      NumericAttachmentMarkers scan{screen};

      while (const auto marker = scan.next()) {
        const auto kept = std::span{candidates}.first(count);
        if (numberClaimed(target, marker->number) || std::ranges::find(kept, marker->number) != kept.end()) {
          continue;
        }

        auto index = count;

        if (count < candidates.size()) {
          ++count;
        } else if (marker->number <= candidates.back()) {
          continue;
        } else {
          index = candidates.size() - 1;
        }

        while (index != 0 && candidates[index - 1] < marker->number) {
          if (index < candidates.size()) {
            candidates[index] = candidates[index - 1];
          }

          --index;
        }

        candidates[index] = marker->number;
      }

      const auto needed = unpaired(target, AttachmentMarkerPolicy::stable_number);

      return needed != 0 && count >= needed ? ds::Option{candidates[needed - 1]} : ds::none;
    }

    [[nodiscard]] ds::Option<AttachmentPathUuid> nextPath(AttachmentTarget target, AttachmentMarkerScreen screen) const noexcept {
      std::array<PathAttachmentMarker, AttachmentLimits::maximum_items * 2> paths{};
      const auto count = PathAttachmentMarkers::collect(screen, paths);
      std::array<AttachmentPathUuid, paths.size()> candidates{};
      std::size_t available = 0;

      for (std::size_t index = 0; index < count; ++index) {
        if (!pathClaimed(target, paths[index].uuid)) {
          candidates[available++] = paths[index].uuid;
        }
      }

      const auto needed = unpaired(target, AttachmentMarkerPolicy::pasted_path);

      return needed != 0 && available >= needed ? ds::Option{candidates[available - needed]} : ds::none;
    }

    [[nodiscard]] Slot* findMutable(std::uint64_t id) noexcept {
      for (auto& slot : slots_) {
        if (slot && slot->capture.request.capture.id == id) {
          return &slot.getMut();
        }
      }

      return nullptr;
    }

    void learnSlot(Slot& slot, AttachmentTarget target, AttachmentMarkerScreen screen) noexcept {
      if (slot.capture.request.marker_policy == AttachmentMarkerPolicy::stable_number) {
        if (const auto number = nextNumber(target, screen)) {
          slot.marker = *number;
        }
      } else if (slot.capture.request.marker_policy == AttachmentMarkerPolicy::pasted_path) {
        if (const auto path = nextPath(target, screen)) {
          slot.marker = *path;
        }
      }
    }

    void learnMarkers(AttachmentTarget target, AttachmentMarkerScreen screen) noexcept {
      const auto visible = snapshot();

      for (std::size_t index = 0; index < visible.count; ++index) {
        auto* const slot = findMutable(visible.items[index].id);
        if (slot != nullptr && !slot->marker && slot->owns(target)) {
          learnSlot(*slot, target, screen);
        }
      }
    }

    static void validate(const AttachmentCapture<Memory>& capture) {
      if (capture.png.size() == 0 || capture.png.size() > AttachmentLimits::maximum_png_bytes || capture.width == 0 || capture.height == 0) {
        throw std::invalid_argument{"InvalidClipboardImage"};
      }

      if (static_cast<std::uint64_t>(capture.width) * capture.height > AttachmentLimits::maximum_pixels) {
        throw std::length_error{"ClipboardImageTooLarge"};
      }
    }

    [[nodiscard]] ds::Option<std::size_t> freeIndex() const noexcept {
      for (std::size_t index = 0; index < slots_.size(); ++index) {
        if (!slots_[index]) {
          return index;
        }
      }

      return ds::none;
    }

    [[nodiscard]] ds::Option<AttachmentEviction> evictionReach(std::size_t bytes) const noexcept {
      if (!freeIndex()) {
        return AttachmentEviction::items;
      }

      return bytes > AttachmentLimits::maximum_retained_bytes - total_bytes_ ? ds::Option{AttachmentEviction::retained_bytes} : ds::none;
    }

    [[nodiscard]] ds::Option<std::size_t> oldestReleasable() const noexcept {
      ds::Option<std::size_t> oldest;
      auto oldest_id = std::numeric_limits<std::uint64_t>::max();

      for (std::size_t index = 0; index < slots_.size(); ++index) {
        const auto& slot = slots_[index];
        if (slot && delivery_.canRelease(slot->delivery) && slot->capture.request.capture.id < oldest_id) {
          oldest = index;
          oldest_id = slot->capture.request.capture.id;
        }
      }

      return oldest;
    }

    void retire(std::size_t index) noexcept {
      auto& slot = slots_[index].getMut();

      delivery_.retire(slot.delivery);
      slot.retired = true;
      if (modal_ == slot.capture.request.capture.id) {
        modal_.reset();
      }
    }

    void free(std::size_t index) noexcept {
      auto& slot = slots_[index];
      if (!slot) {
        std::terminate();
      }

      total_bytes_ -= slot->capture.png.size();
      slot.reset();
    }

    Delivery& delivery_;
    std::array<ds::Option<Slot>, AttachmentLimits::maximum_items> slots_;
    ds::Option<AttachmentTarget> target_;
    ds::Option<std::uint64_t> modal_;
    ds::Option<PendingDeletion> deletion_pending_;
    std::size_t total_bytes_ = 0;
    std::uint64_t ingress_version_ = 0;
  };

}
