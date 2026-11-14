module;
#include "attachments/capture.hpp"
#include <cassert>

export module telar.gui.attachments.catalog;

import std;
import telar.gui.terminal.screen;
import telar.wire.vocabulary;

// The capture types stay textual because the Objective-C++ clipboard source
// shares them; importers reach their names through these declarations instead
// of including them. Markers and the catalog are module code: they read the
// terminal screen and cells through their owner modules.
export namespace telar::gui {
  using telar::gui::AttachmentCapture;
  using telar::gui::AttachmentLimits;
  using telar::gui::AttachmentMarkerPolicy;
  using telar::gui::AttachmentTarget;
  using telar::gui::ClipboardCapture;
  using telar::gui::ClipboardCaptureRequest;
  using telar::gui::eraseSensitiveBytes;
  using telar::gui::SensitiveBytes;
}

export namespace telar::gui {

  struct AttachmentMarkerScreen {
    std::span<const CellValue> cells;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    Cursor cursor;

    template <Allocator Memory>
    [[nodiscard]] static AttachmentMarkerScreen from(const Screen<Memory>& screen) noexcept {
      return {.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .cursor = screen.cursor()};
    }

    [[nodiscard]] const CellValue* cell(CellPosition point) const noexcept {
      if (point.x >= columns || point.y >= rows) {
        return nullptr;
      }

      const auto index = (static_cast<std::size_t>(point.y) * columns) + point.x;

      return index < cells.size() ? &cells[index] : nullptr;
    }

    [[nodiscard]] bool matches(CellPosition point, std::string_view literal) const noexcept {
      if (point.y >= rows || point.x > columns || literal.size() > columns - point.x) {
        return false;
      }

      for (std::size_t offset = 0; offset < literal.size(); ++offset) {
        const auto* const value = cell({.x = static_cast<std::uint16_t>(point.x + offset), .y = point.y});
        if (value == nullptr || value->width == CellWidth::continuation || value->length != 1 || value->text[0] != static_cast<std::uint8_t>(literal[offset])) {
          return false;
        }
      }

      return true;
    }

    [[nodiscard]] static bool blank(const CellValue& cell) noexcept {
      return cell.width == CellWidth::continuation || cell.utf8() == " ";
    }

    [[nodiscard]] bool isolatedInverse(CellPosition point) const noexcept {
      const auto* const value = cell(point);
      if (value == nullptr || !inverse(*value)) {
        return false;
      }

      const auto* const left = point.x != 0 ? cell({.x = static_cast<std::uint16_t>(point.x - 1), .y = point.y}) : nullptr;
      const auto* const right = cell({.x = static_cast<std::uint16_t>(point.x + 1), .y = point.y});

      return (left == nullptr || !inverse(*left)) && (right == nullptr || !inverse(*right));
    }

    [[nodiscard]] std::optional<CellPosition> editorCursor() const noexcept {
      if (cursor.visible) {
        return CellPosition{.x = cursor.x, .y = cursor.y};
      }

      for (std::uint32_t row = 0; row < rows; ++row) {
        for (std::uint16_t column = 0; column < columns; ++column) {
          const CellPosition point{.x = column, .y = row};
          if (isolatedInverse(point)) {
            return point;
          }
        }
      }

      return std::nullopt;
    }

    [[nodiscard]] bool promptContinues() const noexcept {
      const auto point = editorCursor();

      return point && point->x != 0 && matches({.x = static_cast<std::uint16_t>(point->x - 1), .y = point->y}, "\\");
    }

  private:
    [[nodiscard]] static bool inverse(const CellValue& cell) noexcept {
      return (cell.style.flags & static_cast<std::uint16_t>(CellAttribute::inverse)) != 0;
    }
  };

  struct NumericAttachmentMarker {
    std::uint16_t number = 0;
    CellPosition start;
    CellPosition end;
  };

  class NumericAttachmentMarkers {
  public:
    explicit NumericAttachmentMarkers(AttachmentMarkerScreen screen) noexcept
        : screen_(screen) {}

    [[nodiscard]] std::optional<NumericAttachmentMarker> next() noexcept {
      while (position_.y < screen_.rows && static_cast<std::uint32_t>(position_.x) + head.size() <= screen_.columns) {
        const auto point = position_;

        if (static_cast<std::uint32_t>(position_.x) + head.size() < screen_.columns) {
          ++position_.x;
        } else {
          position_.x = 0;
          ++position_.y;
        }

        if (const auto marker = parse(screen_, point)) {
          return marker;
        }
      }

      return std::nullopt;
    }

