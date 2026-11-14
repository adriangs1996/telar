module telar.gui.attachments.catalog;

import telar.base.memory.allocators;

namespace telar::gui {

  template <Allocator Memory>
  AttachmentMarkerScreen AttachmentMarkerScreen::from(const Screen<Memory>& screen) noexcept {
    return {.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .cursor = screen.cursor()};
  }

  const CellValue* AttachmentMarkerScreen::cell(CellPosition point) const noexcept {
    if (point.x >= columns || point.y >= rows) {
      return nullptr;
    }

    const auto index = (static_cast<std::size_t>(point.y) * columns) + point.x;

    return index < cells.size() ? &cells[index] : nullptr;
  }

  bool AttachmentMarkerScreen::matches(CellPosition point, std::string_view literal) const noexcept {
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

  bool AttachmentMarkerScreen::blank(const CellValue& cell) noexcept {
    return cell.width == CellWidth::continuation || cell.utf8() == " ";
  }

  bool AttachmentMarkerScreen::isolatedInverse(CellPosition point) const noexcept {
    const auto* const value = cell(point);
    if (value == nullptr || !inverse(*value)) {
      return false;
    }

    const auto* const left = point.x != 0 ? cell({.x = static_cast<std::uint16_t>(point.x - 1), .y = point.y}) : nullptr;
    const auto* const right = cell({.x = static_cast<std::uint16_t>(point.x + 1), .y = point.y});

    return (left == nullptr || !inverse(*left)) && (right == nullptr || !inverse(*right));
  }

  std::optional<CellPosition> AttachmentMarkerScreen::editorCursor() const noexcept {
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

  bool AttachmentMarkerScreen::promptContinues() const noexcept {
    const auto point = editorCursor();

    return point && point->x != 0 && matches({.x = static_cast<std::uint16_t>(point->x - 1), .y = point->y}, "\\");
  }

  bool AttachmentMarkerScreen::inverse(const CellValue& cell) noexcept {
    return (cell.style.flags & static_cast<std::uint16_t>(CellAttribute::inverse)) != 0;
  }

  NumericAttachmentMarkers::NumericAttachmentMarkers(AttachmentMarkerScreen screen) noexcept
      : screen_(screen) {}

  std::optional<NumericAttachmentMarker> NumericAttachmentMarkers::next() noexcept {
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

  std::optional<NumericAttachmentMarker> NumericAttachmentMarkers::parse(AttachmentMarkerScreen screen, CellPosition point) noexcept {
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

  std::optional<NumericAttachmentMarker> NumericAttachmentMarkers::closest(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
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

  bool NumericAttachmentMarkers::present(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
    NumericAttachmentMarkers scan{screen};

    while (const auto marker = scan.next()) {
      if (marker->number == number) {
        return true;
      }
    }

    return false;
  }

  std::optional<std::uint16_t> NumericAttachmentMarkers::steps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
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

  std::optional<NumericAttachmentMarker> NumericAttachmentMarkers::tail(AttachmentMarkerScreen screen, CellPosition start, CellPosition point) noexcept {
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

  bool NumericAttachmentMarkers::blankTail(AttachmentMarkerScreen screen, CellPosition point) noexcept {
    for (auto column = point.x; column < screen.columns; ++column) {
      const auto* const cell = screen.cell({.x = column, .y = point.y});
      if (cell == nullptr || !AttachmentMarkerScreen::blank(*cell)) {
        return false;
      }
    }

    return true;
  }

  std::optional<CellPosition> NumericAttachmentMarkers::firstInk(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
    for (std::uint16_t column = 0; column < screen.columns; ++column) {
      const auto* const cell = screen.cell({.x = column, .y = row});
      if (cell != nullptr && !AttachmentMarkerScreen::blank(*cell)) {
        return CellPosition{.x = column, .y = row};
      }
    }

    return std::nullopt;
  }

  std::optional<PathAttachmentMarker> PathAttachmentMarkers::find(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept {
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

  std::size_t PathAttachmentMarkers::collect(AttachmentMarkerScreen screen, std::span<PathAttachmentMarker> output) noexcept {
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

  std::optional<std::uint16_t> PathAttachmentMarkers::cursorOnRow(AttachmentMarkerScreen screen, std::uint16_t row) noexcept {
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

  bool PathAttachmentMarkers::cursorAt(AttachmentMarkerScreen screen, CellPosition point) noexcept {
    return screen.cursor.visible ? screen.cursor.x == point.x && screen.cursor.y == point.y : screen.isolatedInverse(point);
  }

  bool PathAttachmentMarkers::single(const CellValue& cell) noexcept {
    return cell.width == CellWidth::single && cell.length == 1;
  }

  bool PathAttachmentMarkers::blank(const CellValue& cell) noexcept {
    return cell.length == 0 || cell.utf8() == " ";
  }

  bool PathAttachmentMarkers::hex(std::uint8_t byte) noexcept {
    return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
  }

  bool PathAttachmentMarkers::alphanumeric(std::uint8_t byte) noexcept {
    return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }

  std::optional<CellPosition> PathAttachmentMarkers::matchExtension(Scan scan) noexcept {
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

  std::optional<PathAttachmentMarker> PathAttachmentMarkers::parseHead(AttachmentMarkerScreen screen, CellPosition start) noexcept {
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

  bool PathAttachmentMarkers::rowForceWrapped(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
    if (screen.columns < 2) {
      return false;
    }

    const auto* const last = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 2), .y = row});
    const auto* const reserved = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 1), .y = row});

    return last != nullptr && reserved != nullptr && !blank(*last) && blank(*reserved);
  }

  CellPosition PathAttachmentMarkers::pathStart(AttachmentMarkerScreen screen, CellPosition marker) noexcept {
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

  std::optional<std::uint16_t> PathAttachmentMarkers::countCells(AttachmentMarkerScreen screen, CellPosition start, CellPosition end) noexcept {
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

  PathAttachmentMarker PathAttachmentMarkers::extend(AttachmentMarkerScreen screen, PathAttachmentMarker head) noexcept {
    head.start = pathStart(screen, head.start);
    head.cells = countCells(screen, head.start, head.end);

    return head;
  }

  PathAttachmentMarkers::Scan::Scan(AttachmentMarkerScreen screen, CellPosition point) noexcept
      : screen_(screen),
        point_(point) {}

  std::optional<CellPosition> PathAttachmentMarkers::Scan::position() noexcept {
    if (screen_.columns < 2) {
      return std::nullopt;
    }

    if (point_.x >= screen_.columns - 1) {
      point_.x = 0;
      ++point_.y;
    }

    return point_.y < screen_.rows ? std::optional{point_} : std::nullopt;
  }

  CellPosition PathAttachmentMarkers::Scan::rawPosition() const noexcept {
    return point_;
  }

  void PathAttachmentMarkers::Scan::step() noexcept {
    ++point_.x;
  }

  bool PathAttachmentMarkers::Scan::expect(std::uint8_t byte) noexcept {
    const auto point = position();
    const auto* const cell = point ? screen_.cell(*point) : nullptr;
    if (cell == nullptr || !single(*cell) || cell->text[0] != byte) {
      return false;
    }

    step();

    return true;
  }

  std::uint32_t AttachmentMarkerRemoval::keyCount() const noexcept {
    return (static_cast<std::uint32_t>(steps) * 2) + deletions;
  }

  AttachmentMarkerPlan AttachmentMarkerPlanning::placeholder(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
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

  AttachmentMarkerPlan AttachmentMarkerPlanning::path(AttachmentMarkerScreen screen, const AttachmentPathUuid& uuid) noexcept {
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

  std::optional<std::uint16_t> AttachmentMarkerPlanning::plainSteps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
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

  template AttachmentMarkerScreen AttachmentMarkerScreen::from<telar::Memory>(const Screen<telar::Memory>& screen) noexcept;
  template AttachmentMarkerScreen AttachmentMarkerScreen::from<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen) noexcept;

}
