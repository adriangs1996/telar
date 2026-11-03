#pragma once

#include "cell_layout.hpp"
#include "ghostty_handle.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_frame.hpp"

namespace telar::runtime {

template <Allocator Memory>
class TextMetadataCapture {
public:
  explicit TextMetadataCapture(Memory &memory)
      : links_(AllocatorRef<MetadataLink, Memory>{memory}),
        runs_(AllocatorRef<MetadataRun, Memory>{memory}),
        uris_(AllocatorRef<Byte, Memory>{memory}) {
    links_.reserve(maximum_links);
    runs_.reserve(maximum_runs);
    uris_.reserve(maximum_uri_bytes);
  }

  TextMetadata view(std::span<const Byte> row_flags) const noexcept {
    return TextMetadata{.status = status_,
                        .row_flags = row_flags,
                        .links = links_,
                        .runs = runs_,
                        .uris = uris_};
  }

  void capture(GhosttyRenderState state, GhosttyRenderStateRowIterator iterator, std::span<const Byte> row_flags, std::uint16_t columns) {
    links_.clear();
    runs_.clear();
    uris_.clear();
    status_ = MetadataStatus::complete;
    identities_.fill({});
    slots_.fill(0);
    checkGhostty(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator));
    std::uint32_t row = 0;

    while (ghostty_render_state_row_iterator_next(iterator)) {
      if ((row_flags[row] & static_cast<Byte>(RowFlag::hyperlinks)) != 0) {
        captureRow(iterator, row * columns);
      }

      ++row;
    }
  }

private:
  struct Identity {
    std::string_view uri;
    std::string_view explicit_id;
    std::uint64_t implicit_id = 0;

    bool operator==(const Identity &) const = default;
  };

  static std::string_view stringView(GhosttyString value) noexcept {
    return {reinterpret_cast<const char *>(value.ptr), value.len};
  }

  static std::size_t hash(const Identity &identity) noexcept {
    std::size_t value = identity.implicit_id;
    for (const auto text : {identity.uri, identity.explicit_id}) {
      for (const unsigned char byte : text) {
        value = (value ^ byte) * 1099511628211ULL;
      }
    }

    return value;
  }

  std::optional<std::uint16_t> intern(const Identity &identity) {
    auto slot = hash(identity) % slots_.size();
    while (slots_[slot] != 0) {
      const auto index = static_cast<std::uint16_t>(slots_[slot] - 1);
      if (identities_[index] == identity) {
        return index;
      }

      slot = (slot + 1) % slots_.size();
    }

    if (links_.size() == maximum_links || identity.uri.size() > maximum_uri_length || identity.explicit_id.size() > maximum_uri_length || identity.uri.size() > maximum_uri_bytes - uris_.size()) {
      status_ = MetadataStatus::partial;
      return std::nullopt;
    }

    const auto index = static_cast<std::uint16_t>(links_.size());
    links_.push_back(MetadataLink{.offset = static_cast<std::uint32_t>(uris_.size()),
                                  .len = static_cast<std::uint16_t>(identity.uri.size())});
    uris_.insert(uris_.end(), identity.uri.begin(), identity.uri.end());
    identities_[index] = identity;
    slots_[slot] = index + 1;
    return index;
  }

  void captureRow(GhosttyRenderStateRowIterator iterator, std::uint32_t row_start) {
    auto reference = ghosttySized<GhosttyGridRef>();
    GhosttyCellsView cells{};
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_GRID_REF, &reference));
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
    bool continuing = false;

    for (std::uint16_t column = 0; column < cells.len; ++column) {
      const auto raw = cells.ptr[column];
      if (!cell_layout::hyperlink(raw) || cell_layout::wide(raw) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        continuing = false;
        continue;
      }

      reference.x = column;
      GhosttyString uri{};
      GhosttyString explicit_id{};
      std::uint64_t implicit_id = 0;
      const auto result = ghostty_grid_ref_hyperlink(&reference, &uri, &explicit_id, &implicit_id);
      if (result == GHOSTTY_NO_VALUE || uri.len == 0) {
        continuing = false;
        continue;
      }

      checkGhostty(result);
      const auto index = intern(Identity{stringView(uri), stringView(explicit_id), implicit_id});
      if (!index) {
        continuing = false;
        continue;
      }

      if (continuing && runs_.back().link_index == *index) {
        ++runs_.back().len;
      } else if (runs_.size() != maximum_runs) {
        runs_.push_back(MetadataRun{.start = row_start + column,
                                    .len = 1,
                                    .link_index = *index});
      } else {
        status_ = MetadataStatus::partial;
        return;
      }

      continuing = true;
    }
  }

  static constexpr std::size_t maximum_links = 256;
  static constexpr std::size_t maximum_runs = 2048;
  static constexpr std::size_t maximum_uri_bytes = 65536;
  static constexpr std::size_t maximum_uri_length = 4096;
  Vector<MetadataLink, Memory> links_;
  Vector<MetadataRun, Memory> runs_;
  Vector<Byte, Memory> uris_;
  std::array<Identity, maximum_links> identities_{};
  std::array<std::uint16_t, maximum_links * 2> slots_{};
  MetadataStatus status_ = MetadataStatus::complete;
};

}
