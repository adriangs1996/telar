module telar.gui.features.explorer;

import std;

import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.base.ds;
import telar.tbc;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace telar::gui::features::explorer {

  namespace {

    // What the path search says git holds of a match, as the explorer names it.
    constexpr FileState stateOf(PathChange change) noexcept {
      switch (change) {
      case PathChange::none:
        return FileState::unchanged;
      case PathChange::modified:
        return FileState::modified;
      case PathChange::added:
        return FileState::added;
      case PathChange::deleted:
        return FileState::deleted;
      case PathChange::renamed:
        return FileState::renamed;
      case PathChange::untracked:
        return FileState::untracked;
      case PathChange::conflicted:
        return FileState::conflicted;
      }

      return FileState::unchanged;
    }

    tbc::val_a<Directory*> findMut(tbc::mut_a<State> state, std::string_view path) noexcept {
      for (auto& directory : state.directories.viewMut()) {
        if (directory->path.view() == path) {
          return &directory.getMut();
        }
      }

      return nullptr;
    }

    // The directory `path`, kept from now on. With the cache full, the one read longest ago that
    // waits for nothing gives it its place.
    tbc::mut_a<Directory> keep(tbc::mut_a<State> state, std::string_view path) {
      if (auto* known = findMut(state, path)) {
        return *known;
      }

      if (state.directories.size() >= ExplorerLimits::directories) {
        std::size_t oldest = state.directories.size();

        for (std::size_t index = 0; index < state.directories.size(); ++index) {
          const auto& directory = *state.directories[index];
          if (directory.listing == 0 && directory.measuring == 0 && (oldest == state.directories.size() || directory.used < state.directories[oldest]->used)) {
            oldest = index;
          }
        }

        if (oldest != state.directories.size()) {
          static_cast<void>(state.directories.remove(oldest));
        }
      }

      auto& directory = state.directories.push(ds::makeBox<Directory>(state.memory, state.memory)).getMut();

      directory.path.assign(path);
      directory.used = ++state.clock;
      return directory;
    }

    void settle(State& state) noexcept {
      if (state.in_flight != 0) {
        --state.in_flight;
      }

      ++state.revision;
    }

    // Whether the entries past the ones a measure covered hold a directory.
    bool holdsUnmeasured(const Directory& directory) noexcept {
      return std::ranges::any_of(directory.entries.view().subspan(std::min<std::size_t>(directory.measured, directory.entries.size())), [](const Entry& entry) {
        return entry.kind == FileKind::directory;
      });
    }

    // The entry of `changes` for exactly `path`.
    tbc::val_a<const Change*> exact(tbc::ref_a<Repository> repository, std::string_view path) noexcept {
      const auto changes = repository.changes.view();
      const auto found = std::ranges::lower_bound(changes, path, {}, [&](const Change& change) {
        return repository.path(change);
      });

      return found != changes.end() && repository.path(*found) == path ? std::to_address(found) : nullptr;
    }

    constexpr bool changed(FileState state) noexcept {
      return state != FileState::unchanged && state != FileState::ignored;
    }

    // The inspection of `path`, in flight or answered.
    tbc::val_a<const Inspection*> inspectionOf(tbc::ref_a<State> state, std::string_view path) noexcept {
      for (const auto& inspection : state.inspections) {
        if (inspection->asked.view() == path) {
          return &inspection.get();
        }
      }

      return nullptr;
    }

    // A place for the inspection of `path`: with all of them taken, the one read longest ago that
    // waits for nothing gives it its own.
    tbc::mut_a<Inspection> keepInspection(tbc::mut_a<State> state, std::string_view path) {
      if (state.inspections.size() >= ExplorerLimits::inspections) {
        std::size_t oldest = state.inspections.size();

        for (std::size_t index = 0; index < state.inspections.size(); ++index) {
          const auto& inspection = *state.inspections[index];
          if (inspection.waiting == 0 && (oldest == state.inspections.size() || inspection.used < state.inspections[oldest]->used)) {
            oldest = index;
          }
        }

        if (oldest != state.inspections.size()) {
          static_cast<void>(state.inspections.remove(oldest));
        }
      }

      auto& inspection = state.inspections.push(ds::makeBox<Inspection>(state.memory, state.memory)).getMut();

      inspection.asked.assign(path);
      inspection.used = ++state.clock;
      return inspection;
    }

  }

  Directory::Directory(Memory& memory)
      : path(memory),
        names(memory),
        entries(memory) {}

  std::string_view Directory::name(const Entry& entry) const noexcept {
    const auto part = names.view().subspan(entry.name, entry.name_size);

    return {part.data(), part.size()};
  }

  bool Directory::whole() const noexcept {
    return listed && entries.size() >= std::min<std::size_t>(total, ExplorerLimits::entries);
  }

  Repository::Repository(Memory& memory)
      : asked(memory),
        root(memory),
        branch(memory),
        text(memory),
        changes(memory) {}

  std::string_view Repository::path(const Change& change) const noexcept {
    const auto part = text.view().subspan(change.path, change.path_size);

    return {part.data(), part.size()};
  }

  Search::Search(Memory& memory)
      : root(memory),
        query(memory),
        text(memory),
        matches(memory) {}

  std::string_view Search::path(const Match& match) const noexcept {
    const auto part = text.view().subspan(match.path, match.path_size);

    return {part.data(), part.size()};
  }

  bool Search::of(std::string_view directory, std::string_view text_asked) const noexcept {
    return (known || waiting != 0) && root.view() == directory && query.view() == text_asked;
  }

  Inspection::Inspection(Memory& memory)
      : asked(memory),
        path(memory),
        target(memory),
        text(memory),
        subject(memory),
        diff(memory) {}

  State::State(Memory& made_in)
      : memory(made_in),
        directories(made_in),
        repository(made_in),
        inspections(made_in),
        search(made_in),
        home(made_in),
        outcomes(made_in),
        committed(made_in),
        carrying(made_in),
        carried(made_in) {}

  Carried::Carried(Memory& memory)
      : bytes(memory),
        text(memory) {}

  Standing standing(const Repository& repository, std::string_view path, bool directory) noexcept {
    const auto root = repository.root.view();
    if (root.empty() || !path.starts_with(root) || path.size() <= root.size() || path[root.size()] != '/') {
      return {};
    }

    // Past the root and its slash, which the test above found there.
    auto relative = path;

    relative.remove_prefix(root.size() + 1);

    Standing result;

    // A directory git ignores or does not track is named once, with a slash: what is below it
    // stands as it does.
    for (auto slash = relative.find('/'); slash != std::string_view::npos; slash = relative.find('/', slash + 1)) {
      if (const auto* above = exact(repository, {relative.data(), slash + 1})) {
        result.ignored = above->unstaged == FileState::ignored;
        result.unstaged = above->unstaged;
        return result;
      }
    }

    if (!directory) {
      if (const auto* change = exact(repository, relative)) {
        result = {.staged = change->staged, .unstaged = change->unstaged, .added = change->added, .removed = change->removed, .ignored = change->unstaged == FileState::ignored};
      }

      return result;
    }

    // Its own entry, `name/`, sorts first among the paths below it.
    const auto changes = repository.changes.view();
    auto found = std::ranges::lower_bound(changes, relative, {}, [&](const Change& change) {
      return repository.path(change);
    });

    for (; found != changes.end(); ++found) {
      const auto below = repository.path(*found);
      if (!below.starts_with(relative) || below.size() <= relative.size() || below[relative.size()] != '/') {
        // `name.ext` sorts between `name` and `name/`.
        if (below.starts_with(relative)) {
          continue;
        }

        break;
      }

      if (below.size() == relative.size() + 1) {
        result.ignored = found->unstaged == FileState::ignored;
        result.unstaged = found->unstaged;
      }

      if (changed(found->staged) || changed(found->unstaged)) {
        ++result.below;
      }
    }

    return result;
  }

  tbc::val_a<const Directory*> find(tbc::ref_a<State> state, std::string_view path) noexcept {
    for (const auto& directory : state.directories) {
      if (directory->path.view() == path) {
        return &directory.get();
      }
    }

    return nullptr;
  }

  tbc::val_a<const Inspection*> inspected(tbc::ref_a<State> state, std::string_view path) noexcept {
    const auto* inspection = inspectionOf(state, path);

    return inspection != nullptr && inspection->known ? inspection : nullptr;
  }

  bool mayAsk(const State& state) noexcept {
    return state.in_flight < ExplorerLimits::in_flight;
  }

  bool lacks(const State& state, const Need& need) noexcept {
    switch (need.kind) {
    case NeedKind::listing: {
      const auto* directory = find(state, need.path);

      return directory == nullptr || (directory->listing == 0 && !directory->failed && (directory->stale || !directory->whole()));
    }
    case NeedKind::sizes: {
      const auto* directory = find(state, need.path);

      return directory != nullptr && directory->listed && !directory->stale && directory->listing == 0 && directory->measuring == 0 && holdsUnmeasured(*directory);
    }
    case NeedKind::changes:
      return state.repository.waiting == 0 && (!state.repository.known || state.repository.stale || state.repository.asked.view() != need.path);
    case NeedKind::inspection:
      return inspectionOf(state, need.path) == nullptr;
    case NeedKind::search:
      // One search at a time: another root or query replaces it, the same one is not asked twice.
      return !state.search.of(need.path, need.text);
    case NeedKind::home:
      return !state.located && state.locating == 0;
    }

    return false;
  }

  tbc::val_a<ListDirectory> listing(const State& state, tbc::val_a<std::string_view> path) noexcept {
    const auto* directory = find(state, path);
    const auto held = directory == nullptr || directory->stale || !directory->listed ? 0 : directory->entries.size();

    return {.path = path, .skip = static_cast<std::uint32_t>(held), .limit = FileLimits::maximum_entries};
  }

  tbc::val_a<MeasureDirectory> measure(const State& state, tbc::val_a<std::string_view> path) noexcept {
    const auto* directory = find(state, path);

    return {.path = path, .skip = directory == nullptr ? 0 : directory->measured, .limit = FileLimits::maximum_entries};
  }

  tbc::val_a<FindPaths> search(const State& state, tbc::val_a<Need> need) noexcept {
    return {.root = need.path, .query = need.text, .kind = PathKindFilter::any, .limit = FindPaths::maximum_limit, .refresh = state.search.stale};
  }

  void asked(State& state, const Need& need, std::uint64_t request_id) {
    if (need.kind == NeedKind::search) {
      // Its answers keep coming while the index is read, and a later query ends it: it is no
      // request to wait for before asking for more. What the query before it found goes now,
      // so nothing of another query shows under this one.
      state.search.root.assign(need.path);
      state.search.query.assign(need.text);
      state.search.text.clear();
      state.search.matches.clear();
      state.search.waiting = request_id;
      state.search.known = false;
      state.search.truncated = false;
      state.search.stale = false;
      ++state.revision;
      return;
    }

    switch (need.kind) {
    case NeedKind::listing:
      keep(state, need.path).listing = request_id;
      break;
    case NeedKind::sizes:
      keep(state, need.path).measuring = request_id;
      break;
    case NeedKind::changes:
      state.repository.asked.assign(need.path);
      state.repository.waiting = request_id;
      break;
    case NeedKind::inspection: {
      auto& inspection = keepInspection(state, need.path);

      inspection.waiting = request_id;
      break;
    }
    case NeedKind::search:
      break;
    case NeedKind::home:
      state.locating = request_id;
      break;
    }

    ++state.in_flight;
  }

  void applying(State& state, std::uint64_t request_id, bool undo) noexcept {
    state.applying = request_id;
    state.undone = undo;
  }

  void committing(State& state, std::uint64_t request_id) noexcept {
    state.committing = request_id;
  }

  bool receive(State& state, const DirectoryContents& listing) {
    auto* directory = findMut(state, listing.path);
    if (directory == nullptr || directory->listing != listing.request_id) {
      return false;
    }

    // The first page replaces what was kept: of a first read, or of one that went stale.
    if (listing.skip == 0) {
      directory->entries.clear();
      directory->names.clear();
      directory->measured = 0;
    }

    for (const auto& entry : listing.entries) {
      if (directory->entries.size() == ExplorerLimits::entries) {
        break;
      }

      directory->entries.push({
          .name = static_cast<std::uint32_t>(directory->names.size()),
          .name_size = static_cast<std::uint16_t>(entry.name.size()),
          .kind = entry.kind,
          .directory = entry.directory,
          .size = entry.size,
          .identity = entry.identity,
      });

      directory->names.extend(std::span<const char>{entry.name});
    }

    // A page that brought nothing ends the reading, whatever the total says.
    directory->total = listing.entries.empty() ? static_cast<std::uint32_t>(directory->entries.size()) : listing.total;
    directory->listed = true;
    directory->failed = false;
    directory->stale = false;
    directory->listing = 0;
    directory->used = ++state.clock;
    settle(state);
    return true;
  }

  bool receive(State& state, const DirectorySizes& sizes) {
    auto* directory = findMut(state, sizes.path);
    if (directory == nullptr || directory->measuring != sizes.request_id) {
      return false;
    }

    // The sizes come in the listing's order, one for each directory of the page measured.
    std::size_t next = directory->measured;

    for (const auto& size : sizes.sizes) {
      for (std::size_t step = 0; step < directory->entries.size(); ++step) {
        const auto index = (next + step) % directory->entries.size();
        auto& entry = directory->entries.atMut(index);
        if (entry.kind == FileKind::directory && directory->name(entry) == size.name) {
          entry.size = size.bytes;
          entry.measured = true;
          entry.complete = size.complete;
          next = index + 1;
          break;
        }
      }
    }

    directory->measured = static_cast<std::uint32_t>(std::min<std::size_t>(directory->entries.size(), std::size_t{directory->measured} + FileLimits::maximum_entries));
    directory->measuring = 0;
    settle(state);
    return true;
  }

  bool receive(State& state, const RepositoryChanges& changes) {
    auto& repository = state.repository;
    if (repository.waiting == 0 || repository.waiting != changes.request_id) {
      return false;
    }

    repository.root.assign(changes.root);
    repository.branch.assign(changes.branch);
    repository.upstream = changes.upstream;
    repository.ahead = changes.ahead;
    repository.behind = changes.behind;
    repository.truncated = changes.truncated;
    repository.text.clear();
    repository.changes.clear();
    repository.staged = 0;
    repository.unstaged = 0;
    repository.untracked = 0;
    for (const auto& change : changes.changes) {
      repository.changes.push({
          .path = static_cast<std::uint32_t>(repository.text.size()),
          .path_size = static_cast<std::uint16_t>(change.path.size()),
          .staged = change.staged,
          .unstaged = change.unstaged,
          .added = change.added,
          .removed = change.removed,
      });

      repository.text.extend(std::span<const char>{change.path});
      repository.staged += changed(change.staged) ? 1 : 0;
      repository.untracked += change.unstaged == FileState::untracked ? 1 : 0;
      repository.unstaged += changed(change.unstaged) && change.unstaged != FileState::untracked ? 1 : 0;
    }

    std::ranges::sort(repository.changes.viewMut(), {}, [&](const Change& change) {
      return repository.path(change);
    });

    repository.known = true;
    repository.stale = false;
    repository.waiting = 0;
    settle(state);
    return true;
  }

  bool receive(State& state, const FileInspection& inspection) {
    Inspection* awaited = nullptr;

    for (auto& candidate : state.inspections.viewMut()) {
      if (candidate->waiting != 0 && candidate->waiting == inspection.request_id) {
        awaited = &candidate.getMut();
      }
    }

    if (awaited == nullptr) {
      return false;
    }

    auto& kept = *awaited;

    kept.path.assign(inspection.path);
    kept.kind = inspection.kind;
    kept.size = inspection.size;
    kept.identity = inspection.identity;
    kept.target.assign(inspection.target);
    kept.binary = inspection.binary;
    kept.truncated = inspection.truncated;
    kept.text.assign(inspection.text);
    kept.commit.assign(inspection.commit);
    kept.committed_seconds = inspection.committed_seconds;
    kept.subject.assign(inspection.subject);
    kept.diff.assign(inspection.diff);
    kept.known = true;
    kept.waiting = 0;
    if (state.in_flight != 0) {
      --state.in_flight;
    }

    ++state.previews;
    return true;
  }

  namespace {

    // A place for the answer to `request`, when a transfer waits for it.
    tbc::val_a<Carried*> keepCarried(tbc::mut_a<State> state, std::uint64_t request, CarriedKind kind) {
      if (!std::ranges::contains(state.carrying, request)) {
        return nullptr;
      }

      state.carrying.retain([&](std::uint64_t waited) {
        return waited != request;
      });

      auto& kept = state.carried.push(Carried{state.memory});

      kept.request = request;
      kept.kind = kind;
      return &kept;
    }

  }

  void carrying(State& state, std::uint64_t request_id) {
    state.carrying.push(request_id);
  }

  bool receive(State& state, const FileChunk& chunk) {
    auto* kept = keepCarried(state, chunk.request_id, CarriedKind::chunk);
    if (kept == nullptr) {
      return false;
    }

    kept->offset = chunk.offset;
    kept->size = chunk.size;
    kept->end = chunk.end;
    kept->bytes.extend(chunk.bytes);
    return true;
  }

  bool receive(State& state, const FileWritten& written) {
    auto* kept = keepCarried(state, written.request_id, CarriedKind::written);
    if (kept == nullptr) {
      return false;
    }

    kept->size = written.size;
    kept->text.assign(written.partial);
    return true;
  }

  bool receive(State& state, const FileWriteEnded& ended) {
    auto* kept = keepCarried(state, ended.request_id, CarriedKind::ended);
    if (kept == nullptr) {
      return false;
    }

    kept->outcome = ended.outcome;
    kept->text.assign(ended.path);
    // The directory it arrived in lists one entry more.
    if (!ended.path.empty()) {
      invalidate(state, ended.path.substr(0, std::max<std::size_t>(ended.path.find_last_of('/'), 1)));
      ++state.revision;
    }

    return true;
  }

  ds::Option<Carried> carried(State& state, std::uint64_t request_id) {
    for (std::size_t index = 0; index < state.carried.size(); ++index) {
      if (state.carried[index].request == request_id) {
        return state.carried.remove(index);
      }
    }

    return ds::none;
  }

  bool receive(State& state, const FilesChanged& changed) {
    // The source of a file that moved to another machine, sent to the trash once it arrived.
    if (auto* kept = keepCarried(state, changed.request_id, CarriedKind::trashed)) {
      kept->outcome = changed.results.empty() ? FileOutcome::failed : changed.results.front().outcome;
      invalidate(state, {});
      ++state.revision;
      return true;
    }

    if (state.applying == 0 || state.applying != changed.request_id) {
      return false;
    }

    state.outcomes.clear();
    for (const auto& result : changed.results) {
      state.outcomes.push({.outcome = result.outcome, .path = ds::String<Memory>{state.memory, result.path}});
    }

    state.undoable = changed.undoable;
    state.applying = 0;
    state.error.assign({});
    ++state.settled;
    invalidate(state, {});
    ++state.revision;
    return true;
  }

  bool receive(State& state, const ChangesCommitted& committed) {
    if (state.committing == 0 || state.committing != committed.request_id) {
      return false;
    }

    state.committed.clear();
    ds::formatTo(state.committed, "{} {}", committed.commit, committed.subject);
    state.committing = 0;
    state.error.assign({});
    state.repository.stale = true;
    ++state.settled;
    ++state.revision;
    return true;
  }

  bool receive(State& state, const HomeLocated& located) {
    if (state.locating == 0 || state.locating != located.request_id) {
      return false;
    }

    state.home.assign(located.path);
    state.located = true;
    state.locating = 0;
    settle(state);
    return true;
  }

  bool receive(State& state, const PathResults& results) {
    auto& search = state.search;
    if (results.request_id == 0 || results.request_id != search.waiting || results.root != search.root.view()) {
      return false;
    }

    search.text.clear();
    search.matches.clear();
    for (const auto& match : results.matches) {
      // A path too long for a row's text is left out; the runtime sends none that long.
      if (match.path.empty() || match.path.size() > std::numeric_limits<std::uint16_t>::max()) {
        continue;
      }

      search.matches.push({
          .path = static_cast<std::uint32_t>(search.text.size()),
          .path_size = static_cast<std::uint16_t>(match.path.size()),
          .directory = match.kind == PathKind::directory,
          .state = stateOf(match.change),
      });

      search.text.extend(std::span<const char>{match.path});
    }

    search.known = true;
    search.truncated = results.truncated;
    search.waiting = results.complete ? 0 : search.waiting;
    ++state.revision;
    return true;
  }

  bool fail(State& state, const RequestFailed& failure) {
    const auto request = failure.request_id;
    bool ours = false;

    if (auto* kept = keepCarried(state, request, CarriedKind::failed)) {
      kept->text.assign(runtime::utf8Prefix(failure.message, ExplorerLimits::error_bytes));
      return true;
    }

    // A search the runtime refused found nothing, and is not asked again as it is.
    if (request != 0 && state.search.waiting == request) {
      state.search.waiting = 0;
      state.search.known = true;
      state.search.text.clear();
      state.search.matches.clear();
      ++state.revision;
      return true;
    }

    for (auto& directory : state.directories.viewMut()) {
      if (directory->listing == request) {
        directory.getMut().listing = 0;
        directory.getMut().failed = true;
        directory.getMut().listed = true;
        directory.getMut().stale = false;
        directory.getMut().entries.clear();
        directory.getMut().names.clear();
        directory.getMut().total = 0;
        ours = true;
      } else if (directory->measuring == request) {
        // What could not be measured is not asked for again.
        directory.getMut().measuring = 0;
        directory.getMut().measured = static_cast<std::uint32_t>(directory->entries.size());
        ours = true;
      }
    }

    if (state.repository.waiting == request) {
      state.repository.waiting = 0;
      state.repository.known = true;
      state.repository.stale = false;
      state.repository.root.clear();
      state.repository.changes.clear();
      ours = true;
    }

    for (auto& inspection : state.inspections.viewMut()) {
      if (inspection->waiting == request) {
        inspection.getMut().waiting = 0;
        inspection.getMut().known = true;
        inspection.getMut().path.clear();
        ours = true;
      }
    }

    // A runtime that does not say its home is not asked again: `~` stands for nothing there.
    if (request != 0 && state.locating == request) {
      state.locating = 0;
      state.located = true;
      ours = true;
    }

    if (ours) {
      settle(state);
      return true;
    }

    if (request == 0 || (state.applying != request && state.committing != request)) {
      return false;
    }

    state.applying = state.applying == request ? 0 : state.applying;
    state.committing = state.committing == request ? 0 : state.committing;
    state.error.assign(runtime::utf8Prefix(failure.message, ExplorerLimits::error_bytes));
    ++state.settled;
    ++state.revision;
    return true;
  }

  void invalidate(State& state, std::string_view path) noexcept {
    for (auto& directory : state.directories.viewMut()) {
      if (path.empty() || directory->path.view() == path) {
        directory.getMut().stale = true;
        directory.getMut().failed = false;
      }
    }

    state.repository.stale = true;
    // What a filter found may name what is gone: it is asked again.
    if (state.search.known || state.search.waiting != 0) {
      state.search.known = false;
      state.search.waiting = 0;
      state.search.stale = true;
    }

    // A preview in flight is still answered; the ones kept are asked for again.
    state.inspections.retain([&](const ds::Box<Inspection, Memory>& inspection) {
      return inspection->waiting != 0 || (!path.empty() && !inspection->asked.view().starts_with(path));
    });
  }

  void reset(State& state) noexcept {
    for (auto& directory : state.directories.viewMut()) {
      directory.getMut().listing = 0;
      directory.getMut().measuring = 0;
      directory.getMut().stale = true;
    }

    state.repository.waiting = 0;
    state.repository.stale = true;
    state.search.waiting = 0;
    state.search.known = false;
    state.locating = 0;
    state.inspections.clear();
    state.applying = 0;
    state.committing = 0;
    state.in_flight = 0;
    // What a transfer asked of the connection that ended is answered by none.
    state.carrying.clear();
    state.carried.clear();
    ++state.epoch;
  }

}
