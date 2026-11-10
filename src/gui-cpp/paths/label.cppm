module;
#include <cstdio>

#include <cstddef>

#include <cstdint>
#include <cstring>


#include <ghostty/vt/unicode.h>
#include "tbc/view.hpp"

export module telar.gui.paths.label;

import std;

export import telar.gui.input.key_encoder;


export import telar.gui.text.json_unsigned_integer;


export import telar.gui.core.unicode_scalar;

export import telar.gui.text.bounded_editor;
import telar.base.diagnostics;
import telar.client.protocol;

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
  [[nodiscard]] inline static std::string query(TypedDirectory typed) {
    const bool children = typed.text.empty() || typed.text.ends_with('/');
    std::string result{typed.expanded};
    if (children && !result.empty() && !result.ends_with('/')) {
      result.push_back('/');
    }

    return result;
  }

  // Splits the query at its last '/': the part before is listed and the rest
  // filters names by prefix. Hidden directories are listed only when the
  // filter itself starts with '.'.
  [[nodiscard]] inline static DirectoryCompletion list(std::string_view query) {
    DirectoryCompletion result;
    if (!query.starts_with('/')) {
      return result;
    }

    const auto split = query.rfind('/');
    result.base = split == 0 ? std::string{"/"} : std::string{query.substr(0, split)};
    const auto partial = query.substr(split + 1);
    std::error_code error;
    result.exact_exists = partial.empty() || std::filesystem::is_directory(std::filesystem::path{std::string{query}}, error);

    std::filesystem::directory_iterator directory{result.base, std::filesystem::directory_options::skip_permission_denied, error};
    for (const std::filesystem::directory_iterator end; !error && directory != end; directory.increment(error)) {
      const auto name = directory->path().filename().string();
      if (!name.starts_with(partial) || (name.starts_with('.') && !partial.starts_with('.'))) {
        continue;
      }

      std::error_code status;
      if (!directory->is_directory(status)) {
        continue;
      }

      ++result.matched;
      result.keep(name);
    }

    std::ranges::sort(result.entries);

    return result;
  }

  // The last component of an expanded directory, ignoring a trailing '/'.
  [[nodiscard]] inline static std::string_view basename(std::string_view path) {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');

    return split == std::string_view::npos ? path : path.substr(split + 1);
  }

  // The directory an entry names, ending in '/' so the next listing shows
  // its children.
  [[nodiscard]] inline std::string join(std::size_t index) const {
    std::string path = base;
    if (!path.ends_with('/')) {
      path.push_back('/');
    }

    path.append(entries.at(index));
    path.push_back('/');

    return path;
  }

private:
  // Keeps the first maximum_entries names whatever order the listing finds
  // them in: a full result gives up its last name for one that sorts before.
  inline void keep(const std::string &name) {
    if (name.empty() || name.size() > maximum_name_bytes) {
      return;
    }

    if (entries.size() < maximum_entries) {
      entries.push_back(name);

      return;
    }

    const auto last = std::ranges::max_element(entries);
    if (name < *last) {
      *last = name;
    }
  }
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

  [[nodiscard]] inline std::span<const std::uint16_t> highlights() const noexcept {
    return std::span{positions}.first(position_count);
  }
};

class PathPickerPage {
public:
  inline void begin(std::uint64_t pane, std::string_view directory) {
    anchor_.assign(directory);
    pane_id_ = pane;
    setRoot(directory);
    ++revision_;
  }

