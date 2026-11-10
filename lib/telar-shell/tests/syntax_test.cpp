import std;
import telar.shell.syntax;

namespace {

  using namespace telar::shell;

  constexpr Syntax posix{Dialect::posix, true};
  constexpr Syntax fish{Dialect::fish, true};
  // Marks the cursor in cursor cases; removed before lexing.
  constexpr std::string_view mark = "\xc2\xa6";

  int failures = 0;

  void check(bool condition, std::string_view what, std::string_view line, std::string_view got = {}) {
    if (!condition) {
      ++failures;
      std::println(std::cerr, "FAIL {}: {:?}{}{}", what, line, got.empty() ? "" : " -> ", got);
    }
  }

  std::string_view name(TokenKind kind) {
    switch (kind) {
    case TokenKind::command:
      return "cmd";
    case TokenKind::argument:
      return "arg";
    case TokenKind::option:
      return "opt";
    case TokenKind::keyword:
      return "kw";
    case TokenKind::assignment:
      return "assign";
    case TokenKind::string:
      return "str";
    case TokenKind::variable:
      return "var";
    case TokenKind::substitution:
      return "sub";
    case TokenKind::control:
      return "ctl";
    case TokenKind::redirection:
      return "redir";
    case TokenKind::comment:
      return "comment";
    case TokenKind::heredoc_body:
      return "heredoc";
    case TokenKind::error:
      return "error";
    }
    return "?";
  }

  std::string render(std::string_view line, std::span<const Token> tokens) {
    std::string out;
    for (const Token &t : tokens) {
      if (!out.empty()) {
        out += ' ';
      }
      out += name(t.kind);
      out += ':';
      out += line.substr(t.begin, t.end - t.begin);
    }
    return out;
  }

  struct TokenCase {
    Syntax syntax;
    std::string_view line;
    std::string_view expected;
  };

