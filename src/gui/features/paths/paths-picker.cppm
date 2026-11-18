// The search the path picker runs: its root, the requests it awaits and the page of matches it
// keeps. Nothing here is exported: only the feature's own units name it, through State.
export module telar.gui.features.paths:picker;

import std;

import :page;
import telar.base.memory.containers;
import telar.wire.editor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::paths {

  class PathPicker {
  public:
    void begin(std::uint64_t pane, std::string_view directory);

    void setRoot(std::string_view directory);

    void close() noexcept;

    void expect(std::uint64_t request_id) noexcept;

    bool receive(const PathResults& results);

    bool fail(const RequestFailed& failure);

    void setError(std::string_view message);

    [[nodiscard]] std::span<const PathPickerMatch> matches() const noexcept;

    [[nodiscard]] std::string_view path(const PathPickerMatch& match) const noexcept;

    [[nodiscard]] std::string_view root() const noexcept;

    [[nodiscard]] std::string_view anchor() const noexcept;

    [[nodiscard]] std::string_view error() const noexcept;

    [[nodiscard]] PathPickerPhase phase() const noexcept;

    [[nodiscard]] std::uint64_t paneId() const noexcept;

    [[nodiscard]] std::uint64_t pendingRequest() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    [[nodiscard]] std::uint32_t scanned() const noexcept;

    [[nodiscard]] bool refreshRequested() const noexcept;

    [[nodiscard]] bool complete() const noexcept;

    [[nodiscard]] bool truncated() const noexcept;

  private:
    static void validate(std::span<const PathMatch> matches);

    runtime::FixedText<PathPickerLimits::root_bytes> root_;
    runtime::FixedText<PathPickerLimits::root_bytes> anchor_;
    runtime::FixedText<PathPickerLimits::error_bytes> error_;
    ds::Array<char, PathPickerLimits::page_bytes> page_{};
    ds::Array<PathPickerMatch, PathPickerLimits::results> matches_{};
    ds::Array<std::uint64_t, PathPickerLimits::tracked_requests> requests_{};
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