    [[nodiscard]] static std::optional<NumericAttachmentMarker> parse(AttachmentMarkerScreen screen, CellPosition point) noexcept {
      if (!screen.matches(point, head)) {
        return std::nullopt;
      }

      const CellPosition after_head{.x = static_cast<std::uint16_t>(point.x + head.size()), .y = point.y};
      if (screen.matches(after_head, separator)) {
        return tail(screen, point, {.x = static_cast<std::uint16_t>(after_head.x + separator.size()), .y = point.y});
      }

      if (point.y + 1 >= screen.rows || !blankTail(screen, after_head)) {
        return std::nullopt;
      }

      const auto first = firstInk(screen, point.y + 1);
      if (!first || !screen.matches(*first, "#")) {
        return std::nullopt;
      }

      return tail(screen, point, {.x = static_cast<std::uint16_t>(first->x + 1), .y = first->y});
    }

    [[nodiscard]] static std::optional<NumericAttachmentMarker> closest(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
      NumericAttachmentMarkers scan{screen};
      std::optional<NumericAttachmentMarker> best;
      auto best_distance = std::numeric_limits<std::uint32_t>::max();

      while (const auto candidate = scan.next()) {
        if (candidate->number != number) {
          continue;
        }

        const auto row_distance = candidate->end.y > screen.cursor.y ? candidate->end.y - screen.cursor.y : screen.cursor.y - candidate->end.y;
        const auto column_distance = candidate->end.x > screen.cursor.x ? candidate->end.x - screen.cursor.x : screen.cursor.x - candidate->end.x;
        const auto distance = (row_distance * (static_cast<std::uint32_t>(screen.columns) + 1)) + static_cast<std::uint32_t>(column_distance);
        if (distance < best_distance) {
          best = candidate;
          best_distance = distance;
        }
      }

      return best;
    }

    [[nodiscard]] static bool present(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
      NumericAttachmentMarkers scan{screen};

      while (const auto marker = scan.next()) {
        if (marker->number == number) {
          return true;
        }
      }

      return false;
    }

    [[nodiscard]] static std::optional<std::uint16_t> steps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
      if (first > last || last > screen.columns || row >= screen.rows) {
        return std::nullopt;
      }

      std::uint16_t count = 0;
      auto column = first;

      while (column < last) {
        const auto marker = parse(screen, {.x = column, .y = row});
        if (marker && marker->start.y == marker->end.y && marker->end.x <= last) {
          ++count;
          column = marker->end.x;
        } else {
          const auto* const value = screen.cell({.x = column, .y = row});

          count = static_cast<std::uint16_t>(count + (value != nullptr && value->width != CellWidth::continuation ? 1 : 0));
          ++column;
        }
      }

      return count;
    }

  private:
    static constexpr std::string_view head = "[Image";
    static constexpr std::string_view separator = " #";
    static constexpr std::uint16_t decimal_base = 10;

    [[nodiscard]] static std::optional<NumericAttachmentMarker> tail(AttachmentMarkerScreen screen, CellPosition start, CellPosition point) noexcept {
      std::uint16_t number = 0;

      for (auto column = point.x; column < screen.columns; ++column) {
        const auto* const cell = screen.cell({.x = column, .y = point.y});
        if (cell == nullptr || cell->width == CellWidth::continuation || cell->length != 1) {
          return std::nullopt;
        }

        const auto byte = cell->text[0];
        if (byte == ']') {
          return column != point.x && number != 0 ? std::optional{NumericAttachmentMarker{.number = number, .start = start, .end = {.x = static_cast<std::uint16_t>(column + 1), .y = point.y}}} : std::nullopt;
        }

        if (byte < '0' || byte > '9' || number > (std::numeric_limits<std::uint16_t>::max() - (byte - '0')) / decimal_base) {
          return std::nullopt;
        }

        number = static_cast<std::uint16_t>((number * decimal_base) + byte - '0');
      }

      return std::nullopt;
    }

    [[nodiscard]] static bool blankTail(AttachmentMarkerScreen screen, CellPosition point) noexcept {
      for (auto column = point.x; column < screen.columns; ++column) {
        const auto* const cell = screen.cell({.x = column, .y = point.y});
        if (cell == nullptr || !AttachmentMarkerScreen::blank(*cell)) {
          return false;
        }
      }

      return true;
    }