  void testTokens() {
    const TokenCase cases[] = {
        {posix, "echo hi", "cmd:echo arg:hi"},
        {posix, "git chec", "cmd:git arg:chec"},
        {posix, "ls -la --color=auto -- -", "cmd:ls opt:-la opt:--color=auto opt:-- opt:-"},
        {posix, "cat - x", "cmd:cat arg:- arg:x"},
        {posix, "FOO=bar BAZ+=1 a[1]=x env", "assign:FOO=bar assign:BAZ+=1 assign:a[1]=x cmd:env"},
        {posix, "FOO=\"a b\" cmd x=1", "assign:FOO= str:\"a b\" cmd:cmd arg:x=1"},
        {posix, "echo 'a b' \"c $d e\" $'\\n'", "cmd:echo str:'a b' str:\"c  var:$d str: e\" str:$'\\n'"},
        {posix, "echo $\"hi\"", "cmd:echo str:$ str:\"hi\""},
        {posix, "echo ${x:-$(date)} $1 $@ $? $", "cmd:echo var:${x:- sub:$( cmd:date sub:) var:} var:$1 var:$@ var:$? var:$"},
        {posix, "echo ${(f)\"$(cmd)\"} ${#a} ${${x}}", "cmd:echo var:${(f) str:\" sub:$( cmd:cmd sub:) str:\" var:} var:${#a} var:${${x}}"},
        {posix, "diff <(ls a) >(cat) =(echo)", "cmd:diff sub:<( cmd:ls arg:a sub:) sub:>( cmd:cat sub:) sub:=( cmd:echo sub:)"},
        {posix, "echo `date` \"`id`\"", "cmd:echo sub:` cmd:date sub:` str:\" sub:` cmd:id sub:` str:\""},
        {posix, "echo $(( 1 + $x )); (( i++ ))", "cmd:echo sub:$(( 1 +  var:$x sub: )) ctl:; kw:(( sub: i++  kw:))"},
        {posix, "a | b |& c || d && e ; f & g", "cmd:a ctl:| cmd:b ctl:|& cmd:c ctl:|| cmd:d ctl:&& cmd:e ctl:; cmd:f ctl:& cmd:g"},
        {posix, "a &! b &| c", "cmd:a ctl:&! cmd:b ctl:&| cmd:c"},
        {posix, "a\nb", "cmd:a ctl:\n cmd:b"},
        {posix, "cmd >out 2>&1 &>log >>app <in <<<str 3<>rw >|clob 2>&- >!z &>>both",
         "cmd:cmd redir:> arg:out redir:2>&1 redir:&> arg:log redir:>> arg:app redir:< arg:in redir:<<< arg:str "
         "redir:3<> arg:rw redir:>| arg:clob redir:2>&- redir:>! arg:z redir:&>> arg:both"},
        {posix, ">out cmd arg", "redir:> arg:out cmd:cmd arg:arg"},
        {posix, "a>b", "cmd:a redir:> arg:b"},
        {posix, "if true; then echo; elif false; then :; else x; fi",
         "kw:if cmd:true ctl:; kw:then cmd:echo ctl:; kw:elif cmd:false ctl:; kw:then cmd:: ctl:; kw:else cmd:x ctl:; kw:fi"},
        {posix, "for i in a b; do echo $i; done", "kw:for arg:i kw:in arg:a arg:b ctl:; kw:do cmd:echo var:$i ctl:; kw:done"},
        {posix, "for i do :; done", "kw:for arg:i kw:do cmd:: ctl:; kw:done"},
        {posix, "for ((i=0; i<3; i++)); do :; done", "kw:for kw:(( sub:i=0; i<3; i++ kw:)) ctl:; kw:do cmd:: ctl:; kw:done"},
        {posix, "while read l; do :; done < f", "kw:while cmd:read arg:l ctl:; kw:do cmd:: ctl:; kw:done redir:< arg:f"},
        {posix, "until x; do y; done", "kw:until cmd:x ctl:; kw:do cmd:y ctl:; kw:done"},
        {posix, "select x in a; do :; done", "kw:select arg:x kw:in arg:a ctl:; kw:do cmd:: ctl:; kw:done"},
        {posix, "echo for if then done", "cmd:echo arg:for arg:if arg:then arg:done"},
        {posix, "X=1 if", "assign:X=1 cmd:if"},
        {posix, "echo 'do' \"if\"", "cmd:echo str:'do' str:\"if\""},
        {posix, "case $x in a|b) echo;; (*) :;& c) ;;& esac",
         "kw:case var:$x kw:in arg:a ctl:| arg:b ctl:) cmd:echo ctl:;; ctl:( arg:* ctl:) cmd:: ctl:;& arg:c ctl:) "
         "ctl:;;& kw:esac"},
        {posix, "case $x in @(a|b)) x; esac", "kw:case var:$x kw:in arg:@(a|b) ctl:) cmd:x ctl:; kw:esac"},
        {posix, "{ echo; } > f", "kw:{ cmd:echo ctl:; kw:} redir:> arg:f"},
        {posix, "{echo}", "cmd:{echo}"},
        {posix, "(cd x; ls) | wc", "ctl:( cmd:cd arg:x ctl:; cmd:ls ctl:) ctl:| cmd:wc"},
        {posix, "[[ -f a && $b == c || ( d < e ) ]]",
         "kw:[[ opt:-f arg:a ctl:&& var:$b arg:== arg:c ctl:|| ctl:( arg:d ctl:< arg:e ctl:) kw:]]"},
        {posix, "! time coproc x", "kw:! kw:time kw:coproc cmd:x"},
        {posix, "foo() { echo; }", "cmd:foo ctl:() kw:{ cmd:echo ctl:; kw:}"},
        {posix, "function foo { :; }", "kw:function arg:foo kw:{ cmd:: ctl:; kw:}"},
        {posix, "a=(1 2) b", "assign:a=(1 assign:2) cmd:b"},
        {posix, "ls *(.) @(a|b) **/*.c(om[1]) {a,b} ~/x", "cmd:ls arg:*(.) arg:@(a|b) arg:**/*.c(om[1]) arg:{a,b} arg:~/x"},
        {posix, "echo a#b # comment", "cmd:echo arg:a#b comment:# comment"},
        {posix, "echo \"a#b\" #", "cmd:echo str:\"a#b\" comment:#"},
        {Syntax{Dialect::posix, false}, "echo #x", "cmd:echo arg:#x"},
        {posix, "echo a\\ b \\$x \\", "cmd:echo arg:a\\ b arg:\\$x arg:\\"},
        {posix, "echo a \\\n b", "cmd:echo arg:a arg:b"},
        {posix, "cat <<EOF\nhello $x\nEOF\necho", "cmd:cat redir:<< arg:EOF ctl:\n heredoc:hello $x\nEOF\n cmd:echo"},
        {posix, "cat <<-'EOF' | wc\n\tbody\n\tEOF\n", "cmd:cat redir:<<- str:'EOF' ctl:| cmd:wc ctl:\n heredoc:\tbody\n\tEOF\n"},
        {posix, "cat <<A <<\"B\"\na\nA\nb\nB", "cmd:cat redir:<< arg:A redir:<< str:\"B\" ctl:\n heredoc:a\nA\n heredoc:b\nB"},
        {posix, "echo )", "cmd:echo error:)"},
        {posix, "fi", "error:fi"},
        {posix, "a ;; b", "cmd:a error:;; cmd:b"},
        {posix, "echo héllo \"ñ\" $é", "cmd:echo arg:héllo str:\"ñ\" arg:$é"},
        {posix, "echo \"a", "cmd:echo str:\"a"},
        {posix, "echo 'a", "cmd:echo str:'a"},

        {fish, "echo hi", "cmd:echo arg:hi"},
        {fish, "set -l x (date) $x[1] $$y $", "cmd:set opt:-l arg:x sub:( cmd:date sub:) var:$x[1] var:$$y var:$"},
        {fish, "echo 'it\\'s' \"a $b c\" \"$(pwd)\"", "cmd:echo str:'it\\'s' str:\"a  var:$b str: c\" str:\" sub:$( cmd:pwd sub:) str:\""},
        {fish, "echo a(b)c", "cmd:echo arg:a sub:( cmd:b sub:) arg:c"},
        {fish, "begin; echo; end | cat", "kw:begin ctl:; cmd:echo ctl:; kw:end ctl:| cmd:cat"},
        {fish, "if test -f x; and true; or false; else if not a; end",
         "kw:if cmd:test opt:-f arg:x ctl:; kw:and cmd:true ctl:; kw:or cmd:false ctl:; kw:else kw:if kw:not cmd:a ctl:; kw:end"},
        {fish, "while true; ! false; end", "kw:while cmd:true ctl:; kw:! cmd:false ctl:; kw:end"},
        {fish, "for f in *.txt; echo $f; end", "kw:for arg:f kw:in arg:*.txt ctl:; cmd:echo var:$f ctl:; kw:end"},
        {fish, "function foo -a x; echo; end", "kw:function arg:foo opt:-a arg:x ctl:; cmd:echo ctl:; kw:end"},
        {fish, "switch $x; case a b; echo; end", "kw:switch var:$x ctl:; kw:case arg:a arg:b ctl:; cmd:echo ctl:; kw:end"},
        {fish, "echo end for", "cmd:echo arg:end arg:for"},
        {fish, "cmd 2>&1 >? f &> g >>h <i 2>| cat", "cmd:cmd redir:2>&1 redir:>? arg:f redir:&> arg:g redir:>> arg:h redir:< arg:i ctl:2>| cmd:cat"},
        {fish, "a && b || c & d &| e; f", "cmd:a ctl:&& cmd:b ctl:|| cmd:c ctl:& cmd:d ctl:&| cmd:e ctl:; cmd:f"},
        {fish, "FOO=bar cmd", "assign:FOO=bar cmd:cmd"},
        {fish, "echo `x` {a,b} $'x'", "cmd:echo arg:`x` arg:{a,b} arg:$ str:'x'"},
        {fish, "echo a#b # c", "cmd:echo arg:a#b comment:# c"},
        {fish, "echo \\n \\(", "cmd:echo arg:\\n arg:\\("},
        {fish, "end", "error:end"},
    };
    std::array<Token, 256> tokens;
    for (const TokenCase &c : cases) {
      const Lexed lexed = lex(c.line, c.syntax, tokens);
      const std::string got = render(c.line, std::span{tokens}.first(lexed.tokens));
      check(!lexed.overflow && got == c.expected, "tokens", c.line, got);
    }
  }

