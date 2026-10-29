#pragma once

#include "link_grid.hpp"
#include "link_match.hpp"
#include "link_target.hpp"
#include "link_text.hpp"
#include "markdown_links.hpp"
#include "path_recognizer.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "uri_recognizer.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

class CellLinks {
public:
  static constexpr std::size_t window_bytes = (LinkText::maximum_span_bytes * 2) + (CellValue::text_capacity * 2);
  static constexpr std::size_t maximum_walk_cells = window_bytes * 2;

  template <Allocator Memory>
  [[nodiscard]] static std::optional<LinkMatch> text(const Screen<Memory> &screen, CellPosition point) {
    return match({.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = {}}, point);
  }

  template <Allocator Memory>
  [[nodiscard]] static std::optional<LinkMatch> resolve(const Screen<Memory> &screen, CellPosition point) {
    const LinkGrid grid{.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = screen.rowFlags()};
    const auto index = grid.cellIndex(point);
    if (!index) {
      return {};
    }

    if (const auto *run = screen.linkRunAt(static_cast<std::uint32_t>(*index))) {
      const auto target = LinkTarget::fromUri(screen.linkAt(static_cast<std::uint32_t>(*index)));
      if (!target) {
        return {};
      }

      return LinkMatch{.target = *target, .start = grid.position(run->start), .end = grid.cellEnd(run->start + run->len - 1), .metadata_index = run->link_index};
    }

    if (screen.metadataStatus() != MetadataStatus::complete && (screen.rowFlags(*index / screen.columns()) & static_cast<Byte>(RowFlag::hyperlinks)) != 0) {
      return {};
    }

    return match(grid, point);
  }

  [[nodiscard]] static std::optional<LinkMatch> match(const LinkGrid &grid, CellPosition point) {
    const auto cursor = grid.cellIndex(point);
    if (!cursor) {
      return {};
    }

    const auto first = windowStart(grid, *cursor);
    if (!first) {
      return {};
    }

    std::array<char, window_bytes> storage{};
    const auto window = readWindow(grid, *first, *cursor, storage);
    if (!window) {
      return {};
    }

    const auto bytes = std::string_view{storage.data(), window->length};
    auto found = MarkdownLinks::extract(bytes, window->cursor);
    if (!found) {
      found = UriRecognizer::extract(bytes, window->cursor);
    }

    if (!found) {
      found = PathRecognizer::extract(bytes, window->cursor);
    }

    if (!found) {
      return {};
    }

    const auto extent = positions(grid, *first, found->extent);
    if (!extent || !grid.complete(extent->first, extent->second)) {
      return {};
    }

    const auto destination = found->destination.view(bytes);
    const auto target = found->scheme == LinkScheme::path ? LinkTarget::fromPath(destination) : LinkTarget::fromUri(destination);

    return target ? std::optional{LinkMatch{.target = *target, .start = extent->first, .end = extent->second}} : std::nullopt;
  }

private:
  struct Window {
    std::size_t length = 0;
    std::size_t cursor = 0;
  };

  [[nodiscard]] static std::optional<std::size_t> windowStart(const LinkGrid &grid, std::size_t index) noexcept {
    std::size_t visited = 0;
    std::size_t bytes = 0;
    while (bytes <= LinkText::maximum_span_bytes) {
      if (visited++ == maximum_walk_cells) {
        return {};
      }

      const auto previous = grid.previous(index);
      if (!previous) {
        break;
      }

      index = *previous;
      bytes += grid.cells[index].utf8().size();
    }

    return index;
  }

  [[nodiscard]] static std::optional<Window> readWindow(const LinkGrid &grid, std::size_t index, std::size_t cursor, std::span<char> storage) noexcept {
    std::size_t visited = 0;
    std::size_t length = 0;
    std::optional<std::size_t> cursor_offset;
    while (true) {
      if (visited++ == maximum_walk_cells) {
        return {};
      }

      if (index == cursor) {
        cursor_offset = length;
      }

      const auto text = grid.cells[index].utf8();
      if (text.size() > storage.size() - length) {
        break;
      }

      std::ranges::copy(text, storage.subspan(length).begin());
      length += text.size();
      if (cursor_offset && length - *cursor_offset >= LinkText::maximum_span_bytes + CellValue::text_capacity) {
        break;
      }

      const auto next = grid.next(index);
      if (!next) {
        break;
      }

      index = *next;
    }

    return cursor_offset ? std::optional{Window{.length = length, .cursor = *cursor_offset}} : std::nullopt;
  }

  [[nodiscard]] static std::optional<std::pair<CellPosition, CellPosition>> positions(const LinkGrid &grid, std::size_t index, TextRange extent) noexcept {
    std::size_t offset = 0;
    std::optional<CellPosition> first;
    while (true) {
      const auto end = offset + grid.cells[index].utf8().size();
      if (!first && offset <= extent.start && end > extent.start) {
        first = grid.position(index);
      }

      if (end >= extent.end) {
        return first ? std::optional{std::pair{*first, grid.cellEnd(index)}} : std::nullopt;
      }

      offset = end;
      const auto next = grid.next(index);
      if (!next) {
        return {};
      }

      index = *next;
    }
  }
};

}
