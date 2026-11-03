#pragma once

#include "limits.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string_view>

namespace telar::gui {

enum class PathPickerPhase : std::uint8_t {
  idle,
  loading,
  ready,
  failed,
};

struct PathPickerMatch {
  std::uint16_t offset = 0;
  std::uint16_t length = 0;
  PathKind kind = PathKind::file;
  std::array<std::uint16_t, PathPickerLimits::query_bytes> positions{};
  std::uint8_t position_count = 0;

  [[nodiscard]] std::span<const std::uint16_t> highlights() const noexcept {
    return std::span{positions}.first(position_count);
  }
};

class PathPickerPage {
public:
  void begin(std::uint64_t pane, std::string_view directory) {
    anchor_.assign(directory);
    pane_id_ = pane;
    setRoot(directory);
    ++revision_;
  }

  void setRoot(std::string_view directory) {
    root_.assign(directory);
    refresh_ = true;
    count_ = 0;
    page_used_ = 0;
    scanned_ = 0;
    complete_ = true;
    truncated_ = false;
    error_.assign({});
    phase_ = PathPickerPhase::idle;
    ++revision_;
  }

  void close() noexcept {
    phase_ = PathPickerPhase::idle;
    pending_request_ = 0;
    pane_id_ = 0;
    count_ = 0;
    page_used_ = 0;
    ++revision_;
  }

  void expect(std::uint64_t request_id) noexcept {
    requests_[next_slot_] = request_id;
    next_slot_ = (next_slot_ + 1) % requests_.size();
    pending_request_ = request_id;
    refresh_ = false;
    phase_ = PathPickerPhase::loading;
    ++revision_;
  }

  bool receive(const PathResults &results) {
    if (results.request_id == 0 || results.request_id != pending_request_ || results.root != root_.view()) {
      return false;
    }

    validate(results.matches);
    count_ = 0;
    page_used_ = 0;
    for (const auto &match : results.matches) {
      auto &retained = matches_[count_];
      retained.offset = static_cast<std::uint16_t>(page_used_);
      retained.length = static_cast<std::uint16_t>(match.path.size());
      retained.kind = match.kind;
      retained.position_count = static_cast<std::uint8_t>(match.positions.size());
      std::ranges::copy(match.positions, retained.positions.begin());
      std::memcpy(page_.data() + page_used_, match.path.data(), match.path.size());
      page_used_ += match.path.size();
      ++count_;
    }

    scanned_ = results.scanned;
    complete_ = results.complete;
    truncated_ = results.truncated;
    error_.assign({});
    phase_ = PathPickerPhase::ready;
    if (complete_) {
      pending_request_ = 0;
    }

    ++revision_;

    return true;
  }

  bool fail(const RequestFailed &failure) {
    if (failure.request_id == 0 || std::ranges::find(requests_, failure.request_id) == requests_.end()) {
      return false;
    }

    if (failure.request_id == pending_request_) {
      pending_request_ = 0;
      setError(failure.message);
    }

    return true;
  }

  void setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, PathPickerLimits::error_bytes));
    phase_ = PathPickerPhase::failed;
    ++revision_;
  }

  [[nodiscard]] std::span<const PathPickerMatch> matches() const noexcept {
    return std::span{matches_}.first(count_);
  }

  [[nodiscard]] std::string_view path(const PathPickerMatch &match) const noexcept {
    return {page_.data() + match.offset, match.length};
  }

  [[nodiscard]] std::string_view root() const noexcept {
    return root_.view();
  }

  [[nodiscard]] std::string_view anchor() const noexcept {
    return anchor_.view();
  }

  [[nodiscard]] std::string_view error() const noexcept {
    return error_.view();
  }

  [[nodiscard]] PathPickerPhase phase() const noexcept {
    return phase_;
  }

  [[nodiscard]] std::uint64_t paneId() const noexcept {
    return pane_id_;
  }

  [[nodiscard]] std::uint64_t pendingRequest() const noexcept {
    return pending_request_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::uint32_t scanned() const noexcept {
    return scanned_;
  }

  [[nodiscard]] bool refreshRequested() const noexcept {
    return refresh_;
  }

  [[nodiscard]] bool complete() const noexcept {
    return complete_;
  }

  [[nodiscard]] bool truncated() const noexcept {
    return truncated_;
  }

private:
  static void validate(std::span<const PathMatch> matches) {
    if (matches.size() > PathPickerLimits::results) {
      throw EncodingError{"Too many path matches"};
    }

    for (const auto &match : matches) {
      if (match.path.empty() || match.path.size() > PathPickerLimits::path_bytes || match.positions.size() > PathPickerLimits::query_bytes) {
        throw EncodingError{"Invalid path match bounds"};
      }

      static_cast<void>(ValueCodec<PathMatch>::encodedSize(match));
    }
  }

  runtime::FixedText<PathPickerLimits::root_bytes> root_;
  runtime::FixedText<PathPickerLimits::root_bytes> anchor_;
  runtime::FixedText<PathPickerLimits::error_bytes> error_;
  std::array<char, PathPickerLimits::page_bytes> page_{};
  std::array<PathPickerMatch, PathPickerLimits::results> matches_{};
  std::array<std::uint64_t, PathPickerLimits::tracked_requests> requests_{};
  PathPickerPhase phase_ = PathPickerPhase::idle;
  std::uint64_t pane_id_ = 0;
  std::uint64_t pending_request_ = 0;
  std::uint64_t revision_ = 0;
  std::size_t next_slot_ = 0;
  std::size_t count_ = 0;
  std::size_t page_used_ = 0;
  std::uint32_t scanned_ = 0;
  bool refresh_ = false;
  bool complete_ = true;
  bool truncated_ = false;
};

}