  void testFlags() {
    std::array<Token, 32> tokens;
    const std::string_view line = "cat >f 'x";
    const Lexed lexed = lex(line, posix, tokens);
    check(lexed.tokens == 4, "flag count", line);
    check(tokens[0].flags == Token::word_start && tokens[0].role == TokenKind::command, "command flags", line);
    check(tokens[2].flags == (Token::word_start | Token::redirect_target), "redirect target", line);
    check(tokens[3].quote == Quote::single_quoted && (tokens[3].flags & Token::unterminated), "unterminated", line);

    const std::string_view dq = "echo \"a $b";
    const Lexed d = lex(dq, posix, tokens);
    check(tokens[d.tokens - 1].kind == TokenKind::variable, "double last piece", dq);
    const std::string_view dq2 = "echo \"a $b c";
    const Lexed d2 = lex(dq2, posix, tokens);
    check((tokens[d2.tokens - 1].flags & Token::unterminated) != 0, "double unterminated", dq2);

    const std::string_view mixed = "--opt=\"$x\"";
    const Lexed m = lex("cmd " + std::string{mixed}, posix, tokens);
    check(m.tokens == 5 && tokens[2].role == TokenKind::option && tokens[3].role == TokenKind::option &&
              tokens[3].kind == TokenKind::variable,
          "piece role", mixed);
  }

  struct CompleteCase {
    Syntax syntax;
    std::string_view line;
    Completeness expected;
  };