  inline void setRoot(std::string_view directory) {
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

  inline void close() noexcept {
    phase_ = PathPickerPhase::idle;
    pending_request_ = 0;
    pane_id_ = 0;
    count_ = 0;
    page_used_ = 0;
    ++revision_;
  }

  inline void expect(std::uint64_t request_id) noexcept {
    requests_[next_slot_] = request_id;
    next_slot_ = (next_slot_ + 1) % requests_.size();
    pending_request_ = request_id;
    refresh_ = false;
    phase_ = PathPickerPhase::loading;
    ++revision_;
  }

  inline bool receive(const PathResults &results) {
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

  inline bool fail(const RequestFailed &failure) {
    if (failure.request_id == 0 || std::ranges::find(requests_, failure.request_id) == requests_.end()) {
      return false;
    }

    if (failure.request_id == pending_request_) {
      pending_request_ = 0;
      setError(failure.message);
    }

    return true;
  }

  inline void setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, PathPickerLimits::error_bytes));
    phase_ = PathPickerPhase::failed;
    ++revision_;
  }

  [[nodiscard]] inline std::span<const PathPickerMatch> matches() const noexcept {
    return std::span{matches_}.first(count_);
  }

  [[nodiscard]] inline std::string_view path(const PathPickerMatch &match) const noexcept {
    return {page_.data() + match.offset, match.length};
  }

  [[nodiscard]] inline std::string_view root() const noexcept {
    return root_.view();
  }

  [[nodiscard]] inline std::string_view anchor() const noexcept {
    return anchor_.view();
  }

  [[nodiscard]] inline std::string_view error() const noexcept {
    return error_.view();
  }

  [[nodiscard]] inline PathPickerPhase phase() const noexcept {
    return phase_;
  }

  [[nodiscard]] inline std::uint64_t paneId() const noexcept {
    return pane_id_;
  }

  [[nodiscard]] inline std::uint64_t pendingRequest() const noexcept {
    return pending_request_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::uint32_t scanned() const noexcept {
    return scanned_;
  }

  [[nodiscard]] inline bool refreshRequested() const noexcept {
    return refresh_;
  }

  [[nodiscard]] inline bool complete() const noexcept {
    return complete_;
  }

  [[nodiscard]] inline bool truncated() const noexcept {
    return truncated_;
  }

private:
  inline static void validate(std::span<const PathMatch> matches) {
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
}

// Interface: paths/insertion.cppm
export {
namespace telar::gui {

class PathInsertion {
public:
  static constexpr std::string_view paste_begin = PasteEncoding::begin;
  static constexpr std::string_view paste_end = PasteEncoding::end;
  static constexpr std::size_t paste_capacity = PathPickerLimits::quoted_bytes + PasteEncoding::framing_bytes;
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

  [[nodiscard]] inline static AbsolutePath join(JoinParts parts) {
    AbsolutePath path;
    path.append(parts.root);
    if (parts.root.size() != 1) {
      path.append("/");
    }

    path.append(parts.relative);

    return path;
  }

  // The relative path is a suffix of the path, region `a`.
  [[nodiscard]] inline static tbc::view<std::optional<std::string_view>, tbc::lt::a> relativeTo(std::string_view anchor, tbc::view<std::string_view, tbc::lt::a> path) noexcept {
    if (anchor.size() == 1) {
      if (path.size() <= 1) {
        return std::nullopt;
      }

      path.remove_prefix(1);

      return path;
    }

    if (path.size() <= anchor.size() + 1 || !path.starts_with(anchor) || path[anchor.size()] != '/') {
      return std::nullopt;
    }

    path.remove_prefix(anchor.size() + 1);

    return path;
  }

  [[nodiscard]] inline static std::optional<Quoted> quote(std::string_view word) {
    Quoted output;
    if (word.empty()) {
      return output;
    }

    try {
      if (word.front() == '-') {
        output.append("./");
      }

      if (plain(word)) {
        output.append(word);

        return output;
      }

      output.append("'");
      for (const auto byte : word) {
        if (byte == '\'') {
          output.append("'\\''");
        } else {
          output.append(std::string_view{&byte, 1});
        }
      }

      output.append("'");
    } catch (const std::length_error &) {
      return std::nullopt;
    }

    return output;
  }

  [[nodiscard]] inline static std::optional<Text> prepare(const PathPickerPage &page, Choice choice) {
    if (page.matches().empty()) {
      return std::nullopt;
    }

    const auto &match = page.matches()[std::min(choice.selection, page.matches().size() - 1)];
    const auto full = join({.root = page.root(), .relative = page.path(match)});
    auto word = full.view();
    if (!choice.absolute) {
      if (const auto relative = relativeTo(page.anchor(), word)) {
        word = *relative;
      }
    }

    const auto quoted = quote(word);
    if (!quoted) {
      return std::nullopt;
    }

    return PasteEncoding::encode<PathPickerLimits::quoted_bytes>(quoted->view(), choice.bracketed);
  }

  // A word the shell reads as written, with nothing to quote or expand.
  [[nodiscard]] inline static bool plain(std::string_view word) noexcept {
    return std::ranges::all_of(word, [](char byte) {
      constexpr std::string_view literal_punctuation = "_-./+@%,:";
      const auto letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
      const auto digit = byte >= '0' && byte <= '9';

      return letter || digit || literal_punctuation.contains(byte);
    });
  }
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
  inline void layout(tbc::view<std::string_view, tbc::lt::a> path, std::span<const std::uint16_t> positions, std::uint16_t width) {
    count_ = 0;
    const auto name_start = nameStart(path);
    if (cellTextColumns(path) <= width) {
      appendSpan({.path = path, .positions = positions, .end = path.size(), .name_start = name_start});

      return;
    }

    const auto name_width = cellTextColumns(path.substr(name_start));
    const auto head_width = width > name_width + ellipsis_columns ? width - name_width - ellipsis_columns : 0;
    const auto head_end = fitting(path.substr(0, name_start), head_width);
    appendSpan({.path = path, .positions = positions, .end = head_end, .name_start = name_start});
    push({.text = ellipsis, .tone = PathLabelTone::ellipsis});
    appendSpan({.path = path, .positions = positions, .start = name_start, .end = path.size(), .name_start = name_start});
  }

  [[nodiscard]] inline tbc::view<std::span<const PathLabelRun>, tbc::lt::a> runs() const noexcept {
    return std::span{runs_}.first(count_);
  }

private:
  struct Span {
    std::string_view path;
    std::span<const std::uint16_t> positions;
    std::size_t start = 0;
    std::size_t end = 0;
    std::size_t name_start = 0;
  };

  [[nodiscard]] inline static std::size_t nameStart(std::string_view path) noexcept {
    const auto last = path.find_last_not_of('/');
    path.remove_suffix(last == std::string_view::npos ? path.size() : path.size() - last - 1);
    const auto split = path.rfind('/');

    return split == std::string_view::npos ? 0 : split + 1;
  }

  [[nodiscard]] inline static std::size_t nextScalar(std::string_view text, std::size_t offset) noexcept {
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[offset]));
    const auto length = sequence >= 1 && sequence <= Utf8Scalar::leading_masks.size() ? sequence : 1;

    return std::min(offset + length, text.size());
  }

  [[nodiscard]] inline static std::size_t fitting(std::string_view text, std::uint32_t width) {
    std::uint32_t used = 0;
    std::size_t end = 0;
    while (end < text.size()) {
      const auto next = nextScalar(text, end);
      const auto columns = cellTextColumns(text.substr(end, next - end));
      if (used + columns > width) {
        break;
      }

      used += columns;
      end = next;
    }

    return end;
  }

  [[nodiscard]] inline static PathLabelTone toneAt(const Span &span, std::size_t first, std::size_t last) noexcept {
    for (const auto position : span.positions) {
      if (position >= first && position < last) {
        return PathLabelTone::match;
      }
    }

    return first >= span.name_start ? PathLabelTone::name : PathLabelTone::directory;
  }

  inline void appendSpan(tbc::view<Span, tbc::lt::a> span) {
    if (span.start == span.end) {
      return;
    }

    auto run_start = span.start;
    auto tone = toneAt(span, span.start, nextScalar(span.path, span.start));
    auto cursor = span.start;
    while (cursor < span.end) {
      const auto next = nextScalar(span.path, cursor);
      const auto current = toneAt(span, cursor, next);
      if (current != tone) {
        push({.text = span.path.substr(run_start, cursor - run_start), .tone = tone});
        run_start = cursor;
        tone = current;
      }

      cursor = next;
    }

    push({.text = span.path.substr(run_start, span.end - run_start), .tone = tone});
  }

  inline void push(tbc::view<PathLabelRun, tbc::lt::a> run) noexcept {
    if (count_ < runs_.size()) {
      runs_[count_++] = run;
    }
  }

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

  [[nodiscard]] inline static std::string_view root(std::string_view path) noexcept {
    if (path.size() <= 1) {
      return "/";
    }

    const auto split = path.rfind('/');
    if (split != std::string_view::npos) {
      path.remove_prefix(split + 1);
    }

    return path;
  }

  [[nodiscard]] inline static Count count(const PathPickerPage &page) {
    Count result;
    result.appendDecimal(page.matches().size());
    result.append(" of ");
    result.appendDecimal(page.scanned());

    return result;
  }

  [[nodiscard]] inline static Status status(const PathPickerPage &page) {
    Status result;
    if (page.phase() == PathPickerPhase::failed) {
      result.append(page.error());

      return result;
    }

    if (!page.complete()) {
      result.append("indexing · ");
      result.appendDecimal(page.scanned());
    } else {
      result.appendDecimal(page.scanned());
      result.append(page.truncated() ? "+ paths" : " paths");
    }

    return result;
  }

  [[nodiscard]] inline static std::string_view empty(const PathPickerPage &page) noexcept {
    if (page.phase() == PathPickerPhase::failed) {
      return "No paths";
    }

    return page.phase() == PathPickerPhase::ready && page.complete() ? "No paths match" : "Searching…";
  }
};

}
}
