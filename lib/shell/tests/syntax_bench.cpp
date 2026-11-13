import std;
import telar.shell.syntax;

namespace {

  using namespace telar::shell;
  using Clock = std::chrono::steady_clock;

  struct Sample {
    std::string_view name;
    Syntax syntax;
    std::string_view line;
  };

  // Keeps the optimizer from discarding the measured work.
  volatile std::size_t sink = 0;

  template <typename Work>
  double nanoseconds(std::size_t rounds, Work &&work) {
    for (std::size_t i = 0; i < rounds / 10; ++i) {
      work();
    }
    const auto begin = Clock::now();
    for (std::size_t i = 0; i < rounds; ++i) {
      work();
    }
    return std::chrono::duration<double, std::nano>(Clock::now() - begin).count() / static_cast<double>(rounds);
  }

}

int main() {
  const Sample samples[] = {
      {"posix pipeline", Syntax{Dialect::posix},
       "git log --oneline --decorate --graph -n 50 \"$branch\" | grep -E '^(feat|fix)' | sed -e 's/^/  /' > \"${HOME}/notes/$(date +%F).txt\" 2>&1 && echo \"done: $?\" || echo failed; for f in *.log; do wc -l $f; done"},
      {"posix heredoc", Syntax{Dialect::posix},
       "if [[ -n $TOKEN && -f ~/.config/app.json ]]; then curl -sS -H \"Authorization: Bearer $TOKEN\" -X POST --data @- https://api.example.com/v1/items <<'EOF'\n{\"name\": \"item\", \"count\": 3}\nEOF\nfi; ls *(.om[1,5])"},
      {"fish", Syntax{Dialect::fish},
       "for f in (find . -name '*.fish' -type f); if test -s $f; and not string match -q '*test*' $f; set -l n (wc -l < $f); echo \"$f: $n lines\" >> /tmp/report.txt 2>&1; else; echo skip $f; end; end | sort -k2 -n"},
  };
  std::array<Token, 512> tokens;
  std::array<Word, 512> words;
  std::array<char, 1024> text;
  constexpr std::size_t rounds = 200000;
  for (const Sample &sample : samples) {
    const std::size_t cursor = sample.line.size() / 2;
    const double lexing = nanoseconds(rounds, [&] {
      sink = sink + lex(sample.line, sample.syntax, tokens).tokens;
    });
    const double query = nanoseconds(rounds, [&] {
      const Lexed lexed = lex(sample.line, sample.syntax, tokens, cursor);
      sink = sink + commandAt(sample.line, sample.syntax, tokens, lexed, words, text).words;
    });
    const Lexed lexed = lex(sample.line, sample.syntax, tokens);
    std::println("{:<15} {:>3} bytes {:>3} tokens  lex {:>7.1f} ns  lex+commandAt {:>7.1f} ns", sample.name,
                 sample.line.size(), lexed.tokens, lexing, query);
  }
}