  void testCompleteness() {
    using enum Completeness;
    const CompleteCase cases[] = {
        {posix, "", complete},
        {posix, "echo hi", complete},
        {posix, "echo \"a#b\"", complete},
        {posix, "echo 'do'", complete},
        {posix, "echo for", complete},
        {posix, "echo done fi esac", complete},
        {posix, "echo \"a\\\nb\"", complete},
        {posix, "echo 'a\\\nb'", complete},
        {posix, "echo \"$(date)\"", complete},
        {posix, "echo `date`", complete},
        {posix, "cat <<-'EOF'\n\tx\n\tEOF", complete},
        {posix, "cat <<EOF\nx\nEOF\n", complete},
        {posix, "cat <<\"E F\"\nx\nE F", complete},
        {posix, "cat <<EOF | grep x\nbody\nEOF", complete},
        {posix, "if a; then b; fi", complete},
        {posix, "if a; then b; else c; fi", complete},
        {posix, "if a\nthen\n  b\nfi", complete},
        {posix, "for i in a; do b; done", complete},
        {posix, "for i do b; done", complete},
        {posix, "while a; do b; done", complete},
        {posix, "case x in a) b;; esac", complete},
        {posix, "case x in a) b; esac", complete},
        {posix, "case x in\n  a) b ;;\n  *) c ;;\nesac", complete},
        {posix, "{ a; }", complete},
        {posix, "(a)", complete},
        {posix, "$(a)", complete},
        {posix, "[[ a && b ]]", complete},
        {posix, "(( i++ ))", complete},
        {posix, "a | b", complete},
        {posix, "a |\nb", complete},
        {posix, "a &&\n\nb", complete},
        {posix, "a &", complete},
        {posix, "foo() { a; }", complete},
        {posix, "foo()\n{ a; }", complete},
        {posix, "function foo { a; }", complete},
        {posix, "echo $((1+2))", complete},
        {posix, "a=(1 2)", complete},
        {posix, "echo # (", complete},
        {posix, "echo )", complete},
        {posix, "fi", complete},
        {posix, "echo a\\\\", complete},
        {posix, "echo $'it\\'s'", complete},
        {posix, "ls *(.)", complete},
        {posix, "echo $(case x in a) echo;; esac)", complete},
        {posix, "case x in a) (b);; esac", complete},
        {posix, "case x in a) b;| c) d;; esac", complete},
        {posix, "if [[ a ]]; then b; fi", complete},
        {posix, "ec\\\nho", complete},
        {posix, "x=$(a\nb)", complete},
        {posix, "echo $(case x in a) echo;;", open_compound},

        {posix, "echo 'a", open_quote},
        {posix, "echo \"a", open_quote},
        {posix, "echo $'a", open_quote},
        {posix, "echo \"a\\", open_quote},
        {posix, "echo a\\", trailing_escape},
        {posix, "echo $(a \\", trailing_escape},
        {posix, "echo \"$(date", open_substitution},
        {posix, "echo $(date", open_substitution},
        {posix, "echo $(a |", open_substitution},
        {posix, "echo ${x", open_substitution},
        {posix, "echo `date", open_substitution},
        {posix, "echo $((1", open_substitution},
        {posix, "diff <(ls", open_substitution},
        {posix, "(cd x", open_group},
        {posix, "{ echo", open_group},
        {posix, "{ echo }", open_group},
        {posix, "a=(1", open_group},
        {posix, "if", open_compound},
        {posix, "if true", open_compound},
        {posix, "if true; then echo", open_compound},
        {posix, "if a; then if b; then c; fi", open_compound},
        {posix, "while a; do", open_compound},
        {posix, "for i in a b", open_compound},
        {posix, "case x in", open_compound},
        {posix, "case x in a) echo;;", open_compound},
        {posix, "[[ a", open_compound},
        {posix, "(( 1", open_compound},
        {posix, "foo()", open_compound},
        {posix, "function foo", open_compound},
        {posix, "cat <<EOF", pending_heredoc},
        {posix, "cat <<EOF\nbody", pending_heredoc},
        {posix, "cat <<EOF\nbody\n", pending_heredoc},
        {posix, "cat <<-EOF\n\tbody\n EOF", pending_heredoc},
        {posix, "cat <<EOF\nEOF \n", pending_heredoc},
        {posix, "a |", trailing_operator},
        {posix, "a &&", trailing_operator},
        {posix, "a ||", trailing_operator},
        {posix, "a |&", trailing_operator},
        {posix, "a |\n", trailing_operator},
        {posix, "a && # why\n", trailing_operator},

        {fish, "echo hi", complete},
        {fish, "begin; end", complete},
        {fish, "if a; end", complete},
        {fish, "if a; else if b; end", complete},
        {fish, "echo 'it\\'s'", complete},
        {fish, "echo (date)", complete},
        {fish, "echo \"$(date)\"", complete},
        {fish, "echo `", complete},
        {fish, "echo for end", complete},
        {fish, "echo 'a", open_quote},
        {fish, "echo 'a\\'", open_quote},
        {fish, "echo \"a", open_quote},
        {fish, "echo a\\", trailing_escape},
        {fish, "echo (date", open_substitution},
        {fish, "echo \"$(date", open_substitution},
        {fish, "begin", open_compound},
        {fish, "if a", open_compound},
        {fish, "if a; else if b", open_compound},
        {fish, "for i in a", open_compound},
        {fish, "function f", open_compound},
        {fish, "switch x; case a", open_compound},
        {fish, "while true; echo;", open_compound},
        {fish, "a |", trailing_operator},
        {fish, "a &&", trailing_operator},
        {fish, "a ||", trailing_operator},
        {fish, "a 2>|", trailing_operator},
    };
    std::array<Token, 128> tokens;
    for (const CompleteCase &c : cases) {
      const Lexed lexed = lex(c.line, c.syntax, tokens);
      check(lexed.completeness == c.expected, "completeness", c.line, std::to_string(static_cast<int>(lexed.completeness)));
    }
  }

