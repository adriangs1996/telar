module telar.runtime.history.matching;

import std;
import telar.base.history;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    HistoryMatchMode patternMode(HistoryMatch mode) noexcept {
      switch (mode) {
      case HistoryMatch::fuzzy:
        return HistoryMatchMode::fuzzy;
      case HistoryMatch::substring:
        return HistoryMatchMode::substring;
      case HistoryMatch::prefix:
        return HistoryMatchMode::prefix;
      case HistoryMatch::regex:
        break;
      }

      return HistoryMatchMode::exact;
    }

    // A regex's score falls with how far into the command its match starts, on the scale of a
    // short fuzzy match.
    std::uint32_t regexScore(std::size_t start) noexcept {
      constexpr std::uint32_t best = 1024;
      constexpr std::size_t step = 4;

      return best - static_cast<std::uint32_t>(std::min<std::size_t>(start * step, best - 1));
    }

  }

  HistoryMatchWork::HistoryMatchWork(ConcurrentMemory& memory)
      : arena_(ds::makeBox<HistoryMatchArena>(memory)),
        pattern_(ds::makeBox<PatternScratch>(memory)) {}

  HistoryMatcher::HistoryMatcher(ConcurrentMemory& memory, HistoryMatch mode, std::string_view query)
      : mode_(mode),
        query_(memory, query),
        pattern_(mode == HistoryMatch::regex ? std::string_view{} : query, patternMode(mode)) {
    if (mode_ == HistoryMatch::regex && !query.empty()) {
      // A regex matches as the other modes fold case: every letter in either case.
      try {
        regex_ = Pattern{query, PatternOptions{.regex = true, .ignore_case = true}};
      } catch (const PatternError& error) {
        throw RequestError{FailureCode::invalid_request, error.what()};
      }
    }
  }

  HistoryMatch HistoryMatcher::mode() const noexcept {
    return mode_;
  }

  std::string_view HistoryMatcher::query() const noexcept {
    return query_.view();
  }

  bool HistoryMatcher::empty() const noexcept {
    return mode_ == HistoryMatch::regex ? query_.empty() : pattern_.empty();
  }

  bool HistoryMatcher::narrows(HistoryMatch previous_mode, std::string_view previous_query) const noexcept {
    // What changes what a longer query matches beyond narrowing it.
    constexpr std::string_view widening = "|!$\\";

    if (previous_mode != mode_ || mode_ == HistoryMatch::regex) {
      return false;
    }

    const auto query = query_.view();

    return query.starts_with(previous_query) && previous_query.find_first_of(widening) == std::string_view::npos && query.find_first_of(widening) == std::string_view::npos;
  }

  ds::Option<std::uint32_t> HistoryMatcher::score(HistoryText text, HistoryMatchWork& scratch) const noexcept {
    if (mode_ != HistoryMatch::regex) {
      return historyMatch(pattern_, text.original, scratch.arena_.getMut());
    }

    if (regex_.empty()) {
      return 0U;
    }

    if (const auto found = regex_.find(text.original, 0, scratch.pattern_.getMut())) {
      return regexScore(found->begin);
    }

    return ds::none;
  }

  std::size_t HistoryMatcher::ranges(HistoryText text, std::span<HistoryRange> out, HistoryMatchWork& scratch) const noexcept {
    if (out.empty() || empty()) {
      return 0;
    }

    if (mode_ != HistoryMatch::regex) {
      if (!historyMatch(pattern_, text.original, scratch.arena_.getMut(), &scratch.ranges_)) {
        return 0;
      }

      const auto found = scratch.ranges_.view();
      const auto count = std::min(found.size(), out.size());

      for (std::size_t index = 0; index < count; ++index) {
        out[index] = {.start = found[index].begin, .end = found[index].end};
      }

      return count;
    }

    const auto found = regex_.find(text.original, 0, scratch.pattern_.getMut());
    if (!found || found->end <= found->begin) {
      return 0;
    }

    out.front() = {.start = static_cast<std::uint32_t>(found->begin), .end = static_cast<std::uint32_t>(found->end)};
    return 1;
  }

  std::uint64_t rankHistory(std::uint32_t score, const HistoryPriors& priors) noexcept {
    constexpr std::int64_t millisecond_per_second = 1000;
    const auto age = std::max<std::int64_t>(0, priors.now_ms - priors.last_ms) / millisecond_per_second;

    return historyRank(score, {
                                  .age_seconds = static_cast<std::uint64_t>(age),
                                  .run_count = priors.runs,
                                  .same_directory = priors.same_cwd,
                                  .same_workspace = priors.same_workspace,
                                  .same_session = priors.same_pane,
                                  .recent_failure = priors.recent_failure,
                                  .follows_previous = priors.follows,
                                  .selected_count = priors.selected,
                              });
  }

  std::uint64_t historyTemplateKey(std::string_view command) noexcept {
    constexpr std::size_t template_bytes = 512;
    constexpr std::uint64_t offset_basis = 0xcbf29ce484222325;
    constexpr std::uint64_t prime = 0x100000001b3;
    ds::Array<char, template_bytes> shape; // NOLINT(cppcoreguidelines-pro-type-member-init): historyTemplate writes what it counts
    const auto written = historyTemplate(command, shape.viewMut());
    std::uint64_t hash = offset_basis;

    for (const char byte : shape.view().first(written)) {
      hash = (hash ^ static_cast<unsigned char>(byte)) * prime;
    }

    return hash;
  }

}
