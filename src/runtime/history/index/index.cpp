module telar.runtime.history.index;

import std;
import telar.base.history;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    std::uint64_t combine(std::uint64_t left, std::uint64_t right) noexcept {
      constexpr std::uint64_t multiplier = 0x9e3779b97f4a7c15;

      constexpr unsigned high_shift = 6;
      constexpr unsigned low_shift = 2;

      return (left ^ (right + multiplier + (left << high_shift) + (left >> low_shift))) * multiplier;
    }

    bool cancelledBy(const std::atomic<bool>* cancelled) noexcept {
      return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
    }

  }

  HistoryIndex::Interner::Interner(ConcurrentMemory& memory)
      : memory_(memory),
        ids_(memory) {}

  std::uint32_t HistoryIndex::Interner::intern(std::string_view text) {
    if (text.empty()) {
      return 0;
    }

    if (const auto* found = ids_.find(text)) {
      return *found;
    }

    const auto id = static_cast<std::uint32_t>(ids_.size() + 1);

    ids_.insert(ds::String<ConcurrentMemory>{memory_, text}, id);
    return id;
  }

  ds::Option<std::uint32_t> HistoryIndex::Interner::find(std::string_view text) const {
    if (text.empty()) {
      return 0U;
    }

    if (const auto* found = ids_.find(text)) {
      return *found;
    }

    return ds::none;
  }

  std::uint32_t HistoryIndex::Interner::size() const noexcept {
    return static_cast<std::uint32_t>(ids_.size() + 1);
  }

  void HistoryIndex::Interner::clear() noexcept {
    ids_.clear();
  }

  HistoryIndex::HistoryIndex(ConcurrentMemory& memory, std::size_t workers)
      : memory_(memory),
        pool_(workers),
        ids_(memory),
        started_(memory),
        texts_(memory),
        places_(memory),
        contexts_(memory),
        durations_ms_(memory),
        exits_(memory),
        flags_(memory),
        order_(memory),
        records_(memory),
        text_bytes_(memory),
        by_text_id_(memory),
        strings_(memory),
        group_names_(memory),
        group_texts_(memory),
        place_table_(memory),
        place_ids_(memory),
        context_table_(memory),
        context_ids_(memory),
        pane_started_(memory),
        pane_last_(memory),
        follow_counts_(memory),
        stamps_(memory),
        stamped_scores_(memory),
        listed_(memory),
        hits_(memory),
        ranked_(memory),
        keys_(memory),
        scratch_(memory),
        groups_(memory) {
    reset();
  }

  HistoryIndex::~HistoryIndex() = default;

  bool HistoryIndex::complete() const noexcept {
    return !loading_ && !overflowed_;
  }

  bool HistoryIndex::overflowed() const noexcept {
    return overflowed_;
  }

  void HistoryIndex::reset() noexcept {
    for (auto* column : {&ids_, &started_}) {
      column->clear();
    }

    for (auto* column : {&texts_, &places_, &contexts_, &durations_ms_, &order_}) {
      column->clear();
    }

    exits_.clear();
    flags_.clear();
    records_.clear();
    text_bytes_.clear();
    by_text_id_.clear();
    strings_.clear();
    group_names_.clear();
    group_texts_.clear();
    place_table_.clear();
    place_ids_.clear();
    context_table_.clear();
    context_ids_.clear();
    pane_last_.clear();
    follow_counts_.clear();
    for (auto& entry : cache_.viewMut()) {
      entry.reset();
    }

    ordered_ = true;
    order_stale_ = false;
    live_runs_ = 0;
    live_texts_ = 0;
    loading_ = true;
    overflowed_ = false;
    loaded_through_ = 0;
  }

  bool HistoryIndex::load(const HistoryRunFacts& run) {
    if (overflowed_) {
      return false;
    }

    if (!append(run)) {
      overflowed_ = true;
      return false;
    }

    loaded_through_ = run.id;
    return true;
  }

  std::int64_t HistoryIndex::loadedThrough() const noexcept {
    return loaded_through_;
  }

  void HistoryIndex::loaded() noexcept {
    loading_ = false;
  }

  ds::Option<std::uint32_t> HistoryIndex::internText(const HistoryRunFacts& run) {
    if (const auto* found = by_text_id_.find(run.text_id)) {
      return *found;
    }

    // The matcher folds what it compares itself: the text alone is kept.
    const auto bytes = run.text.size();

    if (records_.size() >= maximum_texts || bytes > maximum_text_bytes - std::min(maximum_text_bytes, text_bytes_.size())) {
      return ds::none;
    }

    TextRecord record{.text_id = run.text_id, .offset = text_bytes_.size(), .length = static_cast<std::uint32_t>(run.text.size())};

    text_bytes_.extend(std::span{run.text});
    record.folded_offset = record.offset;
    record.folded_length = record.length;

    // A group longer than a stats entry carries, a 16-bit length, counts under what of it fits.
    constexpr std::size_t group_bytes = std::numeric_limits<std::uint16_t>::max();
    const auto group = utf8Prefix(historyGroup(run.text), group_bytes);

    const auto index = static_cast<std::uint32_t>(records_.size());

    record.group = group_names_.intern(group);
    if (record.group >= group_texts_.size()) {
      group_texts_.resize(record.group + 1);
      group_texts_.atMut(record.group) = index;
    }

    records_.push(record);
    by_text_id_.insert(run.text_id, index);
    return index;
  }

  bool HistoryIndex::append(const HistoryRunFacts& run) {
    if (ids_.size() >= maximum_runs) {
      return false;
    }

    const auto text = internText(run);
    if (!text) {
      return false;
    }

    const auto slot = ids_.size();

    ids_.push(run.id);
    started_.push(run.started_ms);
    texts_.push(*text);
    places_.push(0);
    contexts_.push(0);
    durations_ms_.push(0);
    exits_.push(0);
    flags_.push(0);
    assign(slot, run, *text);
    if (!ordered_ && !order_stale_) {
      if (order_.empty() || run.started_ms >= started_[order_.back()]) {
        order_.push(static_cast<std::uint32_t>(slot));
      } else {
        order_stale_ = true;
      }
    } else if (ordered_ && slot != 0 && run.started_ms < started_[slot - 1]) {
      // An imported run older than the ones before it: the ids no longer give the order of time.
      ordered_ = false;
      order_stale_ = true;
    }

    count(slot);
    follow(run.pane, *text);
    return true;
  }

  void HistoryIndex::assign(std::size_t slot, const HistoryRunFacts& run, std::uint32_t text) {
    constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;
    const Place place{.cwd = strings_.intern(run.cwd_key), .workspace = strings_.intern(run.workspace_key), .branch = strings_.intern(run.branch)};
    const auto place_key = combine(combine(place.cwd, place.workspace), place.branch);
    std::uint32_t place_id = 0;

    if (const auto* found = place_ids_.find(place_key); found != nullptr && place_table_[*found].cwd == place.cwd && place_table_[*found].workspace == place.workspace && place_table_[*found].branch == place.branch) {
      place_id = *found;
    } else {
      place_id = static_cast<std::uint32_t>(place_table_.size());
      place_table_.push(place);
      place_ids_.assign(place_key, place_id);
    }

    const Context context{.pane = run.pane, .host = strings_.intern(run.host), .shell = strings_.intern(historyShellName(run.shell))};
    const auto context_key = combine(combine(context.pane, context.host), context.shell);
    std::uint32_t context_id = 0;

    if (const auto* found = context_ids_.find(context_key); found != nullptr && context_table_[*found].pane == context.pane && context_table_[*found].host == context.host && context_table_[*found].shell == context.shell) {
      context_id = *found;
    } else {
      context_id = static_cast<std::uint32_t>(context_table_.size());
      context_table_.push(context);
      context_ids_.assign(context_key, context_id);
    }

    auto flags = static_cast<std::uint8_t>(static_cast<unsigned>(run.status) << status_shift);

    if (run.author == HistoryAuthor::agent) {
      flags |= flag_agent;
    }

    if (run.exit_code) {
      flags |= flag_has_exit;
    }

    if (run.duration_ns > 0 && run.status != HistoryStatus::running) {
      flags |= flag_measured;
    }

    texts_.atMut(slot) = text;
    places_.atMut(slot) = place_id;
    contexts_.atMut(slot) = context_id;
    durations_ms_.atMut(slot) = static_cast<std::uint32_t>(std::clamp<std::int64_t>(run.duration_ns / nanoseconds_per_millisecond, 0, std::numeric_limits<std::uint32_t>::max()));
    exits_.atMut(slot) = run.exit_code.valueOr(0);
    flags_.atMut(slot) = flags;
    records_.atMut(text).selected = std::max(records_[text].selected, run.selected);
  }

  HistoryStatus HistoryIndex::statusAt(std::size_t run) const noexcept {
    constexpr unsigned status_mask = 0x3U;

    return static_cast<HistoryStatus>((static_cast<unsigned>(flags_[run]) >> status_shift) & status_mask);
  }

  ds::Option<std::int32_t> HistoryIndex::exitAt(std::size_t run) const noexcept {
    if ((flags_[run] & flag_has_exit) == 0) {
      return ds::none;
    }

    return exits_[run];
  }

  void HistoryIndex::count(std::size_t run) noexcept {
    tally(run, 1);

    auto& record = records_.atMut(texts_[run]);

    if (record.runs++ == 0) {
      ++live_texts_;
    }

    ++live_runs_;
    if (record.runs == 1 || started_[run] > record.last_ms || (started_[run] == record.last_ms && ids_[run] >= record.last_id)) {
      const auto exit = exitAt(run);

      record.last_ms = started_[run];
      record.last_id = ids_[run];
      record.last_exit = exit.valueOr(0);
      record.last_has_exit = exit.hasValue();
      record.last_failed = historyFailed(exit, statusAt(run));
    }

    const auto remember = [](auto& recent, std::uint32_t value) {
      const auto found = std::ranges::find(recent.view(), value);
      const auto end = found == recent.view().end() ? recent.size() - 1 : static_cast<std::size_t>(found - recent.view().begin());

      for (auto slot = end; slot > 0; --slot) {
        recent.atMut(slot) = recent[slot - 1];
      }

      recent.atMut(0) = value;
    };

    remember(record.recent_places, places_[run]);
    remember(record.recent_contexts, contexts_[run]);
  }

  void HistoryIndex::tally(std::size_t run, int sign) noexcept {
    const auto step = static_cast<std::uint32_t>(sign);
    const auto exit = exitAt(run);
    const bool ended = exit && statusAt(run) == HistoryStatus::completed;
    auto& record = records_.atMut(texts_[run]);

    if ((flags_[run] & flag_measured) != 0) {
      record.measured += step;
      record.measured_ms += static_cast<std::uint64_t>(static_cast<std::int64_t>(sign) * durations_ms_[run]);
    }

    if (ended) {
      record.ended += step;
      record.succeeded += *exit == 0 ? step : 0;
    }
  }

  void HistoryIndex::uncount(std::size_t run) noexcept {
    tally(run, -1);

    auto& record = records_.atMut(texts_[run]);

    --live_runs_;
    if (--record.runs == 0) {
      --live_texts_;
      return;
    }

    if (record.last_id == ids_[run]) {
      flags_.atMut(run) |= flag_deleted;
      recomputeLast(texts_[run]);
      flags_.atMut(run) &= static_cast<std::uint8_t>(~flag_deleted);
    }
  }

  void HistoryIndex::recomputeLast(std::uint32_t text) noexcept {
    auto& record = records_.atMut(text);
    bool found = false;

    for (std::size_t run = 0; run < ids_.size(); ++run) {
      if (texts_[run] != text || (flags_[run] & flag_deleted) != 0) {
        continue;
      }

      if (!found || started_[run] > record.last_ms || (started_[run] == record.last_ms && ids_[run] > record.last_id)) {
        const auto exit = exitAt(run);

        found = true;
        record.last_ms = started_[run];
        record.last_id = ids_[run];
        record.last_exit = exit.valueOr(0);
        record.last_has_exit = exit.hasValue();
        record.last_failed = historyFailed(exit, statusAt(run));
      }
    }
  }

  ds::Option<std::size_t> HistoryIndex::position(std::int64_t id) const noexcept {
    const auto found = std::ranges::lower_bound(ids_.view(), id);
    if (found == ids_.view().end() || *found != id) {
      return ds::none;
    }

    return static_cast<std::size_t>(found - ids_.view().begin());
  }

  void HistoryIndex::upsert(const HistoryRunFacts& run) {
    // A run past what the load read is one it reads yet, as it is now.
    if (loading_ && run.id > loaded_through_) {
      return;
    }

    if (overflowed_) {
      return;
    }

    if (const auto slot = position(run.id)) {
      const bool live = (flags_[*slot] & flag_deleted) == 0;
      if (live) {
        uncount(*slot);
      }

      const auto text = internText(run);
      if (!text) {
        overflowed_ = true;
        return;
      }

      // A run deleted and written again under its id lives again.
      assign(*slot, run, *text);
      count(*slot);
      return;
    }

    if (!ids_.empty() && run.id < ids_.back()) {
      // Never written: ids grow. A run the index cannot place leaves it to load again.
      overflowed_ = true;
      return;
    }

    if (!append(run)) {
      overflowed_ = true;
    }
  }

  void HistoryIndex::remove(std::int64_t id) {
    if (loading_ && id > loaded_through_) {
      return;
    }

    const auto run = position(id);
    if (!run || (flags_[*run] & flag_deleted) != 0) {
      return;
    }

    uncount(*run);
    flags_.atMut(*run) |= flag_deleted;
  }

  void HistoryIndex::removeText(std::int64_t text_id) {
    const auto* found = by_text_id_.find(text_id);
    if (found == nullptr) {
      return;
    }

    const auto text = *found;

    for (std::size_t run = 0; run < ids_.size(); ++run) {
      if (texts_[run] == text && (flags_[run] & flag_deleted) == 0) {
        flags_.atMut(run) |= flag_deleted;
        --live_runs_;
      }
    }

    if (records_[text].runs != 0) {
      --live_texts_;
    }

    // The record stays, matched by nothing; a text stored again later under its id is new.
    auto& record = records_.atMut(text);

    record.runs = 0;
    record.measured = 0;
    record.measured_ms = 0;
    record.ended = 0;
    record.succeeded = 0;
    by_text_id_.remove(text_id);
  }

  void HistoryIndex::session(std::uint64_t pane, std::int64_t started_ms) {
    constexpr std::size_t maximum_panes = std::size_t{1} << 16U;

    if (auto* known = pane_started_.findMut(pane)) {
      *known = std::min(*known, started_ms);
    } else if (pane_started_.size() < maximum_panes) {
      pane_started_.insert(pane, started_ms);
    }
  }

  void HistoryIndex::select(std::int64_t text_id) {
    if (const auto* found = by_text_id_.find(text_id)) {
      ++records_.atMut(*found).selected;
    }
  }

  void HistoryIndex::follow(std::uint64_t pane, std::uint32_t text) {
    constexpr std::size_t maximum_panes = std::size_t{1} << 16U;

    if (pane == 0) {
      return;
    }

    if (const auto* previous = pane_last_.find(pane)) {
      const auto key = combine(historyTemplateKey(this->text(*previous).original), text);

      if (auto* counted = follow_counts_.findMut(key)) {
        *counted = std::min(*counted + 1, std::numeric_limits<std::uint32_t>::max() - 1);
      } else if (follow_counts_.size() < follow_entries) {
        follow_counts_.insert(key, 1);
      }
    }

    if (auto* last = pane_last_.findMut(pane)) {
      *last = text;
    } else if (pane_last_.size() < maximum_panes) {
      pane_last_.insert(pane, text);
    }
  }

  std::uint32_t HistoryIndex::follows(std::uint64_t pane, std::uint32_t text) const noexcept { // NOLINT(bugprone-easily-swappable-parameters): a pane id and a text index, of different widths
    const auto* previous = pane_last_.find(pane);
    if (previous == nullptr) {
      return 0;
    }

    const auto* counted = follow_counts_.find(combine(historyTemplateKey(this->text(*previous).original), text));

    return counted == nullptr ? 0 : *counted;
  }

  HistoryText HistoryIndex::text(std::uint32_t text) const noexcept {
    const auto& record = records_[text];
    const auto bytes = text_bytes_.view();
    const auto original = bytes.subspan(record.offset, record.length);
    const auto folded = bytes.subspan(record.folded_offset, record.folded_length);

    return {.original = {original.data(), original.size()}, .folded = {folded.data(), folded.size()}};
  }

  std::int64_t HistoryIndex::newestId() const noexcept {
    return ids_.empty() ? 0 : ids_.back();
  }

  void HistoryIndex::ensureOrder() {
    if (ordered_ || !order_stale_) {
      return;
    }

    order_.resize(ids_.size());
    for (std::size_t run = 0; run < order_.size(); ++run) {
      order_.atMut(run) = static_cast<std::uint32_t>(run);
    }

    std::ranges::sort(order_.viewMut(), [&](std::uint32_t left, std::uint32_t right) {
      return started_[left] == started_[right] ? ids_[left] < ids_[right] : started_[left] < started_[right];
    });

    order_stale_ = false;
  }

  std::uint32_t HistoryIndex::candidateText(std::span<const Scored> candidates, std::size_t first_new, std::size_t item) noexcept {
    return item < candidates.size() ? candidates[item].text : static_cast<std::uint32_t>(first_new + (item - candidates.size()));
  }

  void HistoryIndex::matchInto(const HistoryMatcher& matcher, std::span<const Scored> candidates, std::size_t first_new, ds::Vec<Scored, ConcurrentMemory>& out, const std::atomic<bool>* cancelled) {
    const auto fresh = records_.size() - std::min(first_new, records_.size());
    const auto total = candidates.size() + fresh;

    // One scratch per worker, made once: each holds the matcher's arena.
    while (scratch_.size() < pool_.workers()) {
      scratch_.emplace(memory_);
    }

    if (total < parallel_threshold) {
      for (std::size_t item = 0; item < total; ++item) {
        if ((item % chunk_texts) == 0 && cancelledBy(cancelled)) {
          return;
        }

        const auto text = candidateText(candidates, first_new, item);

        if (const auto score = scoreText(matcher, records_[text].runs, this->text(text), scratch_.atMut(0)); score != 0) {
          out.push({.text = text, .score = score});
        }
      }

      return;
    }

    matchInParallel(matcher, candidates, first_new, total, cancelled);
    if (cancelledBy(cancelled)) {
      return;
    }

    for (std::size_t item = 0; item < total; ++item) {
      if (keys_[item] != 0) {
        out.push({.text = candidateText(candidates, first_new, item), .score = static_cast<std::uint32_t>(keys_[item])});
      }
    }
  }

  std::uint32_t HistoryIndex::scoreText(const HistoryMatcher& matcher, std::uint32_t runs, HistoryText text, HistoryMatchWork& scratch) noexcept {
    if (runs == 0) {
      return 0;
    }

    // A match that scores nothing, as one of exclusions only does, still matched.
    const auto score = matcher.score(text, scratch);

    return score ? std::max<std::uint32_t>(*score, 1) : 0;
  }

  void HistoryIndex::matchInParallel(const HistoryMatcher& matcher, std::span<const Scored> candidates, std::size_t first_new, std::size_t total, const std::atomic<bool>* cancelled) { // NOLINT(bugprone-easily-swappable-parameters): the first new text, then how many candidates there are in all
    // Each chunk writes the scores of its own slice, so no two threads write one place.
    keys_.resize(total);
    const auto chunks = (total + chunk_texts - 1) / chunk_texts;
    auto work = [&](std::size_t worker, std::size_t chunk) {
      if (cancelledBy(cancelled)) {
        return;
      }

      const auto first = chunk * chunk_texts;
      const auto last = std::min(total, first + chunk_texts);
      auto& scratch = scratch_.atMut(worker);

      for (auto item = first; item < last; ++item) {
        const auto text = candidateText(candidates, first_new, item);

        keys_.atMut(item) = scoreText(matcher, records_[text].runs, this->text(text), scratch);
      }
    };

    pool_.run(chunks, work);
  }

  ds::Option<std::size_t> HistoryIndex::cachedEntry(const HistoryMatcher& matcher) const noexcept {
    for (std::size_t index = 0; index < cache_.size(); ++index) {
      if (cache_[index] && cache_[index]->mode == matcher.mode() && cache_[index]->query.view() == matcher.query()) {
        return index;
      }
    }

    return ds::none;
  }

  ds::Option<std::size_t> HistoryIndex::narrowerEntry(const HistoryMatcher& matcher) const noexcept {
    ds::Option<std::size_t> narrower;

    for (std::size_t index = 0; index < cache_.size(); ++index) {
      const auto& entry = cache_[index];
      const bool fewer = !narrower || (entry && entry->scored.size() < cache_[*narrower]->scored.size());

      if (entry && !entry->query.empty() && matcher.narrows(entry->mode, entry->query.view()) && fewer) {
        narrower = index;
      }
    }

    return narrower;
  }

  std::size_t HistoryIndex::freeCacheSlot() const noexcept {
    std::size_t slot = 0;

    for (std::size_t index = 0; index < cache_.size(); ++index) {
      if (!cache_[index]) {
        return index;
      }

      if (cache_[index]->used < cache_[slot]->used) {
        slot = index;
      }
    }

    return slot;
  }

  void HistoryIndex::boundCache(std::size_t slot, std::size_t incoming) noexcept { // NOLINT(bugprone-easily-swappable-parameters): the slot that takes a match, then its size
    std::size_t held = incoming;

    for (std::size_t index = 0; index < cache_.size(); ++index) {
      if (index != slot && cache_[index]) {
        held += cache_[index]->scored.size();
      }
    }

    while (held > cache_scored) {
      std::size_t oldest = cache_.size();

      for (std::size_t index = 0; index < cache_.size(); ++index) {
        const bool older = oldest == cache_.size() || (cache_[index] && cache_[index]->used < cache_[oldest]->used);

        if (index != slot && cache_[index] && older) {
          oldest = index;
        }
      }

      if (oldest == cache_.size()) {
        return;
      }

      held -= cache_[oldest]->scored.size();
      cache_.atMut(oldest).reset();
    }
  }

  std::span<const HistoryIndex::Scored> HistoryIndex::match(const HistoryMatcher& matcher, const std::atomic<bool>* cancelled) {
    ++cache_clock_;
    // The same query again, as after a backspace: its matches, and those among the texts since.
    if (const auto index = cachedEntry(matcher)) {
      if (cache_[*index]->count < records_.size()) {
        // Taken out while it grows, as the matching reads the index it is part of.
        auto scored = std::move(cache_.atMut(*index).getMut().scored);
        const auto counted = cache_[*index]->count;

        matchInto(matcher, {}, counted, scored, cancelled);
        if (cancelledBy(cancelled)) {
          cache_.atMut(*index).reset();
          return {};
        }

        cache_.atMut(*index).getMut().scored = std::move(scored);
        cache_.atMut(*index).getMut().count = records_.size();
      }

      cache_.atMut(*index).getMut().used = cache_clock_;
      return cache_[*index]->scored.view();
    }

    // A query typed further than one cached matches only what that one matched; it takes the
    // slot of the entry used least lately.
    const auto narrower = narrowerEntry(matcher);
    const auto slot = freeCacheSlot();
    CachedMatch found{.mode = matcher.mode(), .query = ds::String<ConcurrentMemory>{memory_, matcher.query()}, .count = records_.size(), .scored = ds::Vec<Scored, ConcurrentMemory>{memory_}, .used = cache_clock_};

    if (narrower) {
      // A copy of what it matched, as the matching reads the index the cache is part of.
      ds::Vec<Scored, ConcurrentMemory> earlier{memory_};
      const auto earlier_count = cache_[*narrower]->count;

      earlier.extend(cache_[*narrower]->scored.view());
      matchInto(matcher, earlier.view(), earlier_count, found.scored, cancelled);
    } else {
      matchInto(matcher, {}, 0, found.scored, cancelled);
    }

    if (cancelledBy(cancelled)) {
      return {};
    }

    // Bounded: the cache holds run most cache_scored matches across its entries.
    boundCache(slot, found.scored.size());
    cache_.atMut(slot).emplace(std::move(found));
    return cache_[slot]->scored.view();
  }

  std::uint32_t HistoryIndex::nextListing() {
    if (listed_.size() < records_.size()) {
      listed_.resize(records_.size());
    }

    if (++listed_stamp_ == 0) {
      std::ranges::fill(listed_.viewMut(), 0);
      listed_stamp_ = 1;
    }

    return listed_stamp_;
  }

  std::size_t HistoryIndex::runAt(std::size_t rank) const noexcept {
    const auto from_end = ids_.size() - 1 - rank;

    return ordered_ ? from_end : order_[from_end];
  }

  std::uint32_t HistoryIndex::scoreOf(const Filter& filter, std::uint32_t text) const noexcept {
    if (filter.all_texts) {
      return 1;
    }

    return stamps_[text] == stamp_ ? stamped_scores_[text] : 0;
  }

  bool HistoryIndex::passes(const HistoryIndexQuery& query, const Filter& filter, std::size_t run) const noexcept {
    const auto flags = flags_[run];
    if ((flags & flag_deleted) != 0 || ids_[run] > filter.snapshot) {
      return false;
    }

    if (!filter.any) {
      return true;
    }

    if (query.author != HistoryAuthorFilter::all && ((flags & flag_agent) != 0) != (query.author == HistoryAuthorFilter::agent)) {
      return false;
    }

    const auto exit = exitAt(run);

    if ((query.failed_only && !historyFailed(exit, statusAt(run))) || (query.exit_code && exit != query.exit_code)) {
      return false;
    }

    if ((query.since_ms != 0 && started_[run] < query.since_ms) || (query.until_ms != 0 && started_[run] >= query.until_ms)) {
      return false;
    }

    if (query.min_duration_ms > 0 && std::cmp_less(durations_ms_[run], query.min_duration_ms)) {
      return false;
    }

    const auto& place = place_table_[places_[run]];
    const auto& context = context_table_[contexts_[run]];

    if ((!query.host.empty() && context.host != filter.host) || (!query.shell.empty() && context.shell != filter.shell) || (!query.branch.empty() && place.branch != filter.branch)) {
      return false;
    }

    switch (query.scope) {
    case HistoryScope::global:
      return true;
    case HistoryScope::cwd:
      return place.cwd == filter.scope_key;
    case HistoryScope::workspace:
      return place.workspace == filter.scope_key;
    case HistoryScope::pane:
      return context.pane == query.scope_pane || (query.preload && started_[run] < filter.pane_start);
    }

    return true;
  }

  HistoryPriors HistoryIndex::features(const HistoryIndexQuery& query, const Filter& filter, std::uint32_t text, ds::Option<std::size_t> run) const noexcept {
    const auto& record = records_[text];
    HistoryPriors result{.runs = record.runs, .last_ms = record.last_ms, .now_ms = query.now_ms, .recent_failure = record.last_failed, .selected = record.selected};
    const auto place = run ? places_[*run] : none;
    const auto context = run ? contexts_[*run] : none;
    const auto cwd_is = [&](std::uint32_t value) {
      return place_table_[value].cwd == filter.origin_cwd;
    };

    const auto workspace_is = [&](std::uint32_t value) {
      return place_table_[value].workspace == filter.origin_workspace;
    };

    const auto pane_is = [&](std::uint32_t value) {
      return context_table_[value].pane == query.origin_pane;
    };

    // The run listed, when the listing walked one, and the newest runs the record remembers.
    if (filter.origin_cwd != 0) {
      result.same_cwd = (place != none && cwd_is(place)) || std::ranges::any_of(record.recent_places.view(), cwd_is);
    }

    if (filter.origin_workspace != 0) {
      result.same_workspace = (place != none && workspace_is(place)) || std::ranges::any_of(record.recent_places.view(), workspace_is);
    }

    if (query.origin_pane != 0) {
      result.same_pane = (context != none && pane_is(context)) || std::ranges::any_of(record.recent_contexts.view(), pane_is);
      result.follows = follows(query.origin_pane, text);
    }

    return result;
  }

  HistoryIndexPage HistoryIndex::query(const HistoryIndexQuery& query) {
    hits_.clear();
    ensureOrder();

    Filter filter{.all_texts = query.matcher == nullptr || query.matcher->empty()};
    std::span<const Scored> matched;

    if (!filter.all_texts) {
      matched = match(*query.matcher, query.cancelled);
      if (cancelledBy(query.cancelled)) {
        return {.cancelled = true};
      }
    }

    // The score of each text for this query, by a stamp instead of a clear per query.
    if (stamps_.size() < records_.size()) {
      stamps_.resize(records_.size());
      stamped_scores_.resize(records_.size());
    }

    if (++stamp_ == 0) {
      std::ranges::fill(stamps_.viewMut(), 0);
      stamp_ = 1;
    }

    for (const auto& scored : matched) {
      stamps_.atMut(scored.text) = stamp_;
      stamped_scores_.atMut(scored.text) = scored.score;
    }

    // A filter on a text the index never saw matches nothing.
    const auto host = strings_.find(query.host);
    const auto branch = strings_.find(query.branch);
    const auto shell = strings_.find(historyShellName(query.shell));
    const auto scope_key = strings_.find(query.scope_key);
    const bool keyed_scope = query.scope == HistoryScope::cwd || query.scope == HistoryScope::workspace;
    if (!host || !branch || !shell || (keyed_scope && (!scope_key || *scope_key == 0))) {
      return {};
    }

    filter.host = *host;
    filter.branch = *branch;
    filter.shell = *shell;
    filter.scope_key = scope_key.valueOr(0);
    filter.origin_cwd = strings_.find(query.origin_cwd_key).valueOr(0);
    filter.origin_workspace = strings_.find(query.origin_workspace_key).valueOr(0);
    filter.snapshot = query.snapshot == 0 ? std::numeric_limits<std::int64_t>::max() : query.snapshot;
    filter.pane_start = query.now_ms;
    if (const auto* started = pane_started_.find(query.scope_pane)) {
      filter.pane_start = *started;
    }

    filter.any = query.failed_only || query.exit_code || query.author != HistoryAuthorFilter::all || query.since_ms != 0 || query.until_ms != 0 || query.min_duration_ms > 0 || !query.host.empty() || !query.branch.empty() || !query.shell.empty() || query.scope != HistoryScope::global;
    return query.by_rank ? listByRank(query, filter, matched) : listByTime(query, filter);
  }

  std::size_t HistoryIndex::cursorRank(const HistoryIndexQuery& query) const noexcept {
    std::size_t low = 0;
    std::size_t high = ids_.size();

    while (low < high) {
      const auto middle = low + ((high - low) / 2);
      const auto run = runAt(middle);
      const bool newer = started_[run] > query.after_started_ms || (started_[run] == query.after_started_ms && ids_[run] >= query.after_id);

      if (newer) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }

    return low;
  }

  HistoryIndexHit HistoryIndex::hitAt(std::size_t run, bool neighbour) const noexcept {
    const auto& record = records_[texts_[run]];

    return {.id = ids_[run], .text = texts_[run], .run_count = record.runs, .last_exit = record.last_has_exit ? ds::Option{record.last_exit} : ds::none, .neighbour = neighbour};
  }

  bool HistoryIndex::listOnce(std::uint32_t text, std::uint32_t listed) noexcept {
    if (listed_[text] == listed) {
      return false;
    }

    listed_.atMut(text) = listed;
    return true;
  }

  bool HistoryIndex::keepNeighbour(const HistoryIndexQuery& query, Neighbours& around, std::size_t run) {
    if (around.after_left == 0) {
      around.before.atMut(around.before_count % query.neighbours) = run;
      ++around.before_count;
      return true;
    }

    if (hits_.size() == query.limit) {
      return false;
    }

    --around.after_left;
    hits_.push(hitAt(run, true));
    return true;
  }

  bool HistoryIndex::pushMatch(const HistoryIndexQuery& query, Neighbours& around, std::size_t run) {
    const bool raw = query.neighbours != 0 && !query.distinct;
    const auto shown = raw ? std::min<std::size_t>(around.before_count, query.neighbours) : 0;

    if (hits_.size() + shown + 1 > query.limit) {
      return false;
    }

    for (auto back = shown; back > 0; --back) {
      hits_.push(hitAt(around.before[(around.before_count - back) % query.neighbours], true));
    }

    around.before_count = 0;
    around.after_left = raw ? query.neighbours : 0;
    hits_.push(hitAt(run, false));
    return true;
  }

  HistoryIndexPage HistoryIndex::listByTime(const HistoryIndexQuery& query, const Filter& filter) {
    // Newest first, past the cursor: the run a listing showed last, when it names one. A list of
    // each command once walks the runs before the cursor too, listing none, so that a command an
    // earlier page showed is not listed again at an older run.
    const auto past = query.after_id != 0 ? cursorRank(query) : 0;
    const auto first = query.distinct ? 0 : past;
    const auto listed = query.distinct ? nextListing() : 0;
    const std::size_t skip = query.after_id != 0 ? 0 : query.offset;
    const bool raw = query.neighbours != 0 && !query.distinct;
    std::size_t skipped = 0;
    Neighbours around;

    for (auto rank = first; rank < ids_.size(); ++rank) {
      if ((rank % chunk_texts) == 0 && cancelledBy(query.cancelled)) {
        return {.cancelled = true};
      }

      const auto run = runAt(rank);
      if (!passes(query, filter, run)) {
        continue;
      }

      const auto text = texts_[run];

      // A raw listing keeps the runs around each match that do not match themselves.
      if (scoreOf(filter, text) == 0) {
        if (raw && skipped >= skip && !keepNeighbour(query, around, run)) {
          return {.more = true, .hits = hits_.view()};
        }

        continue;
      }

      if ((query.distinct && !listOnce(text, listed)) || rank < past) {
        continue;
      }

      if (skipped < skip) {
        ++skipped;
        continue;
      }

      if (!pushMatch(query, around, run)) {
        return {.more = true, .hits = hits_.view()};
      }
    }

    return {.hits = hits_.view()};
  }

  void HistoryIndex::pushRanked(const HistoryIndexQuery& query, const Filter& filter, std::uint32_t text, std::uint32_t score, ds::Option<std::size_t> run) {
    const auto& record = records_[text];
    const auto order = static_cast<std::uint32_t>(ranked_.size());

    ranked_.push({
        .key = rankHistory(score, features(query, filter, text, run)),
        .order = order,
        .hit = {.id = run ? ids_[*run] : record.last_id, .text = text, .run_count = record.runs, .last_exit = record.last_has_exit ? ds::Option{record.last_exit} : ds::none},
    });
  }

  void HistoryIndex::rankRecords(const HistoryIndexQuery& query, const Filter& filter, std::span<const Scored> matched) {
    // Each command once, from what its record keeps: no walk of the runs.
    if (!filter.all_texts) {
      for (const auto& scored : matched) {
        if (records_[scored.text].runs != 0) {
          pushRanked(query, filter, scored.text, scored.score, ds::none);
        }
      }

      return;
    }

    for (std::uint32_t text = 0; text < records_.size(); ++text) {
      if (records_[text].runs != 0) {
        pushRanked(query, filter, text, 1, ds::none);
      }
    }
  }

  bool HistoryIndex::rankRuns(const HistoryIndexQuery& query, const Filter& filter) {
    const auto listed = query.distinct ? nextListing() : 0;

    for (std::size_t position = 0; position < ids_.size(); ++position) {
      if ((position % chunk_texts) == 0 && cancelledBy(query.cancelled)) {
        return false;
      }

      const auto run = runAt(position);
      const auto text = texts_[run];
      const auto score = scoreOf(filter, text);

      // The newest run that passes stands for the command in a distinct listing.
      if (score != 0 && passes(query, filter, run) && (!query.distinct || listOnce(text, listed))) {
        pushRanked(query, filter, text, score, run);
      }
    }

    return true;
  }

  HistoryIndexPage HistoryIndex::listByRank(const HistoryIndexQuery& query, const Filter& filter, std::span<const Scored> matched) {
    ranked_.clear();
    if (query.distinct && !filter.any && filter.snapshot >= newestId()) {
      rankRecords(query, filter, matched);
    } else if (!rankRuns(query, filter)) {
      return {.cancelled = true};
    }

    // Only the page is ordered in full; the rest is only cut from it.
    const auto precedes = [](const Ranked& left, const Ranked& right) {
      return left.key == right.key ? left.order < right.order : left.key > right.key;
    };

    auto candidates = ranked_.viewMut();
    const auto end = std::min(std::size_t{query.offset} + query.limit, candidates.size());

    if (end < candidates.size()) {
      std::ranges::nth_element(candidates, candidates.begin() + static_cast<std::ptrdiff_t>(end), precedes);
    }

    std::ranges::sort(candidates.first(end), precedes);
    for (auto index = std::min<std::size_t>(query.offset, end); index < end; ++index) {
      hits_.push(candidates[index].hit);
    }

    return {.more = candidates.size() > end, .hits = hits_.view()};
  }

  bool HistoryIndex::inStatsScope(const HistoryIndexStatsQuery& query, ds::Option<std::uint32_t> key, std::size_t run) const noexcept {
    if ((flags_[run] & flag_deleted) != 0 || (query.since_ms != 0 && started_[run] < query.since_ms)) {
      return false;
    }

    const auto& place = place_table_[places_[run]];

    switch (query.scope) {
    case HistoryScope::global:
      return true;
    case HistoryScope::cwd:
      return key && place.cwd == *key;
    case HistoryScope::workspace:
      return key && place.workspace == *key;
    case HistoryScope::pane:
      return context_table_[contexts_[run]].pane == query.pane;
    }

    return false;
  }

  HistoryIndex::Counted HistoryIndex::countScoped(const HistoryIndexStatsQuery& query, ds::Vec<std::uint64_t, ConcurrentMemory>& counts) {
    const auto key = strings_.find(query.scope_key);
    ds::Vec<std::uint32_t, ConcurrentMemory> seen{memory_};
    Counted counted;

    seen.resize(records_.size());
    for (std::size_t run = 0; run < ids_.size(); ++run) {
      if (!inStatsScope(query, key, run)) {
        continue;
      }

      ++counted.total;
      if (seen[texts_[run]] == 0) {
        seen.atMut(texts_[run]) = 1;
        ++counted.unique;
      }

      ++counts.atMut(records_[texts_[run]].group);
    }

    return counted;
  }

  ds::Option<HistoryIndexCommandStats> HistoryIndex::commandStats(std::int64_t text_id, std::int64_t until_ms, std::span<std::uint32_t> per_day) { // NOLINT(bugprone-easily-swappable-parameters): a text's row id, then the end of the days asked for
    constexpr std::int64_t day_ms = 86'400'000;

    std::ranges::fill(per_day, 0U);

    const auto* found = by_text_id_.find(text_id);
    if (found == nullptr || records_[*found].runs == 0) {
      return ds::none;
    }

    const auto text = *found;
    const auto& record = records_[text];
    const HistoryIndexCommandStats result{
        .runs = record.runs,
        .measured = record.measured,
        .measured_ms = record.measured_ms,
        .ended = record.ended,
        .succeeded = record.succeeded,
        .last_started_ms = record.last_ms,
        .last_exit = record.last_has_exit ? ds::Option<std::int32_t>{record.last_exit} : ds::none,
    };

    if (per_day.empty()) {
      return result;
    }

    // Newest first, back to the first day asked for: a run before it is older than every day.
    const auto days = static_cast<std::int64_t>(per_day.size());
    const auto since_ms = until_ms - (days * day_ms);

    ensureOrder();
    for (std::size_t rank = 0; rank < ids_.size(); ++rank) {
      const auto run = runAt(rank);
      const auto started = started_[run];

      if (started < since_ms) {
        break;
      }

      if (started >= until_ms || texts_[run] != text || (flags_[run] & flag_deleted) != 0) {
        continue;
      }

      const auto back = (until_ms - 1 - started) / day_ms;

      ++per_day[per_day.size() - 1 - static_cast<std::size_t>(back)];
    }

    return result;
  }

  HistoryIndexStats HistoryIndex::stats(const HistoryIndexStatsQuery& query) {
    groups_.clear();
    ds::Vec<std::uint64_t, ConcurrentMemory> counts{memory_};

    counts.resize(group_texts_.size());
    std::uint64_t total = 0;
    std::uint64_t unique = 0;
    const bool scoped = query.scope != HistoryScope::global || query.since_ms != 0;

    if (!scoped) {
      // Kept as the runs change: no walk.
      total = live_runs_;
      unique = live_texts_;
      for (const auto& record : records_.view()) {
        counts.atMut(record.group) += record.runs;
      }
    } else {
      const auto counted = countScoped(query, counts);

      total = counted.total;
      unique = counted.unique;
    }

    // A group is read again from the first command that had it, as the texts never move once
    // a stats call has begun.
    constexpr std::size_t group_bytes = std::numeric_limits<std::uint16_t>::max();

    for (std::uint32_t group = 0; group < counts.size() && group < group_texts_.size(); ++group) {
      if (counts[group] != 0) {
        groups_.push({.count = counts[group], .group = utf8Prefix(historyGroup(this->text(group_texts_[group]).original), group_bytes)});
      }
    }

    const auto end = std::min(maximum_top_groups, groups_.size());
    const auto precedes = [](const HistoryIndexGroup& left, const HistoryIndexGroup& right) {
      return left.count == right.count ? left.group < right.group : left.count > right.count;
    };

    std::ranges::partial_sort(groups_.viewMut(), groups_.viewMut().begin() + static_cast<std::ptrdiff_t>(end), precedes);
    return {.total = total, .unique = unique, .top = groups_.view().first(end)};
  }

}