  void testLimits() {
    std::array<Token, 512> tokens;
    std::string deep;
    for (std::size_t i = 0; i < max_depth + 1; ++i) {
      deep += "$(";
    }
    Lexed lexed = lex(deep, posix, tokens);
    check(lexed.completeness == Completeness::limit && tokens[lexed.tokens - 1].kind == TokenKind::error, "nesting limit", "$( x 65");
    std::string shallow;
    for (std::size_t i = 0; i < max_depth - 1; ++i) {
      shallow += "$(";
    }
    lexed = lex(shallow, posix, tokens);
    check(lexed.completeness == Completeness::open_substitution, "nesting below limit", "$( x 63");

    std::string heredocs = "cat";
    for (std::size_t i = 0; i < max_heredocs + 1; ++i) {
      heredocs += " <<E";
    }
    check(lex(heredocs, posix, tokens).completeness == Completeness::limit, "heredoc count", heredocs);
    const std::string long_delimiter = "cat <<" + std::string(max_delimiter + 1, 'x') + "\n";
    check(lex(long_delimiter, posix, tokens).completeness == Completeness::limit, "delimiter length", "<<xxx...");
    const std::string fits = "cat <<" + std::string(max_delimiter, 'x') + "\n" + std::string(max_delimiter, 'x');
    check(lex(fits, posix, tokens).completeness == Completeness::complete, "delimiter fits", "<<xxx...");
  }

  void testOverflow() {
    std::array<Token, 2> small;
    const std::string_view line = "a b c d |";
    const Lexed lexed = lex(line, posix, small);
    check(lexed.overflow && lexed.tokens == 2, "token overflow", line);
    check(lexed.completeness == Completeness::trailing_operator && lexed.commands == 1, "verdict survives overflow", line);

    std::array<Word, 8> words;
    std::array<char, 64> text;
    check(commandAt(line, posix, small, lex(line, posix, small, 3), words, text).overflow, "commandAt on overflow", line);

    std::array<Token, 16> tokens;
    const std::string_view two = "ab cd";
    const Lexed full = lex(two, posix, tokens, 5);
    std::array<Word, 1> one_word;
    check(commandAt(two, posix, tokens, full, one_word, text).overflow, "word overflow", two);
    std::array<char, 3> short_text;
    check(commandAt(two, posix, tokens, full, words, short_text).overflow, "text overflow", two);
    std::array<char, 4> exact_words;
    check(commandAt(two, posix, tokens, full, words, exact_words).overflow, "prefix overflow", two);
    std::array<char, 6> enough;
    const CommandAt at = commandAt(two, posix, tokens, full, words, enough);
    check(!at.overflow && at.prefix == "cd", "prefix fits", two);

    // Tokens that do not match the line are rejected without reading past it.
    std::array<Token, 16> forged = tokens;
    forged[0].end = 99;
    check(commandAt(two, posix, forged, full, words, text).overflow, "forged bounds", two);
    forged = tokens;
    std::swap(forged[0], forged[1]);
    check(commandAt(two, posix, forged, full, words, text).overflow, "forged order", two);

    const std::string_view many = "a | b | c";
    const Lexed m = lex(many, posix, tokens);
    std::array<Segment, 2> segments;
    check(segment(std::span{tokens}.first(m.tokens), segments) == 3, "segment overflow count", many);
  }

