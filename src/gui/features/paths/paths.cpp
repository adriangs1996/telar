module telar.gui.features.paths;

import std;

import :picker;
import telar.base.text.utf8;
import telar.wire.editor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::paths {

  std::span<const std::uint16_t> PathPickerMatch::highlights() const noexcept {
    return std::span{positions}.first(position_count);
  }

  void PathPicker::begin(std::uint64_t pane, std::string_view directory) {
    anchor_.assign(directory);
    pane_id_ = pane;
    setRoot(directory);
    ++revision_;
  }

  void PathPicker::setRoot(std::string_view directory) {
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

  void PathPicker::close() noexcept {
    phase_ = PathPickerPhase::idle;
    pending_request_ = 0;
    pane_id_ = 0;
    count_ = 0;
    page_used_ = 0;
    ++revision_;
  }

  void PathPicker::expect(std::uint64_t request_id) noexcept {
    requests_.atMut(next_slot_) = request_id;
    next_slot_ = (next_slot_ + 1) % requests_.size();
    pending_request_ = request_id;
    refresh_ = false;
    phase_ = PathPickerPhase::loading;
    ++revision_;
  }

  bool PathPicker::receive(const PathResults& results) {
    if (results.request_id == 0 || results.request_id != pending_request_ || results.root != root_.view()) {
      return false;
    }

    validate(results.matches);
    count_ = 0;
    page_used_ = 0;
    for (const auto& match : results.matches) {
      auto& retained = matches_.atMut(count_);

      retained.offset = static_cast<std::uint16_t>(page_used_);
      retained.length = static_cast<std::uint16_t>(match.path.size());
      retained.kind = match.kind;
      retained.position_count = static_cast<std::uint8_t>(match.positions.size());
      std::ranges::copy(match.positions, retained.positions.viewMut().begin());
      std::memcpy(page_.dataMut() + page_used_, match.path.data(), match.path.size());
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

  bool PathPicker::fail(const RequestFailed& failure) {
    if (failure.request_id == 0 || std::ranges::find(requests_, failure.request_id) == requests_.end()) {
      return false;
    }

    if (failure.request_id == pending_request_) {
      pending_request_ = 0;
      setError(failure.message);
    }

    return true;
  }

  void PathPicker::setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, PathPickerLimits::error_bytes));
    phase_ = PathPickerPhase::failed;
    ++revision_;
  }

  std::span<const PathPickerMatch> PathPicker::matches() const noexcept {
    return std::span{matches_}.first(count_);
  }

  std::string_view PathPicker::path(const PathPickerMatch& match) const noexcept {
    return {page_.data() + match.offset, match.length};
  }

  std::string_view PathPicker::root() const noexcept {
    return root_.view();
  }

  std::string_view PathPicker::anchor() const noexcept {
    return anchor_.view();
  }

  std::string_view PathPicker::error() const noexcept {
    return error_.view();
  }

  PathPickerPhase PathPicker::phase() const noexcept {
    return phase_;
  }

  std::uint64_t PathPicker::paneId() const noexcept {
    return pane_id_;
  }

  std::uint64_t PathPicker::pendingRequest() const noexcept {
    return pending_request_;
  }

  std::uint64_t PathPicker::revision() const noexcept {
    return revision_;
  }

  std::uint32_t PathPicker::scanned() const noexcept {
    return scanned_;
  }

  bool PathPicker::refreshRequested() const noexcept {
    return refresh_;
  }

  bool PathPicker::complete() const noexcept {
    return complete_;
  }

  bool PathPicker::truncated() const noexcept {
    return truncated_;
  }

  void PathPicker::validate(std::span<const PathMatch> matches) {
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

  PathPickerPage::PathPickerPage(const PathPicker& picker) noexcept
      : picker_(&picker) {}

  std::span<const PathPickerMatch> PathPickerPage::matches() const noexcept {
    return picker_->matches();
  }

  std::string_view PathPickerPage::path(const PathPickerMatch& match) const noexcept {
    return picker_->path(match);
  }

  std::string_view PathPickerPage::root() const noexcept {
    return picker_->root();
  }

  std::string_view PathPickerPage::anchor() const noexcept {
    return picker_->anchor();
  }

  std::string_view PathPickerPage::error() const noexcept {
    return picker_->error();
  }

  PathPickerPhase PathPickerPage::phase() const noexcept {
    return picker_->phase();
  }

  std::uint64_t PathPickerPage::paneId() const noexcept {
    return picker_->paneId();
  }

  std::uint64_t PathPickerPage::pendingRequest() const noexcept {
    return picker_->pendingRequest();
  }

  std::uint64_t PathPickerPage::revision() const noexcept {
    return picker_->revision();
  }

  std::uint32_t PathPickerPage::scanned() const noexcept {
    return picker_->scanned();
  }

  bool PathPickerPage::complete() const noexcept {
    return picker_->complete();
  }

  bool PathPickerPage::truncated() const noexcept {
    return picker_->truncated();
  }

  PathPickerPage page(const State& state) noexcept {
    return PathPickerPage{Access::picker(state)};
  }

  PathSeed seed(const State& state) noexcept {
    const auto& seed = Access::seed(state);

    return {.pane_id = seed.pane_id, .begin = seed.begin, .text = seed.text.view()};
  }

  void open(State& state, std::uint64_t pane_id, std::string_view directory, PathSeed word) {
    auto& seed = Access::seed(state);

    Access::picker(state).begin(pane_id, directory);
    seed = {};
    if (word.text.empty() || word.text.size() > PathPickerLimits::query_bytes || word.text.front() == '/' || word.text.front() == '~' || !PathInsertion::plain(word.text)) {
      return;
    }

    seed.pane_id = word.pane_id;
    seed.begin = word.begin;
    seed.text.assign(word.text);
  }

  tbc::val_a<FindPaths> search(tbc::ref_a<State> state, tbc::val_a<std::string_view> query, std::uint64_t request_id) noexcept {
    const auto& picker = Access::picker(state);

    return {
        .request_id = request_id,
        .root = picker.root(),
        .query = runtime::utf8Prefix(query, PathPickerLimits::query_bytes),
        .kind = PathKindFilter::any,
        .limit = static_cast<std::uint16_t>(PathPickerLimits::results),
        .refresh = picker.refreshRequested(),
    };
  }

  void wait(State& state, std::uint64_t request_id) noexcept {
    Access::picker(state).expect(request_id);
  }

  void report(State& state, std::string_view message) {
    Access::picker(state).setError(message);
  }

  bool descend(State& state, std::size_t selection) {
    auto& picker = Access::picker(state);
    const auto matches = picker.matches();
    if (matches.empty()) {
      return false;
    }

    const auto& match = matches[std::min(selection, matches.size() - 1)];
    if (match.kind != PathKind::directory) {
      return false;
    }

    auto relative = picker.path(match);
    const auto last = relative.find_last_not_of('/');

    relative.remove_suffix(last == std::string_view::npos ? relative.size() : relative.size() - last - 1);
    const auto directory = PathInsertion::join({.root = picker.root(), .relative = relative});
    if (directory.view().size() > PathPickerLimits::root_bytes) {
      return false;
    }

    picker.setRoot(directory.view());

    return true;
  }

  bool ascend(State& state) {
    auto& picker = Access::picker(state);
    const auto root = picker.root();
    if (root.size() <= 1) {
      return false;
    }

    const auto separator = root.rfind('/');
    if (separator == std::string_view::npos) {
      return false;
    }

    picker.setRoot(separator == 0 ? root.substr(0, 1) : root.substr(0, separator));

    return true;
  }

  void close(State& state) noexcept {
    Access::picker(state).close();
    Access::seed(state) = {};
  }

  void forget(State& state, std::uint64_t pane_id) noexcept {
    if (Access::seed(state).pane_id == pane_id) {
      Access::seed(state) = {};
    }
  }

  bool insertable(State& state) {
    auto& picker = Access::picker(state);
    if (!picker.matches().empty()) {
      return true;
    }

    picker.setError(picker.phase() == PathPickerPhase::loading ? "Searching..." : "No path to insert");

    return false;
  }

  ds::Option<PathInsertion::Text> insertion(const State& state, PathInsertion::Choice choice) {
    return PathInsertion::prepare(page(state), choice);
  }

  bool receive(State& state, const PathResults& results) {
    return Access::picker(state).receive(results);
  }

  ds::Option<bool> fail(State& state, const RequestFailed& failure) {
    auto& picker = Access::picker(state);
    const auto revision = picker.revision();

    if (!picker.fail(failure)) {
      return ds::none;
    }

    return revision != picker.revision();
  }

}
