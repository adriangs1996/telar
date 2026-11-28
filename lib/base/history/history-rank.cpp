module telar.base.history;

import std;
import telar.base.ds;
import telar.base.text.utf8;

namespace telar::runtime {

  namespace {

    // Factors in fixed point, 1024 a factor of one.
    constexpr unsigned fixed_shift = 10;
    constexpr std::uint64_t one = std::uint64_t{1} << fixed_shift;
    constexpr std::uint64_t half = one / 2;
    constexpr std::uint64_t quarter = one / 4;

    // What a prior pulls a command up by, in units of `one`, beside recency's, the counts' and
    // a choice's: at most a half, a half and a half (the sequence), a quarter.
    constexpr std::uint64_t same_directory = 307;
    constexpr std::uint64_t same_place = 102;
    constexpr std::uint64_t most_pull = half + half + half + quarter + same_directory + (2 * same_place);

    // The factor the priors' pull becomes, in a finer fixed point than theirs so that the least
    // of them still moves a key: x1 with none, x1.2 with every one at its most, and x0.8 for a
    // failure.
    constexpr unsigned factor_shift = 20;
    constexpr std::uint64_t factor_one = std::uint64_t{1} << factor_shift;
    constexpr std::uint64_t most_boost = factor_one / 5;
    constexpr std::uint64_t failure_numerator = 4;
    constexpr std::uint64_t failure_denominator = 5;

    constexpr std::uint64_t seconds_per_day = 86400;
    constexpr std::uint64_t forgotten_days = 10;

    // 1 + 0.5 * 2^(-age / 1 day), each day halving what the one before it adds and the day
    // itself taking it down linearly, so the factor falls as the command ages, without a step.
    constexpr std::uint64_t recency(std::uint64_t age_seconds) noexcept {
      const auto days = age_seconds / seconds_per_day;
      if (days >= forgotten_days) {
        return one;
      }

      const auto into_day = age_seconds % seconds_per_day;

      return one + (((half >> days) * ((2 * seconds_per_day) - into_day)) / (2 * seconds_per_day));
    }

    // 1 + `most` * log2(count + 1) / `steps`, full from 2^(steps - 1).
    constexpr std::uint64_t logarithmic(std::uint32_t count, std::uint64_t most, unsigned steps) noexcept {
      return one + ((most * std::min(static_cast<unsigned>(std::bit_width(count)), steps)) / steps);
    }

    // Appends to `out` what fits of each piece, cut between characters; past a cut, nothing.
    class TemplateWriter {
    public:
      explicit TemplateWriter(std::span<char> out) noexcept
          : out_(out) {}

      void write(std::string_view piece) noexcept {
        const auto fits = cut_ ? std::string_view{} : utf8Prefix(piece, out_.size() - written_);

        std::ranges::copy(fits, out_.subspan(written_).begin());
        written_ += fits.size();
        cut_ = cut_ || fits.size() != piece.size();
      }

      [[nodiscard]] std::size_t written() const noexcept {
        return written_;
      }

      // Forgets what was written past `written`.
      void rewind(std::size_t written) noexcept {
        written_ = written;
      }

    private:
      std::span<char> out_;
      std::size_t written_ = 0;
      bool cut_ = false;
    };

    bool blank(char byte) noexcept {
      return byte == ' ' || byte == '\t' || byte == '\n';
    }

    // text[begin, end).
    std::string_view slice(std::string_view text, std::size_t begin, std::size_t end) noexcept {
      text.remove_suffix(text.size() - end);
      text.remove_prefix(begin);
      return text;
    }

    // A run of a word: what lies outside quotes, or quotes that follow each other.
    struct Run {
      std::size_t begin = 0;
      std::size_t end = 0;
      bool quoted = false;
    };

    // One word of a command, its runs and whether a slash lies in it outside quotes. A word
    // of more runs than it holds keeps its first ones.
    struct Word {
      static constexpr std::size_t most_runs = 64;