  std::string renderSegments(std::string_view line, std::span<const Token> tokens) {
    std::array<Segment, 32> segments;
    const std::size_t count = segment(tokens, segments);
    std::string out;
    for (std::size_t i = 0; i < count; ++i) {
      if (i > 0) {
        out += '#';
      }
      out += line.substr(segments[i].source.begin, segments[i].source.end - segments[i].source.begin);
    }
    return out;
  }

  void testSegments() {
    const TokenCase cases[] = {
        {posix, "a b | c $(d e) && f", "a b#c $(d e)#d e#f"},
        {posix, "if x; then y > z; fi; w", "if x#then y > z#fi#w"},
        {posix, "FOO=1 cmd 2>&1 | less", "FOO=1 cmd 2>&1#less"},
        {posix, "for i in a b; do :; done", "for i in a b#do :#done"},
        {fish, "set x (a | b); and c", "set x (a | b)#a#b#and c"},
    };
    std::array<Token, 64> tokens;
    for (const TokenCase &c : cases) {
      const Lexed lexed = lex(c.line, c.syntax, tokens);
      const std::string got = renderSegments(c.line, std::span{tokens}.first(lexed.tokens));
      check(got == c.expected && lexed.commands == std::ranges::count(got, '#') + 1, "segments", c.line, got);
    }
  }

  struct CursorCase {
    Syntax syntax;
    std::string_view line; // contains mark once
    std::string_view expected;
  };

  std::string renderCursor(std::string_view line, const CommandAt &at, std::span<const Word> words, bool completable) {
    if (!completable) {
      return "none";
    }
    std::string out = "words=";
    for (std::size_t i = 0; i < at.words; ++i) {
      if (i > 0) {
        out += ',';
      }
      out += words[i].text;
      if (words[i].flags & Token::redirect_target) {
        out += "(>)";
      }
    }
    out += " cmd=";
    out += at.command_word == no_word ? std::string{"-"} : std::to_string(at.command_word);
    out += " cur=" + std::to_string(at.current);
    out += at.in_word ? " in" : " gap";
    out += " prefix=";
    out += at.prefix;
    out += " replace=";
    out += line.substr(at.replace.begin, at.replace.end - at.replace.begin);
    return out;
  }

