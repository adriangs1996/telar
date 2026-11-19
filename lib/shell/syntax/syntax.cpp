module telar.shell.syntax;

import std;

namespace telar::shell {
  namespace {

    using u8 = std::uint8_t;
    using u32 = std::uint32_t;

    // Byte classes. Bytes >= 0x80 have none, so they are word characters and a
    // token boundary never falls inside a UTF-8 sequence.
    enum : u8 {
      k_blank = 1 << 0,
      k_newline = 1 << 1,
      k_end = 1 << 2,  // ends a word
      k_stop = 1 << 3, // ends a literal run
      k_name = 1 << 4,
      k_name_start = 1 << 5,
      k_digit = 1 << 6,
      k_quote_stop = 1 << 7, // ends a run inside double quotes
    };

    using Table = std::array<u8, 256>;

    consteval Table makeTable(Dialect dialect) {
      Table table{};
      const bool posix = dialect == Dialect::posix;

      for (int c = 0; c < 256; ++c) {
        u8 bits = 0;

        if (c == ' ' || c == '\t') {
          bits |= k_blank | k_end | k_stop;
        }

        if (c == '\n') {
          bits |= k_newline | k_end | k_stop;
        }

        if (c == ';' || c == '&' || c == '|' || c == '<' || c == '>' || c == ')') {
          bits |= k_end | k_stop;
        }

        if (c == '(' || c == '\'' || c == '"' || c == '$' || c == '\\' || (posix && c == '`')) {
          bits |= k_stop;
        }

        if (c == '"' || c == '$' || c == '\\' || (posix && c == '`')) {
          bits |= k_quote_stop;
        }

        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
          bits |= k_name | k_name_start;
        }

        if (c >= '0' && c <= '9') {
          bits |= k_name | k_digit;
        }

        table[static_cast<std::size_t>(c)] = bits;
      }

      return table;
    }

    constexpr Table posix_table = makeTable(Dialect::posix);
    constexpr Table fish_table = makeTable(Dialect::fish);

    constexpr bool isPiece(TokenKind kind) noexcept {
      return kind <= TokenKind::substitution;
    }

    constexpr bool hexValue(char c, u32& value) noexcept {
      if (c >= '0' && c <= '9') {
        value = static_cast<u32>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        value = static_cast<u32>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        value = static_cast<u32>(c - 'A' + 10);
      } else {
        return false;
      }

      return true;
    }

    // Writes unquoted bytes into a caller buffer. Unquoting never produces more
    // bytes than it reads, so an output as large as the input never overflows.
    // Writes unquoted text into a buffer it borrows, region `a`, only ever appending, so the text it
    // returns views the buffer and stays valid as more is written.
    class Unquoter {
    public:
      Unquoter() noexcept = default;

      explicit Unquoter(tbc::view<std::span<char>, tbc::lt::a> out) noexcept
          : out_(out) {}

      [[nodiscard]] std::size_t size() const noexcept {
        return size_;
      }

      [[nodiscard]] bool overflow() const noexcept {
        return overflow_;
      }

