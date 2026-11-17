module telar.gui.paths.label;

import std;

import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.gui.input.key_encoder;
import telar.gui.foundation.text;

namespace telar::gui {

  std::string DirectoryCompletion::query(TypedDirectory typed) {
    const bool children = typed.text.empty() || typed.text.ends_with('/');
    std::string result{typed.expanded};
    if (children && !result.empty() && !result.ends_with('/')) {
      result.push_back('/');
    }

    return result;
  }

  DirectoryCompletion DirectoryCompletion::list(std::string_view query) {
    DirectoryCompletion result;

    if (!query.starts_with('/')) {
      return result;
    }

    const auto split = query.rfind('/');

    result.base = split == 0 ? std::string{"/"} : std::string{query.substr(0, split)};
    const auto partial = query.substr(split + 1);
    std::error_code error;

    result.exact_exists = partial.empty() || std::filesystem::is_directory(std::filesystem::path{std::string{query}}, error);

    std::filesystem::directory_iterator directory{
        result.base,
        std::filesystem::directory_options::skip_permission_denied,
        error,
    };

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

  std::string_view DirectoryCompletion::basename(std::string_view path) {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');

    return split == std::string_view::npos ? path : path.substr(split + 1);
  }

  std::string DirectoryCompletion::join(std::size_t index) const {
    std::string path = base;
    if (!path.ends_with('/')) {
      path.push_back('/');
    }

    path.append(entries.at(index));
    path.push_back('/');

    return path;
  }

  void DirectoryCompletion::keep(const std::string& name) {
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

  std::span<const std::uint16_t> PathPickerMatch::highlights() const noexcept {
    return std::span{positions}.first(position_count);
  }

  void PathPickerPage::begin(std::uint64_t pane, std::string_view directory) {
    anchor_.assign(directory);
    pane_id_ = pane;
    setRoot(directory);
    ++revision_;
  }

  void PathPickerPage::setRoot(std::string_view directory) {
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

  void PathPickerPage::close() noexcept {
    phase_ = PathPickerPhase::idle;
    pending_request_ = 0;
    pane_id_ = 0;
    count_ = 0;
    page_used_ = 0;
    ++revision_;
  }

  void PathPickerPage::expect(std::uint64_t request_id) noexcept {
    requests_[next_slot_] = request_id;
    next_slot_ = (next_slot_ + 1) % requests_.size();
    pending_request_ = request_id;
    refresh_ = false;
    phase_ = PathPickerPhase::loading;
    ++revision_;
  }

  bool PathPickerPage::receive(const PathResults& results) {
    if (results.request_id == 0 || results.request_id != pending_request_ || results.root != root_.view()) {
      return false;
    }

    validate(results.matches);
    count_ = 0;
    page_used_ = 0;
    for (const auto& match : results.matches) {
      auto& retained = matches_[count_];

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

  bool PathPickerPage::fail(const RequestFailed& failure) {
    if (failure.request_id == 0 || std::ranges::find(requests_, failure.request_id) == requests_.end()) {
      return false;
    }

    if (failure.request_id == pending_request_) {
      pending_request_ = 0;
      setError(failure.message);
    }

    return true;
  }

  void PathPickerPage::setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, PathPickerLimits::error_bytes));
    phase_ = PathPickerPhase::failed;
    ++revision_;
  }

  std::span<const PathPickerMatch> PathPickerPage::matches() const noexcept {
    return std::span{matches_}.first(count_);
  }

  std::string_view PathPickerPage::path(const PathPickerMatch& match) const noexcept {
    return {page_.data() + match.offset, match.length};
  }

  std::string_view PathPickerPage::root() const noexcept {
    return root_.view();
  }

  std::string_view PathPickerPage::anchor() const noexcept {
    return anchor_.view();
  }

  std::string_view PathPickerPage::error() const noexcept {
    return error_.view();
  }

  PathPickerPhase PathPickerPage::phase() const noexcept {
    return phase_;
  }

  std::uint64_t PathPickerPage::paneId() const noexcept {
    return pane_id_;
  }

  std::uint64_t PathPickerPage::pendingRequest() const noexcept {
    return pending_request_;
  }

  std::uint64_t PathPickerPage::revision() const noexcept {
    return revision_;
  }

  std::uint32_t PathPickerPage::scanned() const noexcept {
    return scanned_;
  }

  bool PathPickerPage::refreshRequested() const noexcept {
    return refresh_;
  }

  bool PathPickerPage::complete() const noexcept {
    return complete_;
  }

  bool PathPickerPage::truncated() const noexcept {
    return truncated_;
  }

  void PathPickerPage::validate(std::span<const PathMatch> matches) {
    if (matches.size() > PathPickerLimits::results) {
      throw EncodingError{"Too many path matches"};
    }

    for (const auto& match : matches) {
      if (match.path.empty() || match.path.size() > PathPickerLimits::path_bytes || match.positions.size() > PathPickerLimits::query_bytes) {
        throw EncodingError{"Invalid path match bounds"};
      }

      static_cast<void>(ValueCodec<PathMatch>::encodedSize(match));
    }
  }

  PathInsertion::AbsolutePath PathInsertion::join(JoinParts parts) {
    AbsolutePath path;

    path.append(parts.root);
    if (parts.root.size() != 1) {
      path.append("/");
    }

    path.append(parts.relative);

    return path;
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> PathInsertion::relativeTo(std::string_view anchor, tbc::view<std::string_view, tbc::lt::a> path) noexcept {
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

  std::optional<PathInsertion::Quoted> PathInsertion::quote(std::string_view word) {
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
    } catch (const std::length_error&) {
      return std::nullopt;
    }

    return output;
  }

  std::optional<PathInsertion::Text> PathInsertion::prepare(const PathPickerPage& page, Choice choice) {
    if (page.matches().empty()) {
      return std::nullopt;
    }

    const auto& match = page.matches()[std::min(choice.selection, page.matches().size() - 1)];
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

  bool PathInsertion::plain(std::string_view word) noexcept {
    return std::ranges::all_of(word, [](char byte) {
      constexpr std::string_view literal_punctuation = "_-./+@%,:";
      const auto letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
      const auto digit = byte >= '0' && byte <= '9';

      return letter || digit || literal_punctuation.contains(byte);
    });
  }

  void PathLabel::layout(tbc::view<std::string_view, tbc::lt::a> path, std::span<const std::uint16_t> positions, std::uint16_t width) {
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

  tbc::view<std::span<const PathLabelRun>, tbc::lt::a> PathLabel::runs() const noexcept {
    return std::span{runs_}.first(count_);
  }

  std::size_t PathLabel::nameStart(std::string_view path) noexcept {
    const auto last = path.find_last_not_of('/');

    path.remove_suffix(last == std::string_view::npos ? path.size() : path.size() - last - 1);
    const auto split = path.rfind('/');

    return split == std::string_view::npos ? 0 : split + 1;
  }

  std::size_t PathLabel::nextScalar(std::string_view text, std::size_t offset) noexcept {
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[offset]));
    const auto length = sequence >= 1 && sequence <= Utf8Scalar::leading_masks.size() ? sequence : 1;

    return std::min(offset + length, text.size());
  }

  std::size_t PathLabel::fitting(std::string_view text, std::uint32_t width) {
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

  PathLabelTone PathLabel::toneAt(const Span& span, std::size_t first, std::size_t last) noexcept {
    for (const auto position : span.positions) {
      if (position >= first && position < last) {
        return PathLabelTone::match;
      }
    }

    return first >= span.name_start ? PathLabelTone::name : PathLabelTone::directory;
  }

  void PathLabel::appendSpan(tbc::view<Span, tbc::lt::a> span) {
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

  void PathLabel::push(tbc::view<PathLabelRun, tbc::lt::a> run) noexcept {
    if (count_ < runs_.size()) {
      runs_[count_++] = run;
    }
  }

  std::string_view PathPickerLabels::root(std::string_view path) noexcept {
    if (path.size() <= 1) {
      return "/";
    }

    const auto split = path.rfind('/');
    if (split != std::string_view::npos) {
      path.remove_prefix(split + 1);
    }

    return path;
  }

  PathPickerLabels::Count PathPickerLabels::count(const PathPickerPage& page) {
    Count result;

    result.appendDecimal(page.matches().size());
    result.append(" of ");
    result.appendDecimal(page.scanned());

    return result;
  }

  PathPickerLabels::Status PathPickerLabels::status(const PathPickerPage& page) {
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

  std::string_view PathPickerLabels::empty(const PathPickerPage& page) noexcept {
    if (page.phase() == PathPickerPhase::failed) {
      return "No paths";
    }

    return page.phase() == PathPickerPhase::ready && page.complete() ? "No paths match" : "Searching…";
  }

}