  void testCursor() {
    const CursorCase cases[] = {
        {posix, "git chec¦", "words=git,chec cmd=0 cur=1 in prefix=chec replace=chec"},
        {posix, "git ch¦ec", "words=git,chec cmd=0 cur=1 in prefix=ch replace=chec"},
        {posix, "git ¦chec", "words=git,chec cmd=0 cur=1 in prefix= replace=chec"},
        {posix, "¦git", "words=git cmd=0 cur=0 in prefix= replace=git"},
        {posix, "git ¦", "words=git cmd=0 cur=1 gap prefix= replace="},
        {posix, "git a ¦ b", "words=git,a,b cmd=0 cur=2 gap prefix= replace="},
        {posix, "¦", "words= cmd=- cur=0 gap prefix= replace="},
        {posix, "echo \"foo b¦ar\"", "words=echo,foo bar cmd=0 cur=1 in prefix=foo b replace=\"foo bar\""},
        {posix, "echo 'a b'¦", "words=echo,a b cmd=0 cur=1 in prefix=a b replace='a b'"},
        {posix, "echo \"a b¦", "words=echo,a b cmd=0 cur=1 in prefix=a b replace=\"a b"},
        {posix, "echo a\\ b¦", "words=echo,a b cmd=0 cur=1 in prefix=a b replace=a\\ b"},
        {posix, "ec\\\nho¦", "words=echo cmd=0 cur=0 in prefix=echo replace=ec\\\nho"},
        {posix, "echo $'a\\tb¦'", "words=echo,a\tb cmd=0 cur=1 in prefix=a\tb replace=$'a\\tb'"},
        {posix, "echo $'\\x41\\u00e9\\101'¦", "words=echo,AéA cmd=0 cur=1 in prefix=AéA replace=$'\\x41\\u00e9\\101'"},
        {posix, "echo \"$HOME\"/x¦", "words=echo,$HOME/x cmd=0 cur=1 in prefix=$HOME/x replace=\"$HOME\"/x"},
        {posix, "ls | gr¦", "words=gr cmd=0 cur=0 in prefix=gr replace=gr"},
        {posix, "ls |¦", "words= cmd=- cur=0 gap prefix= replace="},
        {posix, "ls && ¦", "words= cmd=- cur=0 gap prefix= replace="},
        {posix, "ls && ¦  grep x", "words=grep,x cmd=0 cur=0 gap prefix= replace="},
        {posix, "x | y¦ | z", "words=y cmd=0 cur=0 in prefix=y replace=y"},
        {posix, "FOO=1 ma¦", "words=FOO=1,ma cmd=1 cur=1 in prefix=ma replace=ma"},
        {posix, "FOO=1 ¦", "words=FOO=1 cmd=- cur=1 gap prefix= replace="},
        {posix, "sudo apt ins¦", "words=sudo,apt,ins cmd=0 cur=2 in prefix=ins replace=ins"},
        {posix, "echo $(git ch¦)", "words=git,ch cmd=0 cur=1 in prefix=ch replace=ch"},
        {posix, "echo $(git ch) ¦", "words=echo,$(git ch) cmd=0 cur=2 gap prefix= replace="},
        {posix, "echo $( ¦)", "words= cmd=- cur=0 gap prefix= replace="},
        {posix, "echo \"x $(da¦te) y\"", "words=date cmd=0 cur=0 in prefix=da replace=date"},
        {posix, "echo ${HO¦", "words=echo,${HO cmd=0 cur=1 in prefix=${HO replace=${HO"},
        {posix, "cat > fi¦", "words=cat,fi(>) cmd=0 cur=1 in prefix=fi replace=fi"},
        {posix, "cat <<E¦", "words=cat,E(>) cmd=0 cur=1 in prefix=E replace=E"},
        {posix, "if gi¦", "words=if,gi cmd=1 cur=1 in prefix=gi replace=gi"},
        {posix, "if ¦", "words=if cmd=- cur=1 gap prefix= replace="},
        {posix, "if¦", "words=if cmd=- cur=0 in prefix=if replace=if"},
        {posix, "for i in ¦", "words=for,i,in cmd=- cur=3 gap prefix= replace="},
        {posix, "¦ if a; then b; fi", "words=if,a cmd=1 cur=0 gap prefix= replace="},
        {posix, "[[ -f fi¦ ]]", "words=[[,-f,fi,]] cmd=- cur=2 in prefix=fi replace=fi"},
        {posix, "a=(x ¦)", "words=a=(x ) cmd=- cur=0 in prefix=a=(x  replace=a=(x )"},
        {posix, "echo # com¦", "none"},
        {posix, "echo # com\nls ¦", "words=ls cmd=0 cur=1 gap prefix= replace="},
        {posix, "cat <<E\nbo¦dy\nE", "none"},
        {posix, "cat <<E\nbody\nE\nl¦", "words=l cmd=0 cur=0 in prefix=l replace=l"},

        {fish, "set -l fo¦", "words=set,-l,fo cmd=0 cur=2 in prefix=fo replace=fo"},
        {fish, "echo (git ch¦)", "words=git,ch cmd=0 cur=1 in prefix=ch replace=ch"},
        {fish, "true; and gi¦", "words=and,gi cmd=1 cur=1 in prefix=gi replace=gi"},
        {fish, "echo 'it\\'s¦'", "words=echo,it's cmd=0 cur=1 in prefix=it's replace='it\\'s'"},
        {fish, "echo \\u00e9¦", "words=echo,é cmd=0 cur=1 in prefix=é replace=\\u00e9"},
        {fish, "echo a\\nb\\x41¦", "words=echo,a\nbA cmd=0 cur=1 in prefix=a\nbA replace=a\\nb\\x41"},
        {fish, "echo \"a\\$b\\q¦\"", "words=echo,a$b\\q cmd=0 cur=1 in prefix=a$b\\q replace=\"a\\$b\\q\""},
    };
    std::array<Token, 64> tokens;
    std::array<Word, 32> words;
    std::array<char, 512> text;
    for (const CursorCase &c : cases) {
      const std::size_t cursor = c.line.find(mark);
      std::string line{c.line};
      line.erase(cursor, mark.size());
      const Lexed lexed = lex(line, c.syntax, tokens, cursor);
      const CommandAt at = commandAt(line, c.syntax, tokens, lexed, words, text);
      const std::string got = renderCursor(line, at, words, lexed.cursor_completable);
      check(!at.overflow && got == c.expected, "cursor", c.line, got);
    }

    std::array<Token, 8> few;
    check(!lex("ab", posix, few, 3).cursor_completable, "cursor past line", "ab");
    check(!lex("ab", posix, few).cursor_completable, "no cursor", "ab");
    check(lex("\xc3\xa9", posix, few, 1).cursor == 0, "cursor inside a sequence", "é");
    check(lex("a\xc3\xa9", posix, few, 2).cursor == 1, "cursor inside a later sequence", "aé");
  }