    [[nodiscard]] static std::optional<CellPosition> firstInk(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
      for (std::uint16_t column = 0; column < screen.columns; ++column) {
        const auto* const cell = screen.cell({.x = column, .y = row});
        if (cell != nullptr && !AttachmentMarkerScreen::blank(*cell)) {
          return CellPosition{.x = column, .y = row};
        }
      }

      return std::nullopt;
    }

    AttachmentMarkerScreen screen_;
    CellPosition position_;
  };

  inline constexpr std::size_t attachment_uuid_bytes = 36;
  using AttachmentPathUuid = std::array<std::uint8_t, attachment_uuid_bytes>;

  struct PathAttachmentMarker {
    AttachmentPathUuid uuid{};
    CellPosition start;
    CellPosition end;
    std::optional<std::uint16_t> cells;
  };

  class PathAttachmentMarkers {
  public:
    static constexpr std::uint16_t maximum_cells = 512;

    [[nodiscard]] static std::optional<PathAttachmentMarker> find(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept {
      Scan scan{screen};

      while (const auto point = scan.position()) {
        const auto head = parseHead(screen, *point);
        if (head && head->uuid == uuid) {
          return extend(screen, *head);
        }

        scan.step();
      }

      return std::nullopt;
    }

    [[nodiscard]] static std::size_t collect(AttachmentMarkerScreen screen, std::span<PathAttachmentMarker> output) noexcept {
      if (output.empty()) {
        return 0;
      }

      std::size_t count = 0;
      Scan scan{screen};

      while (const auto point = scan.position()) {
        const auto head = parseHead(screen, *point);

        scan.step();
        if (!head || std::ranges::any_of(output.first(count), [&](const auto& known) {
              return known.uuid == head->uuid;
            })) {
          continue;
        }

        if (count == output.size()) {
          std::move(output.begin() + 1, output.begin() + static_cast<std::ptrdiff_t>(count), output.begin());
          --count;
        }

        output[count++] = extend(screen, *head);
      }

      return count;
    }

    [[nodiscard]] static std::optional<std::uint16_t> cursorOnRow(AttachmentMarkerScreen screen, std::uint16_t row) noexcept {
      if (screen.cursor.visible) {
        return screen.cursor.y == row ? std::optional{screen.cursor.x} : std::nullopt;
      }

      for (std::uint16_t column = 0; column < screen.columns; ++column) {
        if (screen.isolatedInverse({.x = column, .y = row})) {
          return column;
        }
      }

      return std::nullopt;
    }

    [[nodiscard]] static bool cursorAt(AttachmentMarkerScreen screen, CellPosition point) noexcept {
      return screen.cursor.visible ? screen.cursor.x == point.x && screen.cursor.y == point.y : screen.isolatedInverse(point);
    }

  private:
    static constexpr std::string_view prefix = "pi-clipboard-";
    static constexpr std::array<std::string_view, 4> extensions{"png", "jpg", "webp", "gif"};
    static constexpr std::array<std::size_t, 4> dash_positions{8, 13, 18, 23};

    class Scan {
    public:
      explicit Scan(AttachmentMarkerScreen screen, CellPosition point = {}) noexcept
          : screen_(screen),
            point_(point) {}

      [[nodiscard]] std::optional<CellPosition> position() noexcept {
        if (screen_.columns < 2) {
          return std::nullopt;
        }

        if (point_.x >= screen_.columns - 1) {
          point_.x = 0;
          ++point_.y;
        }

        return point_.y < screen_.rows ? std::optional{point_} : std::nullopt;
      }

      [[nodiscard]] CellPosition rawPosition() const noexcept {
        return point_;
      }

      void step() noexcept {
        ++point_.x;
      }

      [[nodiscard]] bool expect(std::uint8_t byte) noexcept {
        const auto point = position();
        const auto* const cell = point ? screen_.cell(*point) : nullptr;
        if (cell == nullptr || !single(*cell) || cell->text[0] != byte) {
          return false;
        }

        step();

        return true;
      }

    private:
      AttachmentMarkerScreen screen_;
      CellPosition point_;
    };

    [[nodiscard]] static bool single(const CellValue& cell) noexcept {
      return cell.width == CellWidth::single && cell.length == 1;
    }

    [[nodiscard]] static bool blank(const CellValue& cell) noexcept {
      return cell.length == 0 || cell.utf8() == " ";
    }

    [[nodiscard]] static bool hex(std::uint8_t byte) noexcept {
      return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
    }

    [[nodiscard]] static bool alphanumeric(std::uint8_t byte) noexcept {
      return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
    }

    [[nodiscard]] static std::optional<CellPosition> matchExtension(Scan scan) noexcept {
      for (const auto extension : extensions) {
        auto attempt = scan;
        bool matched = true;

        for (const auto byte : extension) {
          matched = matched && attempt.expect(static_cast<std::uint8_t>(byte));
        }

        if (matched) {
          return attempt.rawPosition();
        }
      }

      return std::nullopt;
    }

    [[nodiscard]] static std::optional<PathAttachmentMarker> parseHead(AttachmentMarkerScreen screen, CellPosition start) noexcept {
      if (start.y >= screen.rows || start.x >= screen.columns || screen.columns < 2) {
        return std::nullopt;
      }

      Scan scan{screen, start};

      for (const auto byte : prefix) {
        if (!scan.expect(static_cast<std::uint8_t>(byte))) {
          return std::nullopt;
        }
      }

      AttachmentPathUuid uuid{};

      for (std::size_t index = 0; index < uuid.size(); ++index) {
        const auto point = scan.position();
        const auto* const cell = point ? screen.cell(*point) : nullptr;
        if (cell == nullptr || !single(*cell)) {
          return std::nullopt;
        }

        const auto byte = cell->text[0];
        const bool dash = std::ranges::find(dash_positions, index) != dash_positions.end();
        if ((dash && byte != '-') || (!dash && !hex(byte))) {
          return std::nullopt;
        }

        uuid[index] = byte;
        scan.step();
      }

      if (!scan.expect('.')) {
        return std::nullopt;
      }

      const auto end = matchExtension(scan);
      if (!end) {
        return std::nullopt;
      }

      if (end->x < screen.columns - 1) {
        const auto* const following = screen.cell(*end);
        if (following != nullptr && single(*following) && alphanumeric(following->text[0])) {
          return std::nullopt;
        }
      }

      return PathAttachmentMarker{.uuid = uuid, .start = start, .end = *end, .cells = std::nullopt};
    }

    [[nodiscard]] static bool rowForceWrapped(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
      if (screen.columns < 2) {
        return false;
      }

      const auto* const last = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 2), .y = row});
      const auto* const reserved = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 1), .y = row});

      return last != nullptr && reserved != nullptr && !blank(*last) && blank(*reserved);
    }

    [[nodiscard]] static CellPosition pathStart(AttachmentMarkerScreen screen, CellPosition marker) noexcept {
      auto point = marker;
      std::optional<CellPosition> slash;

      for (;;) {
        if (point.x == 0) {
          if (point.y == 0 || !rowForceWrapped(screen, point.y - 1)) {
            break;
          }

          --point.y;
          point.x = static_cast<std::uint16_t>(screen.columns - 1);
          continue;
        }

        const auto* const previous = screen.cell({.x = static_cast<std::uint16_t>(point.x - 1), .y = point.y});
        if (previous == nullptr) {
          break;
        }

        if (previous->width == CellWidth::continuation) {
          --point.x;
          continue;
        }

        if (blank(*previous)) {
          break;
        }

        --point.x;
        if (single(*previous) && previous->text[0] == '/') {
          slash = point;
        }
      }

      return slash.value_or(marker);
    }

    [[nodiscard]] static std::optional<std::uint16_t> countCells(AttachmentMarkerScreen screen, CellPosition start, CellPosition end) noexcept {
      if (screen.columns < 2 || start.y >= screen.rows || start.x >= screen.columns) {
        return std::nullopt;
      }

      Scan scan{screen, start};
      std::uint16_t count = 0;

      for (;;) {
        if (scan.rawPosition() == end) {
          return count;
        }

        const auto point = scan.position();
        const auto* const value = point ? screen.cell(*point) : nullptr;
        if (value == nullptr) {
          return std::nullopt;
        }

        count = static_cast<std::uint16_t>(count + (value->width != CellWidth::continuation ? 1 : 0));
        if (count > maximum_cells) {
          return std::nullopt;
        }

        scan.step();
      }
    }

    [[nodiscard]] static PathAttachmentMarker extend(AttachmentMarkerScreen screen, PathAttachmentMarker head) noexcept {
      head.start = pathStart(screen, head.start);
      head.cells = countCells(screen, head.start, head.end);

      return head;
    }
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

    [[nodiscard]] std::uint32_t keyCount() const noexcept {
      return (static_cast<std::uint32_t>(steps) * 2) + deletions;
    }
  };

  struct AttachmentMarkerPlan {
    std::optional<AttachmentMarkerRemoval> removal;
    std::optional<AttachmentMarkerReach> limit;
    std::optional<std::uint32_t> requested;
  };

  class AttachmentMarkerPlanning {
  public:
    [[nodiscard]] static AttachmentMarkerPlan placeholder(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
      if (!screen.cursor.visible) {
        return {};
      }

      const auto marker = NumericAttachmentMarkers::closest(screen, number);
      if (!marker) {
        return {};
      }

      std::optional<AttachmentMarkerRemoval> removal;

      if (screen.cursor.y == marker->end.y && screen.cursor.x >= marker->end.x) {
        const auto steps = NumericAttachmentMarkers::steps(screen, static_cast<std::uint16_t>(marker->end.y), marker->end.x, screen.cursor.x);
        if (steps) {
          removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::left, .steps = *steps, .deletion = AttachmentMarkerDeletion::backward};
        }
      } else if (screen.cursor.y == marker->start.y && screen.cursor.x <= marker->start.x) {
        const auto steps = NumericAttachmentMarkers::steps(screen, static_cast<std::uint16_t>(marker->start.y), screen.cursor.x, marker->start.x);
        if (steps) {
          removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::right, .steps = *steps, .deletion = AttachmentMarkerDeletion::forward};
        }
      }

      if (removal && removal->steps > AttachmentLimits::maximum_marker_navigation_steps) {
        return {.removal = std::nullopt, .limit = AttachmentMarkerReach::navigation, .requested = removal->steps};
      }

      return {.removal = removal, .limit = std::nullopt, .requested = std::nullopt};
    }

    [[nodiscard]] static AttachmentMarkerPlan path(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept {
      const auto marker = PathAttachmentMarkers::find(screen, uuid);
      if (!marker) {
        return {};
      }

      if (!marker->cells) {
        return {.removal = std::nullopt, .limit = AttachmentMarkerReach::path_cells, .requested = std::nullopt};
      }

      if (const auto cursor = PathAttachmentMarkers::cursorOnRow(screen, static_cast<std::uint16_t>(marker->end.y)); cursor && *cursor >= marker->end.x) {
        const auto steps = plainSteps(screen, static_cast<std::uint16_t>(marker->end.y), marker->end.x, *cursor);
        if (steps) {
          return {.removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::left, .steps = *steps, .deletion = AttachmentMarkerDeletion::backward, .deletions = *marker->cells}, .limit = std::nullopt, .requested = std::nullopt};
        }
      }

      if (const auto cursor = PathAttachmentMarkers::cursorOnRow(screen, static_cast<std::uint16_t>(marker->start.y)); cursor && *cursor <= marker->start.x) {
        const auto steps = plainSteps(screen, static_cast<std::uint16_t>(marker->start.y), *cursor, marker->start.x);
        if (steps) {
          return {.removal = AttachmentMarkerRemoval{.direction = AttachmentMarkerDirection::right, .steps = *steps, .deletion = AttachmentMarkerDeletion::forward, .deletions = *marker->cells}, .limit = std::nullopt, .requested = std::nullopt};
        }
      }

      return {};
    }

  private:
    [[nodiscard]] static std::optional<std::uint16_t> plainSteps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
      if (first > last || last > screen.columns || row >= screen.rows) {
        return std::nullopt;
      }

      std::uint16_t count = 0;

      for (auto column = first; column < last; ++column) {
        const auto* const value = screen.cell({.x = column, .y = row});

        count = static_cast<std::uint16_t>(count + (value != nullptr && value->width != CellWidth::continuation ? 1 : 0));
      }

      return count;
    }
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
    std::optional<std::uint64_t> modal;
  };

  // Delivery owns presentation resources. A retired slot remains charged until
  // its last render lease is released; eviction may only reuse releasable slots.
  template <Allocator Memory, typename Delivery>
  class AttachmentCatalog {
  public:
    struct Slot {
      AttachmentCapture<Memory> capture;
      Delivery::SlotState delivery;
      bool retired = false;
      std::optional<std::variant<std::uint16_t, AttachmentPathUuid>> marker = std::nullopt;

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
        assert(!slot || delivery_.canRelease(slot->delivery));
      }
    }

    [[nodiscard]] std::size_t retainedBytes() const noexcept {
      return total_bytes_;
    }

    [[nodiscard]] std::uint64_t ingressVersion() const noexcept {
      return ingress_version_;
    }

    [[nodiscard]] const std::optional<AttachmentTarget>& target() const noexcept {
      return target_;
    }

    bool setTarget(std::optional<AttachmentTarget> target) noexcept {
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

    [[nodiscard]] std::optional<AttachmentEviction> adopt(AttachmentCapture<Memory>& capture) {
      validate(capture);
      std::optional<AttachmentEviction> evicted;

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

        delivery_.retire(slot->delivery);
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
          const auto number = markerNumber(*slot).value_or(static_cast<std::uint16_t>(index + 1));

          plan = AttachmentMarkerPlanning::placeholder(screen, number);
        }

        if (plan.removal && plan.removal->keyCount() > AttachmentLimits::maximum_removal_keys) {
          return {.removal = std::nullopt, .limit = AttachmentMarkerReach::keys, .requested = plan.removal->keyCount()};
        }

        return plan;
      }

      return {};
    }

    [[nodiscard]] std::optional<std::uint64_t> markerAtDeletion(AttachmentMarkerScreen screen, AttachmentMarkerDeletion deletion) const noexcept {
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

      return std::nullopt;
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
        --deletion_pending_->frames;
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
      return std::exchange(modal_, std::nullopt).has_value();
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

    [[nodiscard]] static std::optional<std::uint16_t> markerNumber(const Slot& slot) noexcept {
      const auto* const value = slot.marker ? std::get_if<std::uint16_t>(&*slot.marker) : nullptr;

      return value != nullptr ? std::optional{*value} : std::nullopt;
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
        return numericTouches(screen, markerNumber(slot).value_or(boundary.ordinal), boundary.deletion);
      }

      const auto* const uuid = markerPath(slot);
      const auto path = uuid != nullptr ? PathAttachmentMarkers::find(screen, *uuid) : std::nullopt;

      return path && PathAttachmentMarkers::cursorAt(screen, boundary.deletion == AttachmentMarkerDeletion::backward ? path->end : path->start);
    }

    [[nodiscard]] static bool markerPresent(const Slot& slot, AttachmentMarkerScreen screen) noexcept {
      if (const auto number = markerNumber(slot)) {
        return NumericAttachmentMarkers::present(screen, *number);
      }

      const auto* const path = markerPath(slot);

      return path != nullptr && PathAttachmentMarkers::find(screen, *path).has_value();
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

    [[nodiscard]] std::optional<std::uint16_t> nextNumber(AttachmentTarget target, AttachmentMarkerScreen screen) const noexcept {
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

      return needed != 0 && count >= needed ? std::optional{candidates[needed - 1]} : std::nullopt;
    }

    [[nodiscard]] std::optional<AttachmentPathUuid> nextPath(AttachmentTarget target, AttachmentMarkerScreen screen) const noexcept {
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

      return needed != 0 && available >= needed ? std::optional{candidates[available - needed]} : std::nullopt;
    }

    [[nodiscard]] Slot* findMutable(std::uint64_t id) noexcept {
      for (auto& slot : slots_) {
        if (slot && slot->capture.request.capture.id == id) {
          return &*slot;
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

    [[nodiscard]] std::optional<std::size_t> freeIndex() const noexcept {
      for (std::size_t index = 0; index < slots_.size(); ++index) {
        if (!slots_[index]) {
          return index;
        }
      }

      return std::nullopt;
    }

    [[nodiscard]] std::optional<AttachmentEviction> evictionReach(std::size_t bytes) const noexcept {
      if (!freeIndex()) {
        return AttachmentEviction::items;
      }

      return bytes > AttachmentLimits::maximum_retained_bytes - total_bytes_ ? std::optional{AttachmentEviction::retained_bytes} : std::nullopt;
    }

    [[nodiscard]] std::optional<std::size_t> oldestReleasable() const noexcept {
      std::optional<std::size_t> oldest;
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
      auto& slot = *slots_[index];

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
    std::array<std::optional<Slot>, AttachmentLimits::maximum_items> slots_;
    std::optional<AttachmentTarget> target_;
    std::optional<std::uint64_t> modal_;
    std::optional<PendingDeletion> deletion_pending_;
    std::size_t total_bytes_ = 0;
    std::uint64_t ingress_version_ = 0;
  };

}