      ds::Array<Run, most_runs> runs{};
      std::size_t run_count = 0;
      std::size_t start = 0;
      std::size_t end = 0;
      bool slash = false;

      // Ends the run that began at `start` at `end_at`.
      void close(std::size_t end_at, bool quoted) noexcept {
        if (end_at == start) {
          return;
        }

        if (run_count != 0 && quoted && runs[run_count - 1].quoted && runs[run_count - 1].end == start) {
          runs.atMut(run_count - 1).end = end_at;
        } else if (run_count < runs.size()) {
          runs.atMut(run_count++) = {.begin = start, .end = end_at, .quoted = quoted};
        }

        start = end_at;
      }
    };

    // The word that starts at `index`, up to the first blank outside quotes. A backslash
    // outside single quotes escapes the byte after it.
    Word readWord(std::string_view command, std::size_t index) noexcept {
      Word word{.start = index};
      char quote = 0;

      for (; index < command.size() && (quote != 0 || !blank(command[index])); ++index) {
        const auto byte = command[index];

        if (byte == '\\' && quote != '\'' && index + 1 < command.size()) {
          ++index;
        } else if (quote != 0 && byte == quote) {
          quote = 0;
          word.close(index + 1, true);
        } else if (quote == 0 && (byte == '\'' || byte == '"')) {
          word.close(index, false);
          quote = byte;
        } else if (quote == 0 && byte == '/') {
          word.slash = true;
        }
      }

      word.close(index, quote != 0);
      word.end = index;
      return word;
    }

    // Writes `word` of `command`, a `<path>` when it holds a slash, each quoted run a `<str>`.
    void writeWord(TemplateWriter& writer, std::string_view command, const Word& word) noexcept {
      constexpr std::string_view quoted = "<str>";
      constexpr std::string_view path = "<path>";

      if (word.slash) {
        writer.write(path);
        return;
      }

      for (const auto& run : word.runs.view().first(word.run_count)) {
        writer.write(run.quoted ? quoted : slice(command, run.begin, run.end));
      }
    }

  }

  std::uint64_t historyRank(std::uint32_t score, const HistoryRankFeatures& features) noexcept {
    constexpr unsigned run_steps = 10;
    constexpr unsigned context_steps = 8;
    // The priors add up, then the sum is bounded as a whole: multiplied, seven of them weighed
    // up to x6.7, so a weak match run often and here outranked one several times better.
    const auto pull = (recency(features.age_seconds) - one) + (logarithmic(features.run_count, half, run_steps) - one) + (logarithmic(features.follows_previous, half, context_steps) - one) + (logarithmic(features.selected_count, quarter, context_steps) - one) + (features.same_directory ? same_directory : 0) + (features.same_workspace ? same_place : 0) + (features.same_session ? same_place : 0);
    const auto factor = factor_one + ((pull * most_boost) / most_pull);
    // At most 2^32 times 1.2 * 2^20, which leaves the failure's product room in 64 bits.
    const auto key = (std::uint64_t{score} + 1) * factor;

    return features.recent_failure ? (key * failure_numerator) / failure_denominator : key;
  }

  std::size_t historyTemplate(std::string_view command, std::span<char> out) noexcept {
    constexpr std::size_t kept_words = 2;
    TemplateWriter writer{out};
    std::size_t index = 0;

    for (std::size_t words = 0; words < kept_words; ++words) {
      while (index < command.size() && blank(command[index])) {
        ++index;
      }

      if (index == command.size()) {
        break;
      }

      const auto word = readWord(command, index);
      // A space that no word follows is no part of the template.
      const auto before_space = writer.written();

      if (words != 0) {
        writer.write(" ");
      }

      const auto after_space = writer.written();

      writeWord(writer, command, word);
      if (writer.written() == after_space) {
        writer.rewind(before_space);
      }

      index = word.end;
    }

    return writer.written();
  }

}