  // Random lines biased towards shell syntax must keep every invariant, and
  // under the sanitizer build, stay in bounds.
  void testFuzz() {
    constexpr std::string_view alphabet = " \t\n;&|<>()[]{}'\"`$\\#=-!*?~:%^,.0129abfiondesac";
    constexpr std::string_view fragments[] = {
        "if ",
        "then ",
        "fi",
        "do ",
        "done",
        "case ",
        "esac",
        "in ",
        "for ",
        "while ",
        "begin",
        "end",
        "function ",
        "$(",
        "${",
        "$((",
        "<<",
        "<<-",
        "<<<",
        "2>&1",
        "&&",
        "||",
        "|&",
        ";;",
        "[[",
        "]]",
        "((",
        "))",
        "\\\n",
        "EOF",
        "\nEOF\n",
        "\xc3\xa9",
        "\xe2\x82\xac",
        "\xf0\x9f\x98\x80",
        "\x80",
        "\xff",
        "$'",
        "a=(",
        "=(",
    };
    std::mt19937_64 random{0x7e1a5};
    std::vector<Token> tokens(512);
    std::vector<Word> words(512);
    std::vector<char> text(1024);
    std::string line;
    std::size_t checked = 0;
    for (int round = 0; round < 60000; ++round) {
      line.clear();
      const std::size_t length = random() % 220;
      while (line.size() < length) {
        const std::uint64_t pick = random() % 10;
        if (pick < 6) {
          line += alphabet[random() % alphabet.size()];
        } else if (pick < 9) {
          line += fragments[random() % std::size(fragments)];
        } else {
          line += static_cast<char>(random() % 256);
        }
      }
      for (const Syntax syntax : {posix, fish, Syntax{Dialect::posix, false}}) {
        const std::size_t cursor = random() % (line.size() + 2);
        // An exact-size buffer must never overflow; the bound holds for any input.
        const Lexed lexed = lex(line, syntax, std::span{tokens}.first(line.size()), cursor);
        bool ok = !lexed.overflow && lexed.tokens <= line.size();
        std::uint32_t last_end = 0;
        for (std::size_t i = 0; ok && i < lexed.tokens; ++i) {
          const Token &t = tokens[i];
          ok = t.begin < t.end && t.end <= line.size() && t.begin >= last_end &&
               (t.command == no_command || t.command < lexed.commands);
          last_end = t.end;
        }
        const CommandAt at = commandAt(line, syntax, std::span{tokens}.first(lexed.tokens), lexed,
                                       std::span{words}.first(line.size()), std::span{text}.first(2 * line.size()));
        ok = ok && !at.overflow && at.words <= line.size() && at.replace.begin <= at.replace.end &&
             at.replace.end <= line.size() && (!at.in_word || at.current < at.words);
        for (std::size_t i = 0; ok && i < at.words; ++i) {
          ok = words[i].source.end <= line.size() && words[i].text.size() <= words[i].source.end - words[i].source.begin;
        }
        std::array<Segment, 8> segments;
        ok = ok && segment(std::span{tokens}.first(lexed.tokens), segments) == lexed.commands;
        // Small buffers only report overflow.
        std::array<Token, 3> small;
        const Lexed short_lexed = lex(line, syntax, small, cursor);
        ok = ok && short_lexed.completeness == lexed.completeness && short_lexed.commands == lexed.commands &&
             short_lexed.cursor_command == lexed.cursor_command;
        check(ok, "fuzz invariant", line);
        if (!ok) {
          return;
        }
        ++checked;
      }
    }
    check(checked > 0, "fuzz ran", "");
  }

  // With valid UTF-8, no token boundary falls inside a multibyte sequence.
  void testUtf8Boundaries() {
    constexpr std::string_view pieces[] = {"é", "€", "😀", " ", "\"", "'", "$", "\\", "(", ")", "|", "a", "$(", "${", "\n"};
    std::mt19937_64 random{42};
    std::vector<Token> tokens(256);
    for (int round = 0; round < 20000; ++round) {
      std::string line;
      const std::size_t count = random() % 40;
      for (std::size_t i = 0; i < count; ++i) {
        line += pieces[random() % std::size(pieces)];
      }
      for (const Syntax syntax : {posix, fish}) {
        const Lexed lexed = lex(line, syntax, std::span{tokens}.first(line.size()));
        for (std::size_t i = 0; i < lexed.tokens; ++i) {
          const auto continuation = [&](std::uint32_t at) {
            return at < line.size() && (static_cast<unsigned char>(line[at]) & 0xc0) == 0x80;
          };
          if (continuation(tokens[i].begin) || continuation(tokens[i].end)) {
            check(false, "utf8 boundary", line);
            return;
          }
        }
      }
    }
  }

}

int main() {
  testTokens();
  testFlags();
  testCompleteness();
  testLimits();
  testOverflow();
  testSegments();
  testCursor();
  testFuzz();
  testUtf8Boundaries();
  if (failures > 0) {
    std::println(std::cerr, "{} failures", failures);
    return 1;
  }
  std::println("telar-shell: all checks passed");
  return 0;
}
