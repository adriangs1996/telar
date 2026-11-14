export module telar.gui.paths.label;

import std;
import telar.tbc;

export import telar.gui.text.json_unsigned_integer;

import telar.base.memory.containers;
import telar.base.text;
import telar.wire.editor;
import telar.wire.runtime;
import telar.wire.vocabulary;

// Interface: paths/directory_completion.cppm
export {
  namespace telar::gui {

    struct TypedDirectory {
      std::string_view text;
      std::string_view expanded;
    };

    // The directories one expanded path can complete to, as the workspace form
    // lists them. A listing may block on the filesystem, so it runs on a
    // worker and keeps at most maximum_entries names, the first ones by name.
    struct DirectoryCompletion {
      static constexpr std::size_t maximum_entries = 64;
      static constexpr std::size_t maximum_name_bytes = 255;

      std::string base;
      std::vector<std::string> entries;
      std::size_t matched = 0;
      bool exact_exists = false;

      // The query for what the user typed: a field that is empty or ends with
      // '/' asks for the children of the expanded directory.
      [[nodiscard]] static std::string query(TypedDirectory typed);

      // Splits the query at its last '/': the part before is listed and the rest
      // filters names by prefix. Hidden directories are listed only when the
      // filter itself starts with '.'.
      [[nodiscard]] static DirectoryCompletion list(std::string_view query);

      // The last component of an expanded directory, ignoring a trailing '/'.
      [[nodiscard]] static std::string_view basename(std::string_view path);

      // The directory an entry names, ending in '/' so the next listing shows
      // its children.
      [[nodiscard]] std::string join(std::size_t index) const;

    private:
      // Keeps the first maximum_entries names whatever order the listing finds
      // them in: a full result gives up its last name for one that sorts before.
      void keep(const std::string& name);
    };

  }
}

// Interface: paths/limits.cppm
export {
  namespace telar::gui {

    struct PathPickerLimits {
      static constexpr std::size_t root_bytes = 4096;
      static constexpr std::size_t query_bytes = 64;
      static constexpr std::size_t path_bytes = 1024;
      static constexpr std::size_t results = 50;
      static constexpr std::size_t tracked_requests = 32;
      static constexpr std::size_t error_bytes = 128;
      static constexpr std::size_t page_bytes = results * path_bytes;
      static constexpr std::size_t absolute_bytes = root_bytes + path_bytes + 1;
      static constexpr std::size_t quote_escape_bytes = 4;
      static constexpr std::size_t quoted_bytes = quote_escape_bytes * (root_bytes + path_bytes);
    };

  }
}

// Interface: paths/page.cppm
export {
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

      [[nodiscard]] std::span<const std::uint16_t> highlights() const noexcept;
    };

    class PathPickerPage {
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
}

// Interface: paths/insertion.cppm
export {
  namespace telar::gui {

    class PathInsertion {
    public:
      static constexpr std::string_view paste_begin = BracketedPaste::begin;
      static constexpr std::string_view paste_end = BracketedPaste::end;
      static constexpr std::size_t paste_capacity = PathPickerLimits::quoted_bytes + BracketedPaste::framing_bytes;
      using Text = BoundedText<paste_capacity>;
      using Quoted = BoundedText<PathPickerLimits::quoted_bytes>;
      using AbsolutePath = BoundedText<PathPickerLimits::absolute_bytes>;

      struct Choice {
        std::size_t selection = 0;
        bool absolute = false;
        bool bracketed = false;
      };

      struct JoinParts {
        std::string_view root;
        std::string_view relative;
      };

      [[nodiscard]] static AbsolutePath join(JoinParts parts);

      // The relative path is a suffix of the path, region `a`.
      [[nodiscard]] static tbc::view<std::optional<std::string_view>, tbc::lt::a> relativeTo(std::string_view anchor, tbc::view<std::string_view, tbc::lt::a> path) noexcept;

      [[nodiscard]] static std::optional<Quoted> quote(std::string_view word);

      [[nodiscard]] static std::optional<Text> prepare(const PathPickerPage& page, Choice choice);

      // A word the shell reads as written, with nothing to quote or expand.
      [[nodiscard]] static bool plain(std::string_view word) noexcept;
    };

  }
}

// Interface: paths/label.cppm
export {
  namespace telar::gui {

    enum class PathLabelTone : std::uint8_t {
      directory,
      name,
      match,
      ellipsis,
    };

    struct PathLabelRun {
      std::string_view text;
      PathLabelTone tone = PathLabelTone::name;
    };

    class PathLabel {
    public:
      static constexpr std::size_t runs_per_match = 2;
      static constexpr std::size_t structural_runs = 6;
      static constexpr std::size_t maximum_runs = (runs_per_match * PathPickerLimits::query_bytes) + structural_runs;
      static constexpr std::string_view ellipsis = "…";
      static constexpr std::uint32_t ellipsis_columns = 1;

      // The runs view the laid out path, region `a`, until the next layout.
      void layout(tbc::view<std::string_view, tbc::lt::a> path, std::span<const std::uint16_t> positions, std::uint16_t width);

      [[nodiscard]] tbc::view<std::span<const PathLabelRun>, tbc::lt::a> runs() const noexcept;

    private:
      struct Span {
        std::string_view path;
        std::span<const std::uint16_t> positions;
        std::size_t start = 0;
        std::size_t end = 0;
        std::size_t name_start = 0;
      };

      [[nodiscard]] static std::size_t nameStart(std::string_view path) noexcept;

      [[nodiscard]] static std::size_t nextScalar(std::string_view text, std::size_t offset) noexcept;

      [[nodiscard]] static std::size_t fitting(std::string_view text, std::uint32_t width);

      [[nodiscard]] static PathLabelTone toneAt(const Span& span, std::size_t first, std::size_t last) noexcept;

      void appendSpan(tbc::view<Span, tbc::lt::a> span);

      void push(tbc::view<PathLabelRun, tbc::lt::a> run) noexcept;

      tbc::view<std::array<PathLabelRun, maximum_runs>, tbc::lt::a> runs_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: paths/labels.cppm
export {
  namespace telar::gui {

    struct PathPickerLabels {
      static constexpr std::size_t count_bytes = 32;
      using Status = BoundedText<PathPickerLimits::error_bytes>;
      using Count = BoundedText<count_bytes>;

      [[nodiscard]] static std::string_view root(std::string_view path) noexcept;

      [[nodiscard]] static Count count(const PathPickerPage& page);

      [[nodiscard]] static Status status(const PathPickerPage& page);

      [[nodiscard]] static std::string_view empty(const PathPickerPage& page) noexcept;
    };

  }
}