      [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> text(std::size_t from) const noexcept {
        return {out_.data() + from, size_ - from};
      }

      void verbatim(std::string_view bytes) noexcept {
        for (const char c : bytes) {
          put(c);
        }
      }

      void piece(Dialect dialect, TokenKind kind, Quote quote, std::string_view bytes) noexcept {
        switch (kind) {
        case TokenKind::variable:
        case TokenKind::substitution:
          verbatim(bytes);
          return;
        case TokenKind::string:
          switch (quote) {
          case Quote::none: // the $ of a bash $"..." string
            return;
          case Quote::single_quoted:
            singleQuoted(dialect, bytes);
            return;
          case Quote::double_quoted:
            doubleQuoted(dialect, bytes);
            return;
          case Quote::ansi_c:
            ansiC(bytes);
            return;
          }

          return;
        default:
          literal(dialect, bytes);
          return;
        }
      }

    private:
      void put(char c) noexcept {
        if (size_ < out_.size()) {
          out_[size_++] = c;
        } else {
          overflow_ = true;
        }
      }

      void singleQuoted(Dialect dialect, std::string_view s) noexcept {
        for (std::size_t i = 0; i < s.size(); ++i) {
          const char c = s[i];
          if (dialect == Dialect::fish && c == '\\' && i + 1 < s.size() && (s[i + 1] == '\\' || s[i + 1] == '\'')) {
            put(s[++i]);
          } else if (c != '\'') {
            put(c);
          }
        }
      }

      void doubleQuoted(Dialect dialect, std::string_view s) noexcept {
        for (std::size_t i = 0; i < s.size(); ++i) {
          const char c = s[i];
          if (c == '"') {
            continue;
          }

          if (c != '\\') {
            put(c);
            continue;
          }

          if (i + 1 == s.size()) {
            return;
          }

          const char next = s[++i];
          const bool special = next == '"' || next == '$' || next == '\\' ||
                               (dialect == Dialect::posix && next == '`');

          if (next == '\n') {
            continue;
          }

          if (!special) {
            put('\\');
          }

          put(next);
        }
      }

      void literal(Dialect dialect, std::string_view s) noexcept {
        for (std::size_t i = 0; i < s.size(); ++i) {
          const char c = s[i];
          if (c != '\\') {
            put(c);
            continue;
          }

          if (i + 1 == s.size()) {
            return;
          }

          if (s[i + 1] == '\n') {
            ++i;
          } else if (dialect == Dialect::fish) {
            i = escape(s, i, false);
          } else {
            put(s[++i]);
          }
        }
      }

      void ansiC(std::string_view s) noexcept {
        bool inside = false;

        for (std::size_t i = 0; i < s.size(); ++i) {
          const char c = s[i];

          if (!inside) {
            if (c == '$' && i + 1 < s.size() && s[i + 1] == '\'') {
              inside = true;
              ++i;
            } else {
              put(c);
            }
          } else if (c == '\'') {
            inside = false;
          } else if (c == '\\' && i + 1 < s.size()) {
            i = escape(s, i, true);
          } else if (c != '\\') {
            put(c);
          }
        }
      }

      // Decodes the escape at s[i] == '\\' (with a byte after it) and returns the
      // index of its last byte. ANSI-C keeps unknown escapes; fish drops the slash.
      std::size_t escape(std::string_view s, std::size_t i, bool ansi) noexcept {
        const char c = s[i + 1];

        switch (c) {
        case 'a':
          put('\a');
          return i + 1;
        case 'b':
          put('\b');
          return i + 1;
        case 'e':
        case 'E':
          put('\x1b');
          return i + 1;
        case 'f':
          put('\f');
          return i + 1;
        case 'n':
          put('\n');
          return i + 1;
        case 'r':
          put('\r');
          return i + 1;
        case 't':
          put('\t');
          return i + 1;
        case 'v':
          put('\v');
          return i + 1;
        case 'c':
          if (i + 2 < s.size()) {
            put(static_cast<char>(s[i + 2] & 0x1f));
            return i + 2;
          }

          break;
        case 'x':
        case 'X':
        case 'u':
        case 'U': {
          if (c == 'X' && ansi) {
            break;
          }

          const std::size_t digits = c == 'u' ? 4 : (c == 'U' ? 8 : 2);
          u32 code = 0;
          std::size_t j = i + 2;

          for (u32 digit = 0; j < s.size() && j < i + 2 + digits && hexValue(s[j], digit); ++j) {
            code = code * 16 + digit;
          }

          if (j == i + 2) {
            break;
          }

          if (c == 'x' || c == 'X') {
            put(static_cast<char>(code));
          } else if (!utf8(code)) {
            verbatim(s.substr(i, j - i));
          }

          return j - 1;
        }
        default:
          if (c >= '0' && c <= '7') {
            u32 code = 0;
            std::size_t j = i + 1;

            for (; j < s.size() && j < i + 4 && s[j] >= '0' && s[j] <= '7'; ++j) {
              code = code * 8 + static_cast<u32>(s[j] - '0');
            }

            put(static_cast<char>(code & 0xff));
            return j - 1;
          }

          break;
        }

        if (ansi && c != '\\' && c != '\'' && c != '"' && c != '?') {
          put('\\');
        }

        put(c);
        return i + 1;
      }

      bool utf8(u32 code) noexcept {
        if (code < 0x80) {
          put(static_cast<char>(code));
        } else if (code < 0x800) {
          put(static_cast<char>(0xc0 | (code >> 6)));
          put(static_cast<char>(0x80 | (code & 0x3f)));
        } else if (code < 0x10000) {
          if (code >= 0xd800 && code <= 0xdfff) {
            return false;
          }

          put(static_cast<char>(0xe0 | (code >> 12)));
          put(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
          put(static_cast<char>(0x80 | (code & 0x3f)));
        } else if (code <= 0x10ffff) {
          put(static_cast<char>(0xf0 | (code >> 18)));
          put(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
          put(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
          put(static_cast<char>(0x80 | (code & 0x3f)));
        } else {
          return false;
        }

        return true;
      }

      tbc::view<std::span<char>, tbc::lt::a> out_;
      std::size_t size_ = 0;
      bool overflow_ = false;
    };

    enum class FrameKind : u8 {
      // Command lists and word lists.
      root,
      subshell,
      group,
      substitution,
      backtick,
      if_block,
      loop,
      case_block,
      fish_block,
      test,
      array,
      // Inside one word.
      double_quote,
      parameter,
      arithmetic,
    };

    constexpr bool isList(FrameKind kind) noexcept {
      return kind <= FrameKind::array;
    }

    enum class Position : u8 {
      start,       // command name, assignments and keywords may come
      prefix,      // after assignments: no keywords
      arguments,   // after the command name
      header,      // words after for/case/select/function/switch
      after_close, // after a compound command: redirections and operators
      pattern,     // case patterns
    };

    enum class Header : u8 {
      none,
      loop,      // for, select: `in` or `do` second
      case_word, // case: `in` second
      function,  // posix function: one name, then a body
      plain,
    };

    enum class Keyword : u8 {
      none,
      if_,
      then_,
      elif_,
      else_,
      fi,
      while_,
      until,
      for_,
      select,
      do_,
      done,
      case_,
      esac,
      in,
      function,
      time,
      coproc,
      bang,
      brace_open,
      brace_close,
      test_open,
      begin,
      end,
      switch_,
      and_,
      or_,
      not_,
    };

    // Keywords fit in eight bytes, so a word compares as one integer.
    constexpr std::uint64_t pack(std::string_view word) noexcept {
      std::uint64_t key = 0;

      for (std::size_t i = 0; i < word.size(); ++i) {
        key |= static_cast<std::uint64_t>(static_cast<unsigned char>(word[i])) << (8 * i);
      }

      return key;
    }

    struct KeywordName {
      std::uint64_t key;
      Keyword keyword;

      consteval KeywordName(std::string_view name, Keyword k)
          : key(pack(name)),
            keyword(k) {}
    };

    constexpr KeywordName posix_keywords[] = {
        {"if", Keyword::if_},
        {"then", Keyword::then_},
        {"elif", Keyword::elif_},
        {"else", Keyword::else_},
        {"fi", Keyword::fi},
        {"while", Keyword::while_},
        {"until", Keyword::until},
        {"for", Keyword::for_},
        {"select", Keyword::select},
        {"do", Keyword::do_},
        {"done", Keyword::done},
        {"case", Keyword::case_},
        {"esac", Keyword::esac},
        {"in", Keyword::in},
        {"function", Keyword::function},
        {"time", Keyword::time},
        {"coproc", Keyword::coproc},
        {"!", Keyword::bang},
        {"{", Keyword::brace_open},
        {"}", Keyword::brace_close},
        {"[[", Keyword::test_open},
    };

    constexpr KeywordName fish_keywords[] = {
        {"begin", Keyword::begin},
        {"end", Keyword::end},
        {"if", Keyword::if_},
        {"else", Keyword::else_},
        {"while", Keyword::while_},
        {"for", Keyword::for_},
        {"in", Keyword::in},
        {"function", Keyword::function},
        {"switch", Keyword::switch_},
        {"case", Keyword::case_},
        {"and", Keyword::and_},
        {"or", Keyword::or_},
        {"not", Keyword::not_},
        {"!", Keyword::not_},
        {"time", Keyword::time},
    };

    // Only words of one to eight plain bytes in command position get here.
    Keyword findKeyword(std::span<const KeywordName> names, std::string_view word) noexcept {
      const std::uint64_t key = pack(word);

      for (const KeywordName& entry : names) {
        if (entry.key == key) {
          return entry.keyword;
        }
      }

      return Keyword::none;
    }

    // Trivial so the frame stack is not initialized per call; push() starts from blank_frame.
    struct Frame {
      u32 command; // list: current command; word frames: the word's command
      u32 word_begin;
      u32 parens; // arithmetic nesting
      u32 owner;  // substitution and backtick: the word that holds them
      FrameKind kind;
      Position position;
      Header header;
      u8 header_words;
      TokenKind role;
      TokenKind owner_role;
      u8 word_flags;
      u8 owner_flags;
      u8 glob; // posix glob groups open inside the word: *(.) @(a|b)
      bool in_word;
      bool fresh; // the next piece starts the word
      bool pending_operator;
      bool pending_body;
      bool after_else;
      bool redirect; // the next word is a redirection target
      bool heredoc;  // ... and a heredoc delimiter
      bool strip_tabs;
      bool arithmetic_command;
    };

    constexpr Frame blank_frame{.command = no_command, .word_begin = 0, .parens = 0, .owner = no_command, .kind = FrameKind::root, .position = Position::start, .header = Header::none, .header_words = 0, .role = TokenKind::argument, .owner_role = TokenKind::argument, .word_flags = 0, .owner_flags = 0, .glob = 0, .in_word = false, .fresh = false, .pending_operator = false, .pending_body = false, .after_else = false, .redirect = false, .heredoc = false, .strip_tabs = false, .arithmetic_command = false};
    static_assert(std::is_trivially_default_constructible_v<Frame>);

    struct Heredoc {
      std::array<char, max_delimiter> text;
      std::size_t size = 0;
      bool strip_tabs = false;
    };

    class Lexer {
    public:
      Lexer(std::string_view line, Syntax syntax, std::span<Token> tokens, std::size_t cursor) noexcept
          : s_(line),
            n_(line.size()),
            table_(syntax.dialect == Dialect::fish ? fish_table : posix_table),
            syntax_(syntax),
            fish_(syntax.dialect == Dialect::fish),
            tokens_(tokens),
            cursor_(cursor) {
        frames_[0] = blank_frame;
        depth_ = 1;
        if (cursor_ > n_) {
          cursor_done_ = true;
        } else {
          while (cursor_ > 0 && cursor_ < n_ && (static_cast<unsigned char>(s_[cursor_]) & 0xc0) == 0x80 &&
                 cursor - cursor_ < 3) {
            --cursor_;
          }
        }
      }

      // The capture writes into a heredoc beside it, so the lexer stays where it was built.
      Lexer(const Lexer&) = delete;
      Lexer& operator=(const Lexer&) = delete;
      Lexer(Lexer&&) = delete;
      Lexer& operator=(Lexer&&) = delete;

      Lexed run() noexcept {
        if (n_ > max_line) {
          limited_ = true;
          return result();
        }

        // Every step consumes a byte except ending a word and starting one, and
        // neither happens twice in a row. A stall is a bug: fail closed.
        std::size_t stalled = 0;

        while (p_ < n_) {
          const std::size_t before = p_;
          const std::size_t frame = depth_ - 1;

          switch (frames_[frame].kind) {
          case FrameKind::double_quote:
            stepDouble(frame);
            break;
          case FrameKind::parameter:
            stepParameter(frame);
            break;
          case FrameKind::arithmetic:
            stepArithmetic(frame);
            break;
          default:
            stepList(frame);
            break;
          }

          stalled = p_ == before ? stalled + 1 : 0;
          if (stalled > 2) {
#if TELAR_DEBUG
            std::abort();
#endif
            fail();
          }
        }

        finish();
        return result();
      }

    private:
      [[nodiscard]] unsigned char at(std::size_t i) const noexcept {
        return static_cast<unsigned char>(s_[i]);
      }

      [[nodiscard]] u8 bits(std::size_t i) const noexcept {
        return table_[at(i)];
      }

      [[nodiscard]] bool next(std::size_t i, char c) const noexcept {
        return i < n_ && s_[i] == c;
      }

      [[nodiscard]] std::size_t level() const noexcept {
        return depth_ - 1;
      }

      Frame& top() noexcept {
        return frames_[depth_ - 1];
      }

      // ---- output

      void emit(TokenKind kind, TokenKind role, u32 command, Quote quote, u8 flags, std::size_t begin, std::size_t end) noexcept {
        if (capturing_ && command == capture_command_ && isPiece(kind)) {
          capture_.verbatim(s_.substr(capture_gap_, begin - capture_gap_));
          capture_.piece(syntax_.dialect, kind, quote, s_.substr(begin, end - begin));
          capture_gap_ = end;
        }

        if (overflow_) {
          return;
        }

        if (count_ > 0 && isPiece(kind) && (flags & Token::word_start) == 0) {
          Token& last = tokens_[count_ - 1];
          if (last.end == begin && last.kind == kind && last.role == role && last.command == command &&
              last.quote == quote && (last.flags & ~Token::word_start) == flags) {
            last.end = static_cast<u32>(end);
            return;
          }
        }

        if (count_ == tokens_.size()) {
          overflow_ = true;
          return;
        }

        tokens_[count_++] = Token{static_cast<u32>(begin), static_cast<u32>(end), command, kind, role, quote, flags};
      }

      void control(std::size_t length, TokenKind kind = TokenKind::control) noexcept {
        emit(kind, kind, no_command, Quote::none, 0, p_, p_ + length);
        p_ += length;
      }

      // A part of the word the frame is building.
      void out(std::size_t frame, TokenKind kind, Quote quote, std::size_t begin, std::size_t end, u8 extra = 0) noexcept {
        u8 flags = static_cast<u8>(frames_[frame].word_flags | extra);

        if (frames_[frame].fresh) {
          flags |= Token::word_start;
          frames_[frame].fresh = false;
        }

        emit(kind, frames_[frame].role, frames_[frame].command, quote, flags, begin, end);
      }

      // The rest of the line becomes one error token.
      void fail() noexcept {
        if (p_ < n_) {
          emit(TokenKind::error, TokenKind::error, no_command, Quote::none, 0, p_, n_);
        }

        p_ = n_;
        limited_ = true;
      }

      [[nodiscard]] bool room() noexcept {
        if (depth_ < max_depth) {
          return true;
        }

        fail();
        return false;
      }

      // The index of the frame pushed: the steps address frames by index, as each changes others, the
      // way Rust indexes `self.frames` rather than hold one across `&mut self` calls.
      std::size_t push(FrameKind kind, u32 command, TokenKind role) noexcept {
        const std::size_t frame = depth_++;

        frames_[frame] = blank_frame;
        frames_[frame].kind = kind;
        frames_[frame].command = command;
        frames_[frame].role = role;
        return frame;
      }

      void pop() noexcept {
        if (cursor_pending_ == level()) {
          cursor_pending_ = no_cursor;
        }

        --depth_;
      }

      // ---- commands and cursor

      void ensureCommand(std::size_t at_level) noexcept {
        const std::size_t frame = at_level;
        if (frames_[frame].command != no_command) {
          return;
        }

        frames_[frame].command = commands_++;
        if (cursor_pending_ == at_level) {
          cursor_command_ = frames_[frame].command;
          cursor_pending_ = no_cursor;
        }
      }

      void endCommand(std::size_t frame, std::size_t at_level, Position position) noexcept {
        frames_[frame].command = no_command;
        frames_[frame].position = position;
        frames_[frame].header = Header::none;
        frames_[frame].header_words = 0;
        frames_[frame].redirect = false;
        frames_[frame].heredoc = false;
        frames_[frame].after_else = false;
        if (cursor_pending_ == at_level) {
          cursor_pending_ = no_cursor;
        }
      }

      // At a boundary of the top list: the cursor before this element is
      // between words of the current command.
      void gap(bool inclusive) noexcept {
        if (cursor_done_ || !(cursor_ < p_ || (inclusive && cursor_ == p_))) {
          return;
        }

        cursor_done_ = true;
        cursor_completable_ = true;
        const std::size_t frame = depth_ - 1;
        if (frames_[frame].command != no_command) {
          cursor_command_ = frames_[frame].command;
        } else {
          cursor_pending_ = level();
        }
      }

      void touch(u32 command, std::size_t begin, std::size_t end) noexcept {
        if (!cursor_done_ && begin <= cursor_ && cursor_ <= end) {
          cursor_done_ = true;
          cursor_completable_ = true;
          cursor_command_ = command;
        }
      }

      void opaque(bool inside) noexcept {
        if (!cursor_done_ && inside) {
          cursor_done_ = true;
        }
      }

      // ---- command lists

      void stepList(std::size_t frame) noexcept {
        if (frames_[frame].in_word) {
          stepWord(frame);
          return;
        }

        const char c = s_[p_];
        if (c == ' ' || c == '\t') {
          ++p_;
          while (p_ < n_ && (bits(p_) & k_blank)) {
            ++p_;
          }

          return;
        }

        if (c == '\\' && next(p_ + 1, '\n')) {
          p_ += 2;
          return;
        }

        if (frames_[frame].kind == FrameKind::test) {
          testElement(frame);
          return;
        }

        if (frames_[frame].kind == FrameKind::array) {
          arrayElement(frame);
          return;
        }

        switch (c) {
        case '\n':
          gap(true);
          newline(frame);
          return;
        case ';':
          gap(true);
          semicolon(frame);
          return;
        case '&':
          gap(true);
          ampersand(frame);
          return;
        case '|':
          gap(true);
          pipe(frame);
          return;
        case '<':
        case '>':
          if (!fish_ && next(p_ + 1, '(')) {
            break;
          }

          gap(true);
          redirection(frame, p_);
          return;
        case '(':
          if (fish_) {
            break;
          }

          if (next(p_ + 1, ')')) {
            gap(true);
            control(2);
            endCommand(frame, level(), Position::start);
            frames_[frame].pending_body = true;
            return;
          }

          if (frames_[frame].position == Position::pattern) {
            gap(true);
            control(1);
            return;
          }

          if (frames_[frame].position == Position::start || frames_[frame].position == Position::after_close ||
              (frames_[frame].position == Position::header && frames_[frame].header == Header::loop && frames_[frame].header_words == 0)) {
            gap(true);
            if (next(p_ + 1, '(')) {
              arithmeticCommand(frame);
            } else {
              subshell(frame);
            }

            return;
          }

          break;
        case ')':
          gap(true);
          closeParen(frame);
          return;
        case '`':
          if (!fish_ && frames_[frame].kind == FrameKind::backtick) {
            gap(true);
            closeList(frame);
            return;
          }

          break;
        case '#':
          if (syntax_.comments) {
            gap(true);
            comment();
            return;
          }

          break;
        default:
          if (bits(p_) & k_digit) {
            std::size_t q = p_ + 1;

            while (q < n_ && (bits(q) & k_digit)) {
              ++q;
            }

            if (q < n_ && (s_[q] == '<' || s_[q] == '>') && !(!fish_ && next(q + 1, '('))) {
              gap(true);
              redirection(frame, q);
              return;
            }
          }

          break;
        }

        gap(false);
        beginWord(frame);
      }

      void operatorEnd(std::size_t frame, std::size_t length, bool pending, Position position = Position::start) noexcept {
        control(length);
        endCommand(frame, level(), position);
        frames_[frame].pending_operator = pending;
        frames_[frame].pending_body = false;
      }

      void newline(std::size_t frame) noexcept {
        control(1);
        if (frames_[frame].position != Position::pattern && (frames_[frame].command != no_command || frames_[frame].position != Position::start)) {
          endCommand(frame, level(), Position::start);
        }

        if (heredoc_count_ > 0) {
          readHeredocs();
        }
      }

      void semicolon(std::size_t frame) noexcept {
        if (!fish_) {
          std::size_t length = 0;

          if (next(p_ + 1, ';')) {
            length = next(p_ + 2, '&') ? 3 : 2;
          } else if (next(p_ + 1, '&') || next(p_ + 1, '|')) {
            length = 2;
          }

          if (length > 0) {
            if (frames_[frame].kind == FrameKind::case_block && frames_[frame].position != Position::pattern) {
              operatorEnd(frame, length, false, Position::pattern);
            } else {
              control(length, TokenKind::error);
              endCommand(frame, level(), Position::start);
            }

            return;
          }
        }

        operatorEnd(frame, 1, false);
      }

      void ampersand(std::size_t frame) noexcept {
        if (next(p_ + 1, '&')) {
          operatorEnd(frame, 2, true);
        } else if (next(p_ + 1, '>')) {
          redirection(frame, p_);
        } else if (next(p_ + 1, '|')) {
          operatorEnd(frame, 2, fish_); // fish pipes both streams; zsh disowns
        } else if (!fish_ && next(p_ + 1, '!')) {
          operatorEnd(frame, 2, false);
        } else {
          operatorEnd(frame, 1, false);
        }
      }

      void pipe(std::size_t frame) noexcept {
        const std::size_t length = next(p_ + 1, '|') || (!fish_ && next(p_ + 1, '&')) ? 2 : 1;

        if (frames_[frame].position == Position::pattern) {
          control(length);
          return;
        }

        operatorEnd(frame, length, true);
      }

      // p_ starts the redirection (at its file descriptor, if any); op is its first < > or &.
      void redirection(std::size_t frame, std::size_t op) noexcept {
        std::size_t e = op + 1;
        bool target = true;
        bool heredoc = false;
        bool strip = false;
        const auto duplicate = [&] {
          if (next(e, '-')) {
            ++e;
            target = false;
          } else if (e < n_ && (bits(e) & k_digit)) {
            while (e < n_ && (bits(e) & k_digit)) {
              ++e;
            }

            target = false;
          }
        };

        if (s_[op] == '&') { // &> &>>
          e = next(op + 2, '>') ? op + 3 : op + 2;
        } else if (s_[op] == '<') {
          if (!fish_ && next(op + 1, '<')) {
            if (next(op + 2, '<')) {
              e = op + 3;
            } else {
              heredoc = true;
              e = op + 2;
              if (next(e, '-')) {
                strip = true;
                ++e;
              }
            }
          } else if (next(op + 1, '&')) {
            e = op + 2;
            duplicate();
          } else if (!fish_ && next(op + 1, '>')) {
            e = op + 2;
          }
        } else if (next(op + 1, '>')) {
          e = op + 2;
        } else if (next(op + 1, '&')) {
          e = op + 2;
          duplicate();
        } else if (next(op + 1, '|')) {
          if (fish_) { // 2>| pipes a stream
            operatorEnd(frame, op + 2 - p_, true);
            return;
          }

          e = op + 2;
        } else if ((fish_ && next(op + 1, '?')) || (!fish_ && next(op + 1, '!'))) {
          e = op + 2;
        }

        if (heredoc && heredoc_count_ == max_heredocs) {
          fail();
          return;
        }

        ensureCommand(level());
        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        emit(TokenKind::redirection, TokenKind::redirection, frames_[frame].command, Quote::none, 0, p_, e);
        p_ = e;
        frames_[frame].redirect = target;
        frames_[frame].heredoc = heredoc;
        frames_[frame].strip_tabs = strip;
      }

      void comment() noexcept {
        std::size_t q = s_.find('\n', p_);
        if (q == std::string_view::npos) {
          q = n_;
        }

        opaque(p_ < cursor_ && cursor_ <= q);
        control(q - p_, TokenKind::comment);
      }

      void subshell(std::size_t frame) noexcept {
        if (!room()) {
          return;
        }

        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        if (cursor_pending_ == level()) {
          cursor_pending_ = no_cursor;
        }

        control(1);
        push(FrameKind::subshell, no_command, TokenKind::argument);
      }

      void arithmeticCommand(std::size_t frame) noexcept {
        if (!room()) {
          return;
        }

        ensureCommand(level());
        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        emit(TokenKind::keyword, TokenKind::keyword, frames_[frame].command, Quote::none, Token::word_start, p_, p_ + 2);
        p_ += 2;
        const std::size_t g = push(FrameKind::arithmetic, frames_[frame].command, TokenKind::keyword);

        frames_[g].arithmetic_command = true;
      }

      // A substitution or backtick frame ends at the boundary of its list.
      void closeList(std::size_t frame) noexcept {
        emit(TokenKind::substitution, frames_[frame].owner_role, frames_[frame].owner, Quote::none, frames_[frame].owner_flags, p_, p_ + 1);
        ++p_;
        pop();
      }

      void closeParen(std::size_t frame) noexcept {
        if (frames_[frame].kind == FrameKind::substitution) {
          closeList(frame);
        } else if (frames_[frame].kind == FrameKind::subshell) {
          control(1);
          pop();
          top().position = Position::after_close;
        } else if (frames_[frame].position == Position::pattern) {
          control(1);
          endCommand(frame, level(), Position::start);
        } else {
          control(1, TokenKind::error);
        }
      }

      void testElement(std::size_t frame) noexcept {
        const char c = s_[p_];
        if (c == '\n') {
          ++p_;
          return;
        }

        if (c == '&' || c == '|') {
          gap(true);
          control(next(p_ + 1, c) ? 2 : 1, next(p_ + 1, c) ? TokenKind::control : TokenKind::error);
          return;
        }

        if (c == '<' || c == '>' || c == '(' || c == ')') {
          gap(true);
          control(1);
          return;
        }

        if (c == ';') {
          gap(true);
          control(1, TokenKind::error);
          return;
        }

        gap(false);
        if (c == ']' && next(p_ + 1, ']') && (p_ + 2 == n_ || (bits(p_ + 2) & k_end))) {
          emit(TokenKind::keyword, TokenKind::keyword, frames_[frame].command, Quote::none, Token::word_start, p_, p_ + 2);
          touch(frames_[frame].command, p_, p_ + 2);
          p_ += 2;
          pop();
          top().position = Position::after_close;
          return;
        }

        startWord(frame, optionOrArgument());
      }

      void arrayElement(std::size_t frame) noexcept {
        const char c = s_[p_];
        if (c == '\n') {
          ++p_;
          return;
        }

        if (c == ')') {
          gap(true);
          out(frame, TokenKind::assignment, Quote::none, p_, p_ + 1);
          ++p_;
          pop();
          return;
        }

        if (c == '#' && syntax_.comments) {
          gap(true);
          comment();
          return;
        }

        if (bits(p_) & k_end) {
          gap(true);
          control(1, TokenKind::error);
          return;
        }

        gap(false);
        frames_[frame].in_word = true;
        frames_[frame].word_begin = static_cast<u32>(p_);
      }

      [[nodiscard]] TokenKind optionOrArgument() const noexcept {
        return s_[p_] == '-' && !(p_ + 1 < n_ && (bits(p_ + 1) & k_end)) ? TokenKind::option : TokenKind::argument;
      }

      void startWord(std::size_t frame, TokenKind role) noexcept {
        frames_[frame].in_word = true;
        frames_[frame].fresh = true;
        frames_[frame].word_begin = static_cast<u32>(p_);
        frames_[frame].glob = 0;
        frames_[frame].role = role;
        frames_[frame].word_flags = 0;
        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        frames_[frame].after_else = false;
      }

      [[nodiscard]] bool isAssignment(std::size_t q) const noexcept {
        if (!(bits(p_) & k_name_start)) {
          return false;
        }

        std::size_t i = p_ + 1;

        while (i < q && (bits(i) & k_name)) {
          ++i;
        }

        if (i < q && s_[i] == '=') {
          return true;
        }

        if (fish_ || i >= q) {
          return false;
        }

        if (s_[i] == '+') {
          return i + 1 < q && s_[i + 1] == '=';
        }

        if (s_[i] == '[') {
          const std::size_t close = s_.substr(i, q - i).find(']');

          return close != std::string_view::npos && i + close + 1 < q && s_[i + close + 1] == '=';
        }

        return false;
      }

      void beginWord(std::size_t frame) noexcept {
        std::size_t q = p_;

        while (q < n_ && !(bits(q) & k_stop)) {
          ++q;
        }

        const bool whole = q == n_ || (bits(q) & k_end);
        if (!frames_[frame].redirect && whole && q - p_ <= 8 && q > p_ && keyword(frame, q)) {
          return;
        }

        ensureCommand(level());
        const Position position = frames_[frame].position;

        startWord(frame, TokenKind::argument);
        if (frames_[frame].redirect) {
          frames_[frame].word_flags = Token::redirect_target;
          if (frames_[frame].heredoc) {
            capturing_ = true;
            capture_command_ = frames_[frame].command;
            capture_gap_ = p_;
            capture_ = Unquoter{heredocs_[heredoc_count_].text};
          }
        } else {
          switch (position) {
          case Position::start:
          case Position::prefix:
            if (isAssignment(q)) {
              frames_[frame].role = TokenKind::assignment;
              frames_[frame].position = Position::prefix;
            } else {
              frames_[frame].role = TokenKind::command;
              frames_[frame].position = Position::arguments;
            }

            break;
          case Position::arguments:
          case Position::header:
            frames_[frame].role = optionOrArgument();
            break;
          case Position::after_close:
          case Position::pattern:
            break;
          }
        }

        if (!fish_ && (s_[p_] == '<' || s_[p_] == '>' || s_[p_] == '=') && next(p_ + 1, '(')) {
          openList(frame, FrameKind::substitution, p_ + 2);
          return;
        }

        if (q > p_) {
          out(frame, frames_[frame].role, Quote::none, p_, q);
          p_ = q;
          if (!fish_ && frames_[frame].role == TokenKind::assignment && s_[q - 1] == '=' && next(q, '(')) {
            if (room()) {
              out(frame, TokenKind::assignment, Quote::none, q, q + 1);
              ++p_;
              const std::size_t g = push(FrameKind::array, frames_[frame].command, TokenKind::assignment);

              frames_[g].word_flags = frames_[frame].word_flags;
            }
          }
        }
      }

      // Emits the keyword at [p_, q) and updates the lists; false if the word
      // is not a keyword where it stands.
      bool keyword(std::size_t frame, std::size_t q) noexcept {
        const std::string_view word = s_.substr(p_, q - p_);
        const Keyword k = findKeyword(fish_ ? std::span<const KeywordName>{fish_keywords} : std::span<const KeywordName>{posix_keywords}, word);
        if (k == Keyword::none) {
          return false;
        }

        switch (frames_[frame].position) {
        case Position::start:
        case Position::after_close:
          break;
        case Position::header:
          if (k == Keyword::in && frames_[frame].header_words == 1 && (frames_[frame].header == Header::loop || frames_[frame].header == Header::case_word)) {
            word_keyword(frame, q);
            ++frames_[frame].header_words;
            if (frames_[frame].header == Header::case_word) {
              endCommand(frame, level(), Position::pattern);
            }

            return true;
          }

          if (!fish_ && k == Keyword::do_ && frames_[frame].header_words == 1 && frames_[frame].header == Header::loop) {
            endCommand(frame, level(), Position::start);
            word_keyword(frame, q);
            return true;
          }

          return false;
        case Position::pattern:
          if (k == Keyword::esac && frames_[frame].command == no_command) {
            close(frame, FrameKind::case_block, q);
            return true;
          }

          return false;
        default:
          return false;
        }

        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        if (fish_) {
          return fishKeywordAt(frame, k, q);
        }

        switch (k) {
        case Keyword::if_:
          open(FrameKind::if_block, Position::start, Header::none, q);
          return true;
        case Keyword::while_:
        case Keyword::until:
          open(FrameKind::loop, Position::start, Header::none, q);
          return true;
        case Keyword::for_:
        case Keyword::select:
          open(FrameKind::loop, Position::header, Header::loop, q);
          return true;
        case Keyword::case_:
          open(FrameKind::case_block, Position::header, Header::case_word, q);
          return true;
        case Keyword::brace_open:
          open(FrameKind::group, Position::start, Header::none, q);
          return true;
        case Keyword::fi:
          close(frame, FrameKind::if_block, q);
          return true;
        case Keyword::done:
          close(frame, FrameKind::loop, q);
          return true;
        case Keyword::esac:
          close(frame, FrameKind::case_block, q);
          return true;
        case Keyword::brace_close:
          close(frame, FrameKind::group, q);
          return true;
        case Keyword::test_open:
          if (room()) {
            ensureCommand(level());
            word_keyword(frame, q);
            frames_[push(FrameKind::test, frames_[frame].command, TokenKind::argument)].position = Position::arguments;
          }

          return true;
        case Keyword::function:
          word_keyword(frame, q);
          frames_[frame].position = Position::header;
          frames_[frame].header = Header::function;
          frames_[frame].header_words = 0;
          return true;
        case Keyword::then_:
        case Keyword::elif_:
        case Keyword::else_:
        case Keyword::do_:
        case Keyword::bang:
        case Keyword::time:
        case Keyword::coproc:
          word_keyword(frame, q);
          frames_[frame].position = Position::start;
          return true;
        default:
          return false;
        }
      }

      bool fishKeywordAt(std::size_t frame, Keyword k, std::size_t q) noexcept {
        switch (k) {
        case Keyword::begin:
          open(FrameKind::fish_block, Position::start, Header::none, q);
          return true;
        case Keyword::if_:
          if (frames_[frame].after_else) {
            word_keyword(frame, q);
            frames_[frame].position = Position::start;
            frames_[frame].after_else = false;
          } else {
            open(FrameKind::fish_block, Position::start, Header::none, q);
          }

          return true;
        case Keyword::while_:
          open(FrameKind::fish_block, Position::start, Header::none, q);
          return true;
        case Keyword::for_:
          open(FrameKind::fish_block, Position::header, Header::loop, q);
          return true;
        case Keyword::function:
        case Keyword::switch_:
          open(FrameKind::fish_block, Position::header, Header::plain, q);
          return true;
        case Keyword::end:
          close(frame, FrameKind::fish_block, q);
          return true;
        case Keyword::else_:
          word_keyword(frame, q);
          frames_[frame].position = Position::start;
          frames_[frame].after_else = true;
          return true;
        case Keyword::case_:
          word_keyword(frame, q);
          frames_[frame].position = Position::header;
          frames_[frame].header = Header::plain;
          frames_[frame].header_words = 0;
          return true;
        case Keyword::and_:
        case Keyword::or_:
        case Keyword::not_:
        case Keyword::time:
          word_keyword(frame, q);
          frames_[frame].position = Position::start;
          return true;
        default:
          return false;
        }
      }

      // A keyword word joins the command that follows it.
      void word_keyword(std::size_t frame, std::size_t q) noexcept {
        ensureCommand(level());
        emit(TokenKind::keyword, TokenKind::keyword, frames_[frame].command, Quote::none, Token::word_start, p_, q);
        touch(frames_[frame].command, p_, q);
        p_ = q;
      }

      void open(FrameKind kind, Position position, Header header, std::size_t q) noexcept {
        if (!room()) {
          return;
        }

        // A cursor waiting for the next command of this list gets the block's first.
        const bool pending = cursor_pending_ == level();
        const std::size_t g = push(kind, no_command, TokenKind::argument);

        if (pending) {
          cursor_pending_ = level();
        }

        word_keyword(g, q);
        frames_[g].position = position;
        frames_[g].header = header;
      }

      void close(std::size_t frame, FrameKind kind, std::size_t q) noexcept {
        if (frames_[frame].kind != kind) {
          control(q - p_, TokenKind::error);
          return;
        }

        pop();
        const std::size_t parent = depth_ - 1;

        frames_[parent].command = no_command;
        word_keyword(parent, q);
        frames_[parent].position = Position::after_close;
      }

      // ---- words

      void stepWord(std::size_t frame) noexcept {
        const char c = s_[p_];

        if (!fish_ && frames_[frame].glob > 0) {
          if (c == ')' || c == '|' || c == '(') {
            if (c == ')') {
              --frames_[frame].glob;
            } else if (c == '(' && frames_[frame].glob < 255) {
              ++frames_[frame].glob;
            }

            out(frame, frames_[frame].role, Quote::none, p_, p_ + 1);
            ++p_;
            return;
          }
        }

        if ((bits(p_) & k_end) || (!fish_ && c == '`' && frames_[frame].kind == FrameKind::backtick)) {
          endWord(frame, level());
          return;
        }

        switch (c) {
        case '\'':
          singleQuote(frame);
          return;
        case '"':
          openWord(frame, FrameKind::double_quote, p_ + 1, TokenKind::string, Quote::double_quoted);
          return;
        case '`':
          if (!fish_) {
            openList(frame, FrameKind::backtick, p_ + 1);
            return;
          }

          break;
        case '$':
          if (fish_) {
            fishDollar(frame, frames_[frame].role, Quote::none);
          } else {
            dollar(frame, frames_[frame].role, Quote::none, true);
          }

          return;
        case '\\':
          if (p_ + 1 == n_) {
            trailing_escape_ = true;
          }

          escape(frame, frames_[frame].role, Quote::none);
          return;
        case '(':
          if (fish_) {
            openList(frame, FrameKind::substitution, p_ + 1);
          } else if (next(p_ + 1, ')') && frames_[frame].kind != FrameKind::array) {
            endWord(frame, level());
          } else {
            ++frames_[frame].glob;
            out(frame, frames_[frame].role, Quote::none, p_, p_ + 1);
            ++p_;
          }

          return;
        default:
          break;
        }

        std::size_t q = p_ + 1;

        while (q < n_ && !(bits(q) & k_stop)) {
          ++q;
        }

        out(frame, frames_[frame].role, Quote::none, p_, q);
        p_ = q;
      }

      void endWord(std::size_t frame, std::size_t at_level) noexcept {
        frames_[frame].in_word = false;
        frames_[frame].glob = 0;
        touch(frames_[frame].command, frames_[frame].word_begin, p_);
        if (frames_[frame].redirect) {
          frames_[frame].redirect = false;
          frames_[frame].word_flags = 0;
          if (frames_[frame].heredoc) {
            frames_[frame].heredoc = false;
            finishCapture(frames_[frame].strip_tabs);
          }

          return;
        }

        if (frames_[frame].position == Position::header) {
          if (frames_[frame].header_words < 255) {
            ++frames_[frame].header_words;
          }

          if (frames_[frame].header == Header::function && frames_[frame].header_words == 1) {
            endCommand(frame, at_level, Position::start);
            frames_[frame].pending_body = true;
          }
        }
      }

      void finishCapture(bool strip_tabs) noexcept {
        if (!capturing_) {
          return;
        }

        capturing_ = false;
        if (capture_.overflow()) {
          fail();
          return;
        }

        Heredoc& h = heredocs_[heredoc_count_++];

        h.size = capture_.size();
        h.strip_tabs = strip_tabs;
      }

      // A backslash and the character it escapes, whole even when multibyte.
      void escape(std::size_t frame, TokenKind kind, Quote quote) noexcept {
        std::size_t e = p_ + 1;
        if (e < n_) {
          ++e;
          while (e < n_ && (at(e) & 0xc0) == 0x80 && e < p_ + 5) {
            ++e;
          }
        }

        out(frame, kind, quote, p_, e);
        p_ = e;
      }

      void singleQuote(std::size_t frame) noexcept {
        std::size_t i = p_ + 1;

        for (;;) {
          i = s_.find_first_of(fish_ ? std::string_view{"\\'"} : std::string_view{"'"}, i);
          if (i == std::string_view::npos || (s_[i] == '\\' && i + 1 == n_)) {
            open_quote_ = true;
            out(frame, TokenKind::string, Quote::single_quoted, p_, n_, Token::unterminated);
            p_ = n_;
            return;
          }

          if (s_[i] == '\'') {
            break;
          }

          i += 2;
        }

        out(frame, TokenKind::string, Quote::single_quoted, p_, i + 1);
        p_ = i + 1;
      }

      void ansiString(std::size_t frame) noexcept {
        std::size_t i = p_ + 2;

        for (;;) {
          i = s_.find_first_of("\\'", i);
          if (i == std::string_view::npos || (s_[i] == '\\' && i + 1 == n_)) {
            open_quote_ = true;
            out(frame, TokenKind::string, Quote::ansi_c, p_, n_, Token::unterminated);
            p_ = n_;
            return;
          }

          if (s_[i] == '\'') {
            break;
          }

          i += 2;
        }

        out(frame, TokenKind::string, Quote::ansi_c, p_, i + 1);
        p_ = i + 1;
      }

      // Emits the opener as part of the frame's word, then enters a frame inside the word.
      void openWord(std::size_t frame, FrameKind kind, std::size_t end, TokenKind opener, Quote quote) noexcept {
        if (!room()) {
          return;
        }

        out(frame, opener, quote, p_, end);
        p_ = end;
        const u32 command = frames_[frame].command;
        const TokenKind role = frames_[frame].role;
        const u8 flags = frames_[frame].word_flags;

        frames_[push(kind, command, role)].word_flags = flags;
      }

      // Emits the opener as part of the frame's word, then enters a nested command list.
      void openList(std::size_t frame, FrameKind kind, std::size_t end) noexcept {
        if (!room()) {
          return;
        }

        out(frame, TokenKind::substitution, Quote::none, p_, end);
        p_ = end;
        const u32 command = frames_[frame].command;
        const TokenKind role = frames_[frame].role;
        const u8 flags = frames_[frame].word_flags;
        const std::size_t g = push(kind, no_command, TokenKind::argument);

        frames_[g].owner = command;
        frames_[g].owner_role = role;
        frames_[g].owner_flags = flags;
      }

      // $ in posix: literal is how a lone $ reads in the current context.
      void dollar(std::size_t frame, TokenKind literal, Quote quote, bool unquoted) noexcept {
        const std::size_t b = p_;
        if (b + 1 == n_) {
          out(frame, TokenKind::variable, Quote::none, b, n_);
          p_ = n_;
          return;
        }

        const char c = s_[b + 1];
        if (c == '{') {
          openWord(frame, FrameKind::parameter, b + 2, TokenKind::variable, Quote::none);
        } else if (c == '(') {
          if (next(b + 2, '(')) {
            openWord(frame, FrameKind::arithmetic, b + 3, TokenKind::substitution, Quote::none);
          } else {
            openList(frame, FrameKind::substitution, b + 2);
          }
        } else if (unquoted && c == '\'') {
          ansiString(frame);
        } else if (unquoted && c == '"') {
          out(frame, TokenKind::string, Quote::none, b, b + 1);
          p_ = b + 1;
        } else if (bits(b + 1) & k_name_start) {
          std::size_t q = b + 2;

          while (q < n_ && (bits(q) & k_name)) {
            ++q;
          }

          out(frame, TokenKind::variable, Quote::none, b, q);
          p_ = q;
        } else if ((bits(b + 1) & k_digit) || c == '@' || c == '*' || c == '#' || c == '?' || c == '$' ||
                   c == '!' || c == '-') {
          out(frame, TokenKind::variable, Quote::none, b, b + 2);
          p_ = b + 2;
        } else {
          out(frame, literal, quote, b, b + 1);
          p_ = b + 1;
        }
      }

      void fishDollar(std::size_t frame, TokenKind literal, Quote quote) noexcept {
        const std::size_t b = p_;
        if (b + 1 == n_) {
          out(frame, TokenKind::variable, Quote::none, b, n_);
          p_ = n_;
          return;
        }

        if (s_[b + 1] == '(') {
          openList(frame, FrameKind::substitution, b + 2);
          return;
        }

        std::size_t q = b + 1;

        while (q < n_ && s_[q] == '$') {
          ++q;
        }

        if (q == n_ || !(bits(q) & k_name)) {
          out(frame, q == n_ ? TokenKind::variable : literal, q == n_ ? Quote::none : quote, b, q);
          p_ = q;
          return;
        }

        while (q < n_ && (bits(q) & k_name)) {
          ++q;
        }

        if (next(q, '[')) {
          std::size_t r = q + 1;

          while (r < n_ && s_[r] != ']' && !(bits(r) & k_newline) && s_[r] != '$' && s_[r] != '(' &&
                 s_[r] != '\'' && s_[r] != '"') {
            ++r;
          }

          if (next(r, ']')) {
            q = r + 1;
          }
        }

        out(frame, TokenKind::variable, Quote::none, b, q);
        p_ = q;
      }

      // ---- frames inside a word

      void stepDouble(std::size_t frame) noexcept {
        const char c = s_[p_];
        if (c == '"') {
          out(frame, TokenKind::string, Quote::double_quoted, p_, p_ + 1);
          ++p_;
          pop();
          return;
        }

        if (c == '\\') {
          escape(frame, TokenKind::string, Quote::double_quoted);
          return;
        }

        if (c == '$') {
          if (fish_) {
            fishDollar(frame, TokenKind::string, Quote::double_quoted);
          } else {
            dollar(frame, TokenKind::string, Quote::double_quoted, false);
          }

          return;
        }

        if (!fish_ && c == '`') {
          openList(frame, FrameKind::backtick, p_ + 1);
          return;
        }

        std::size_t q = p_ + 1;

        while (q < n_ && !(bits(q) & k_quote_stop)) {
          ++q;
        }

        out(frame, TokenKind::string, Quote::double_quoted, p_, q);
        p_ = q;
      }

      // Shared by ${...} and $((...)): quotes, escapes and expansions nest.
      bool stepNested(std::size_t frame, TokenKind kind) noexcept {
        switch (s_[p_]) {
        case '\\':
          escape(frame, kind, Quote::none);
          return true;
        case '"':
          openWord(frame, FrameKind::double_quote, p_ + 1, TokenKind::string, Quote::double_quoted);
          return true;
        case '\'':
          singleQuote(frame);
          return true;
        case '$':
          dollar(frame, kind, Quote::none, false);
          return true;
        case '`':
          openList(frame, FrameKind::backtick, p_ + 1);
          return true;
        default:
          return false;
        }
      }

      void stepParameter(std::size_t frame) noexcept {
        if (s_[p_] == '}') {
          out(frame, TokenKind::variable, Quote::none, p_, p_ + 1);
          ++p_;
          pop();
          return;
        }

        if (stepNested(frame, TokenKind::variable)) {
          return;
        }

        std::size_t q = p_ + 1;

        while (q < n_) {
          const char c = s_[q];
          if (c == '}' || c == '\\' || c == '"' || c == '\'' || c == '$' || c == '`') {
            break;
          }

          ++q;
        }

        out(frame, TokenKind::variable, Quote::none, p_, q);
        p_ = q;
      }

      void stepArithmetic(std::size_t frame) noexcept {
        const char c = s_[p_];
        if (c == '(') {
          ++frames_[frame].parens;
          out(frame, TokenKind::substitution, Quote::none, p_, p_ + 1);
          ++p_;
          return;
        }

        if (c == ')') {
          if (frames_[frame].parens > 0) {
            --frames_[frame].parens;
            out(frame, TokenKind::substitution, Quote::none, p_, p_ + 1);
            ++p_;
            return;
          }

          const std::size_t length = next(p_ + 1, ')') ? 2 : 1;
          const TokenKind closer = length == 1 ? TokenKind::error : frames_[frame].arithmetic_command ? TokenKind::keyword
                                                                                                      : TokenKind::substitution;

          out(frame, closer, Quote::none, p_, p_ + length);
          p_ += length;
          pop();
          return;
        }

        if (stepNested(frame, TokenKind::substitution)) {
          return;
        }

        std::size_t q = p_ + 1;

        while (q < n_) {
          const char d = s_[q];
          if (d == '(' || d == ')' || d == '\\' || d == '"' || d == '\'' || d == '$' || d == '`') {
            break;
          }

          ++q;
        }

        out(frame, TokenKind::substitution, Quote::none, p_, q);
        p_ = q;
      }

      // ---- heredocs

      void readHeredocs() noexcept {
        for (std::size_t i = 0; i < heredoc_count_; ++i) {
          const Heredoc& h = heredocs_[i];
          const std::string_view delimiter{h.text.data(), h.size};
          const std::size_t begin = p_;
          bool closed = false;

          while (p_ < n_) {
            std::size_t e = s_.find('\n', p_);
            if (e == std::string_view::npos) {
              e = n_;
            }

            std::size_t b = p_;

            if (h.strip_tabs) {
              while (b < e && s_[b] == '\t') {
                ++b;
              }
            }

            p_ = e < n_ ? e + 1 : n_;
            if (s_.substr(b, e - b) == delimiter) {
              closed = true;
              break;
            }
          }

          if (!closed) {
            heredoc_open_ = true;
          }

          opaque(begin <= cursor_ && (cursor_ < p_ || (cursor_ == p_ && (!closed || s_[p_ - 1] != '\n'))));
          if (p_ > begin) {
            emit(TokenKind::heredoc_body, TokenKind::heredoc_body, no_command, Quote::none, closed ? 0 : Token::unterminated, begin, p_);
          }
        }

        heredoc_count_ = 0;
      }

      // ---- end of line

      void finish() noexcept {
        for (std::size_t i = depth_; i-- > 0;) {
          const std::size_t frame = i;
          if (isList(frames_[frame].kind) && frames_[frame].in_word) {
            endWord(frame, i);
          }
        }

        finishCapture(false);
        if (!cursor_done_) {
          std::size_t i = depth_;

          while (i-- > 1 && !isList(frames_[i].kind)) {
          }

          cursor_done_ = true;
          cursor_completable_ = true;
          cursor_command_ = frames_[i].command;
        }

        if (top().kind == FrameKind::double_quote && count_ > 0 && !overflow_) {
          Token& last = tokens_[count_ - 1];
          if (last.kind == TokenKind::string && last.quote == Quote::double_quoted) {
            last.flags |= Token::unterminated;
          }
        }
      }

      [[nodiscard]] Completeness completeness() const noexcept {
        if (limited_) {
          return Completeness::limit;
        }

        if (trailing_escape_) {
          return Completeness::trailing_escape;
        }

        if (open_quote_) {
          return Completeness::open_quote;
        }

        if (heredoc_open_) {
          return Completeness::pending_heredoc;
        }

        const std::size_t frame = depth_ - 1;

        switch (frames_[frame].kind) {
        case FrameKind::double_quote:
          return Completeness::open_quote;
        case FrameKind::parameter:
        case FrameKind::substitution:
        case FrameKind::backtick:
          return Completeness::open_substitution;
        case FrameKind::arithmetic:
          return frames_[frame].arithmetic_command ? Completeness::open_compound : Completeness::open_substitution;
        case FrameKind::subshell:
        case FrameKind::group:
        case FrameKind::array:
          return Completeness::open_group;
        case FrameKind::if_block:
        case FrameKind::loop:
        case FrameKind::case_block:
        case FrameKind::fish_block:
        case FrameKind::test:
          return Completeness::open_compound;
        case FrameKind::root:
          break;
        }

        if (heredoc_count_ > 0) {
          return Completeness::pending_heredoc;
        }

        if (frames_[frame].pending_body) {
          return Completeness::open_compound;
        }

        if (frames_[frame].pending_operator) {
          return Completeness::trailing_operator;
        }

        return Completeness::complete;
      }

      [[nodiscard]] Lexed result() const noexcept {
        Lexed lexed;

        lexed.tokens = count_;
        lexed.commands = commands_;
        lexed.completeness = completeness();
        lexed.overflow = overflow_;
        lexed.cursor_completable = cursor_completable_;
        lexed.cursor_command = cursor_completable_ ? cursor_command_ : no_command;
        lexed.cursor = cursor_;
        return lexed;
      }

      std::string_view s_;
      std::size_t n_;
      std::size_t p_ = 0;
      const Table& table_;
      Syntax syntax_;
      bool fish_;
      std::span<Token> tokens_;
      std::size_t count_ = 0;
      bool overflow_ = false;
      bool limited_ = false;
      bool trailing_escape_ = false;
      bool open_quote_ = false;
      bool heredoc_open_ = false;
      u32 commands_ = 0;

      std::array<Frame, max_depth> frames_;
      std::size_t depth_ = 0;

      std::size_t cursor_;
      bool cursor_done_ = false;
      bool cursor_completable_ = false;
      u32 cursor_command_ = no_command;
      std::size_t cursor_pending_ = no_cursor; // list level whose next command holds the cursor

      std::array<Heredoc, max_heredocs> heredocs_;
      std::size_t heredoc_count_ = 0;
      bool capturing_ = false;
      u32 capture_command_ = no_command;
      std::size_t capture_gap_ = 0;
      // Writes into the heredoc beside it.
      tbc::view<Unquoter, tbc::lt::self> capture_;
    };

  }

  Lexed lex(std::string_view line, Syntax syntax, std::span<Token> tokens, std::size_t cursor) noexcept {
    return Lexer{line, syntax, tokens, cursor}.run();
  }

  std::size_t segment(std::span<const Token> tokens, std::span<Segment> segments) noexcept {
    std::size_t count = 0;

    for (std::size_t i = 0; i < tokens.size(); ++i) {
      const Token& t = tokens[i];
      if (t.command == no_command) {
        continue;
      }

      const std::size_t id = t.command;
      if (id >= count) {
        if (id < segments.size()) {
          for (std::size_t j = count; j <= id; ++j) {
            segments[j] = Segment{{t.begin, t.begin}, static_cast<u32>(i), static_cast<u32>(i)};
          }
        }

        count = id + 1;
      }

      if (id < segments.size()) {
        Segment& s = segments[id];

        s.source.end = std::max(s.source.end, t.end);
        s.end_token = static_cast<u32>(i + 1);
      }
    }

    return count;
  }

  tbc::view<CommandAt, tbc::lt::a> commandAt(tbc::view<std::string_view, tbc::lt::a> line, Syntax syntax, std::span<const Token> tokens, const Lexed& lexed, std::span<Word> words, tbc::view<std::span<char>, tbc::lt::a> text) noexcept {
    CommandAt at;

    if (!lexed.cursor_completable || lexed.cursor > line.size()) {
      return at;
    }

    if (lexed.overflow) {
      at.overflow = true;
      return at;
    }

    const std::size_t cursor = lexed.cursor;
    const u32 command = lexed.cursor_command;

    tokens = tokens.first(std::min(tokens.size(), lexed.tokens));
    at.replace = Range{static_cast<u32>(cursor), static_cast<u32>(cursor)};
    if (command == no_command) {
      at.current = 0;
      return at;
    }

    Unquoter unquoter{text};
    bool open = false;
    Word word;
    std::size_t text_begin = 0;
    std::size_t gap = 0;
    std::size_t first = 0;
    std::size_t current_first = 0;
    std::size_t current_end = 0;
    const auto closeWord = [&](std::size_t end_token) {
      if (!open) {
        return true;
      }

      open = false;
      if (at.words == words.size() || unquoter.overflow()) {
        return false;
      }

      word.text = unquoter.text(text_begin);
      if (!at.in_word && word.source.begin <= cursor && cursor <= word.source.end) {
        at.in_word = true;
        at.current = at.words;
        at.replace = word.source;
        current_first = first;
        current_end = end_token;
      }

      if (at.command_word == no_word && word.role == TokenKind::command) {
        at.command_word = at.words;
      }

      words[at.words++] = word;
      return true;
    };

    // Tokens from another line or out of order are rejected, never read past.
    std::size_t last_end = 0;

    for (std::size_t i = 0; i < tokens.size(); ++i) {
      const Token& t = tokens[i];
      if (t.begin < last_end || t.begin > t.end || t.end > line.size()) {
        at = CommandAt{};
        at.overflow = true;
        return at;
      }

      last_end = t.end;
      if (t.command != command) {
        continue;
      }

      if (!isPiece(t.kind)) {
        if (!closeWord(i)) {
          at.overflow = true;
          return at;
        }

        continue;
      }

      if (!open || (t.flags & Token::word_start)) {
        if (!closeWord(i)) {
          at.overflow = true;
          return at;
        }

        open = true;
        word = Word{{t.begin, t.end}, {}, t.role, static_cast<u8>(t.flags & Token::redirect_target)};
        text_begin = unquoter.size();
        gap = t.begin;
        first = i;
      }

      unquoter.verbatim(line.substr(gap, t.begin - gap));
      unquoter.piece(syntax.dialect, t.kind, t.quote, line.substr(t.begin, t.end - t.begin));
      gap = t.end;
      word.source.end = t.end;
    }

    if (!closeWord(tokens.size())) {
      at.overflow = true;
      return at;
    }

    if (!at.in_word) {
      std::size_t before = 0;

      while (before < at.words && words[before].source.end < cursor) {
        ++before;
      }

      at.current = before;
      return at;
    }

    // The prefix: the current word's pieces cut at the cursor.
    Unquoter prefix{text.subspan(unquoter.size())};

    gap = at.replace.begin;
    for (std::size_t i = current_first; i < current_end && gap < cursor; ++i) {
      const Token& t = tokens[i];
      if (t.command != command || !isPiece(t.kind)) {
        continue;
      }

      const std::size_t begin = std::min<std::size_t>(t.begin, cursor);
      const std::size_t end = std::min<std::size_t>(t.end, cursor);

      prefix.verbatim(line.substr(gap, begin - gap));
      prefix.piece(syntax.dialect, t.kind, t.quote, line.substr(begin, end - begin));
      gap = end;
    }

    if (prefix.overflow()) {
      at.overflow = true;
      return at;
    }

    at.prefix = prefix.text(0);
    return at;
  }

}
