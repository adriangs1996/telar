module telar.shell.syntax;

import std;

namespace telar::shell {
  namespace {

    using u8 = std::uint8_t;
    using u32 = std::uint32_t;

    // Byte classes. Bytes >= 0x80 have none, so they are word characters and a
    // token boundary never falls inside a UTF-8 sequence.
    constexpr unsigned k_blank = 1U << 0U;
    constexpr unsigned k_newline = 1U << 1U;
    constexpr unsigned k_end = 1U << 2U;  // ends a word
    constexpr unsigned k_stop = 1U << 3U; // ends a literal run
    constexpr unsigned k_name = 1U << 4U;
    constexpr unsigned k_name_start = 1U << 5U;
    constexpr unsigned k_digit = 1U << 6U;
    constexpr unsigned k_quote_stop = 1U << 7U; // ends a run inside double quotes

    constexpr int byte_values = 256;

    using Table = std::array<u8, byte_values>;

    consteval Table makeTable(Dialect dialect) {
      Table table{};
      const bool posix = dialect == Dialect::posix;

      for (int byte = 0; byte < byte_values; ++byte) {
        u8 bits = 0;

        if (byte == ' ' || byte == '\t') {
          bits |= k_blank | k_end | k_stop;
        }

        if (byte == '\n') {
          bits |= k_newline | k_end | k_stop;
        }

        if (byte == ';' || byte == '&' || byte == '|' || byte == '<' || byte == '>' || byte == ')') {
          bits |= k_end | k_stop;
        }

        if (byte == '(' || byte == '\'' || byte == '"' || byte == '$' || byte == '\\' || (posix && byte == '`')) {
          bits |= k_stop;
        }

        if (byte == '"' || byte == '$' || byte == '\\' || (posix && byte == '`')) {
          bits |= k_quote_stop;
        }

        if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || byte == '_') {
          bits |= k_name | k_name_start;
        }

        if (byte >= '0' && byte <= '9') {
          bits |= k_name | k_digit;
        }

        table[static_cast<std::size_t>(byte)] = bits;
      }

      return table;
    }

    constexpr Table posix_table = makeTable(Dialect::posix);
    constexpr Table fish_table = makeTable(Dialect::fish);

    // UTF-8: the first code point of each sequence length, the lead byte that announces it, and the
    // six bits a continuation byte carries after its tag.
    constexpr u32 first_two_byte = 0x80;
    constexpr u32 first_three_byte = 0x800;
    constexpr u32 first_four_byte = 0x10000;
    constexpr u32 max_code_point = 0x10ffff;
    constexpr u32 first_surrogate = 0xd800;
    constexpr u32 last_surrogate = 0xdfff;
    constexpr u32 two_byte_lead = 0xc0;
    constexpr u32 three_byte_lead = 0xe0;
    constexpr u32 four_byte_lead = 0xf0;
    constexpr u32 continuation_mask = 0xc0;
    constexpr u32 continuation_tag = 0x80;
    constexpr u32 continuation_payload = 0x3f;
    constexpr unsigned continuation_bits = 6;

    // Escapes: \cX keeps the low five bits of X, \x reads up to two hexadecimal digits, \u four and
    // \U eight, and an octal escape writes one byte.
    constexpr u32 control_bits = 0x1f;
    constexpr std::size_t hex_byte_digits = 2;
    constexpr std::size_t short_unicode_digits = 4;
    constexpr std::size_t long_unicode_digits = 8;
    constexpr u32 hex_base = 16;
    constexpr u32 octal_base = 8;
    constexpr u32 byte_mask = 0xff;

    // The value of the hexadecimal digit a, the first after the decimal ones.
    constexpr u32 first_hex_letter = 10;

    constexpr bool isPiece(TokenKind kind) noexcept {
      return kind <= TokenKind::substitution;
    }

    constexpr bool isContinuation(unsigned char byte) noexcept {
      return (byte & continuation_mask) == continuation_tag;
    }

    constexpr char continuationByte(u32 code, unsigned shift) noexcept {
      return static_cast<char>(continuation_tag | ((code >> shift) & continuation_payload));
    }

    // [from, until) of text, which the caller keeps in bounds; unlike substr it never throws.
    constexpr std::string_view slice(std::string_view text, std::size_t from, std::size_t until) noexcept {
      const auto bytes = std::span{text}.subspan(from, until - from);

      return {bytes.begin(), bytes.end()};
    }

    constexpr bool hexValue(char digit, u32& value) noexcept {
      if (digit >= '0' && digit <= '9') {
        value = static_cast<u32>(digit - '0');
      } else if (digit >= 'a' && digit <= 'f') {
        value = static_cast<u32>(digit - 'a') + first_hex_letter;
      } else if (digit >= 'A' && digit <= 'F') {
        value = static_cast<u32>(digit - 'A') + first_hex_letter;
      } else {
        return false;
      }

      return true;
    }

    // The hexadecimal digits \x, \u and \U read at most.
    constexpr std::size_t codeDigits(char letter) noexcept {
      switch (letter) {
      case 'u':
        return short_unicode_digits;
      case 'U':
        return long_unicode_digits;
      default:
        return hex_byte_digits;
      }
    }

    // The byte a one-letter escape stands for, or none.
    constexpr char simpleEscape(char letter) noexcept {
      switch (letter) {
      case 'a':
        return '\a';
      case 'b':
        return '\b';
      case 'e':
      case 'E':
        return '\x1b';
      case 'f':
        return '\f';
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'v':
        return '\v';
      default:
        return '\0';
      }
    }

    // Writes unquoted bytes into a caller buffer. Unquoting never produces more
    // bytes than it reads, so an output as large as the input never overflows.
    // Writes unquoted text into a buffer it borrows, region `a`, only ever appending, so the text it
    // returns views the buffer and stays valid as more is written.
    class Unquoter {
    public:
      Unquoter() noexcept = default;

      explicit Unquoter(tbc::val_a<std::span<char>> out) noexcept
          : out_(out) {}

      [[nodiscard]] std::size_t size() const noexcept {
        return size_;
      }

      [[nodiscard]] bool overflow() const noexcept {
        return overflow_;
      }

      [[nodiscard]] tbc::val_a<std::string_view> text(std::size_t from) const noexcept {
        const auto written = out_.subspan(from, size_ - from);

        return {written.data(), written.size()};
      }

      void verbatim(std::string_view bytes) noexcept {
        for (const char byte : bytes) {
          put(byte);
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
        case TokenKind::command:
        case TokenKind::argument:
        case TokenKind::option:
        case TokenKind::keyword:
        case TokenKind::assignment:
        case TokenKind::control:
        case TokenKind::redirection:
        case TokenKind::comment:
        case TokenKind::heredoc_body:
        case TokenKind::error:
          literal(dialect, bytes);
          return;
        }
      }

    private:
      void put(char byte) noexcept {
        if (size_ < out_.size()) {
          out_[size_++] = byte;
        } else {
          overflow_ = true;
        }
      }

      void singleQuoted(Dialect dialect, std::string_view bytes) noexcept {
        for (std::size_t i = 0; i < bytes.size(); ++i) {
          const char byte = bytes[i];
          if (dialect == Dialect::fish && byte == '\\' && i + 1 < bytes.size() && (bytes[i + 1] == '\\' || bytes[i + 1] == '\'')) {
            put(bytes[++i]);
          } else if (byte != '\'') {
            put(byte);
          }
        }
      }

      void doubleQuoted(Dialect dialect, std::string_view bytes) noexcept {
        for (std::size_t i = 0; i < bytes.size(); ++i) {
          const char byte = bytes[i];
          if (byte == '"') {
            continue;
          }

          if (byte != '\\') {
            put(byte);
            continue;
          }

          if (i + 1 == bytes.size()) {
            return;
          }

          const char next = bytes[++i];
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

      void literal(Dialect dialect, std::string_view bytes) noexcept {
        for (std::size_t i = 0; i < bytes.size(); ++i) {
          const char byte = bytes[i];
          if (byte != '\\') {
            put(byte);
            continue;
          }

          if (i + 1 == bytes.size()) {
            return;
          }

          if (bytes[i + 1] == '\n') {
            ++i;
          } else if (dialect == Dialect::fish) {
            i = escape(bytes, i, false);
          } else {
            put(bytes[++i]);
          }
        }
      }

      void ansiC(std::string_view bytes) noexcept {
        bool inside = false;

        for (std::size_t i = 0; i < bytes.size(); ++i) {
          const char byte = bytes[i];

          if (!inside) {
            if (byte == '$' && i + 1 < bytes.size() && bytes[i + 1] == '\'') {
              inside = true;
              ++i;
            } else {
              put(byte);
            }
          } else if (byte == '\'') {
            inside = false;
          } else if (byte == '\\' && i + 1 < bytes.size()) {
            i = escape(bytes, i, true);
          } else if (byte != '\\') {
            put(byte);
          }
        }
      }

      // Decodes the escape at bytes[slash] == '\\' (with a byte after it) and returns
      // the index of its last byte. ANSI-C keeps unknown escapes; fish drops the slash.
      std::size_t escape(std::string_view bytes, std::size_t slash, bool ansi) noexcept {
        const char letter = bytes[slash + 1];
        if (const char simple = simpleEscape(letter); simple != '\0') {
          put(simple);
          return slash + 1;
        }

        switch (letter) {
        case 'c':
          if (slash + 2 < bytes.size()) {
            put(static_cast<char>(static_cast<unsigned char>(bytes[slash + 2]) & control_bits));
            return slash + 2;
          }

          break;
        case 'x':
        case 'X':
        case 'u':
        case 'U':
          if (letter != 'X' || !ansi) {
            if (const std::size_t last = codeEscape(letter, bytes, slash); last != slash) {
              return last;
            }
          }

          break;
        default:
          if (letter >= '0' && letter <= '7') {
            return octalEscape(bytes, slash);
          }

          break;
        }

        if (ansi && letter != '\\' && letter != '\'' && letter != '"' && letter != '?') {
          put('\\');
        }

        put(letter);
        return slash + 1;
      }

      // \x \X \u \U and their digits; returns the index of the escape's last byte, or slash when no
      // digit follows.
      std::size_t codeEscape(char letter, std::string_view bytes, std::size_t slash) noexcept {
        const std::size_t digits = codeDigits(letter);
        u32 code = 0;
        std::size_t end = slash + 2;

        for (u32 digit = 0; end < bytes.size() && end < slash + 2 + digits && hexValue(bytes[end], digit); ++end) {
          code = (code * hex_base) + digit;
        }

        if (end == slash + 2) {
          return slash;
        }

        if (letter == 'x' || letter == 'X') {
          put(static_cast<char>(code));
        } else if (!utf8(code)) {
          verbatim(slice(bytes, slash, end));
        }

        return end - 1;
      }

      // Up to three octal digits after the slash; returns the index of the last.
      std::size_t octalEscape(std::string_view bytes, std::size_t slash) noexcept {
        u32 code = 0;
        std::size_t end = slash + 1;

        for (; end < bytes.size() && end < slash + 4 && bytes[end] >= '0' && bytes[end] <= '7'; ++end) {
          code = (code * octal_base) + static_cast<u32>(bytes[end] - '0');
        }

        put(static_cast<char>(code & byte_mask));
        return end - 1;
      }

      bool utf8(u32 code) noexcept {
        if (code < first_two_byte) {
          put(static_cast<char>(code));
        } else if (code < first_three_byte) {
          put(static_cast<char>(two_byte_lead | (code >> continuation_bits)));
          put(continuationByte(code, 0));
        } else if (code < first_four_byte) {
          if (code >= first_surrogate && code <= last_surrogate) {
            return false;
          }

          put(static_cast<char>(three_byte_lead | (code >> (2 * continuation_bits))));
          put(continuationByte(code, continuation_bits));
          put(continuationByte(code, 0));
        } else if (code <= max_code_point) {
          put(static_cast<char>(four_byte_lead | (code >> (3 * continuation_bits))));
          put(continuationByte(code, 2 * continuation_bits));
          put(continuationByte(code, continuation_bits));
          put(continuationByte(code, 0));
        } else {
          return false;
        }

        return true;
      }

      tbc::val_a<std::span<char>> out_;
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
      if_word,
      then_word,
      elif_word,
      else_word,
      fi,
      while_word,
      until,
      for_word,
      select,
      do_word,
      done,
      case_word,
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
      switch_word,
      and_word,
      or_word,
      not_word,
    };

    // Keywords fit in eight bytes, so a word compares as one integer.
    constexpr std::size_t max_keyword_bytes = sizeof(std::uint64_t);
    constexpr std::size_t byte_bits = 8;

    constexpr std::uint64_t pack(std::string_view word) noexcept {
      std::uint64_t key = 0;

      for (std::size_t i = 0; i < word.size(); ++i) {
        key |= static_cast<std::uint64_t>(static_cast<unsigned char>(word[i])) << (byte_bits * i);
      }

      return key;
    }

    struct KeywordName {
      std::uint64_t key;
      Keyword keyword;

      consteval KeywordName(std::string_view name, Keyword value)
          : key(pack(name)),
            keyword(value) {}
    };

    constexpr auto posix_keywords = std::to_array<KeywordName>({
        {"if", Keyword::if_word},
        {"then", Keyword::then_word},
        {"elif", Keyword::elif_word},
        {"else", Keyword::else_word},
        {"fi", Keyword::fi},
        {"while", Keyword::while_word},
        {"until", Keyword::until},
        {"for", Keyword::for_word},
        {"select", Keyword::select},
        {"do", Keyword::do_word},
        {"done", Keyword::done},
        {"case", Keyword::case_word},
        {"esac", Keyword::esac},
        {"in", Keyword::in},
        {"function", Keyword::function},
        {"time", Keyword::time},
        {"coproc", Keyword::coproc},
        {"!", Keyword::bang},
        {"{", Keyword::brace_open},
        {"}", Keyword::brace_close},
        {"[[", Keyword::test_open},
    });

    constexpr auto fish_keywords = std::to_array<KeywordName>({
        {"begin", Keyword::begin},
        {"end", Keyword::end},
        {"if", Keyword::if_word},
        {"else", Keyword::else_word},
        {"while", Keyword::while_word},
        {"for", Keyword::for_word},
        {"in", Keyword::in},
        {"function", Keyword::function},
        {"switch", Keyword::switch_word},
        {"case", Keyword::case_word},
        {"and", Keyword::and_word},
        {"or", Keyword::or_word},
        {"not", Keyword::not_word},
        {"!", Keyword::not_word},
        {"time", Keyword::time},
    });

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

    struct Heredoc { // NOLINT(cppcoreguidelines-pro-type-member-init): a capture writes the delimiter before it is read, so a lexer does not clear its heredocs per call
      std::array<char, max_delimiter> text;
      std::size_t size = 0;
      bool strip_tabs = false;
    };

    // A token to write: its kinds, the command it belongs to and the bytes it covers.
    struct Emission {
      TokenKind kind = TokenKind::error;
      TokenKind role = TokenKind::error;
      u32 command = no_command;
      Quote quote = Quote::none;
      u8 flags = 0;
      std::size_t begin = 0;
      std::size_t end = 0;
    };

    // An operator that ends a command: its length, whether the line must go on after it, and where
    // the next command starts.
    struct Operator {
      std::size_t length = 1;
      bool pending = false;
      Position position = Position::start;
    };

    // The operator of a redirection: where it ends, and whether a target word or a heredoc
    // delimiter follows it.
    struct Redirect {
      std::size_t end = 0;
      bool target = true;
      bool heredoc = false;
      bool strip_tabs = false;
    };

    // Where a heredoc body ends: past the line that is its delimiter, or at the end of the line.
    struct HeredocBody {
      std::size_t end = 0;
      bool closed = false;
    };

    class Lexer { // NOLINT(cppcoreguidelines-special-member-functions,hicpp-special-member-functions): the implicit destructor is the right one, and declaring it here is a warning of its own
    public:
      Lexer(std::string_view line, Syntax syntax, std::span<Token> tokens, std::size_t cursor) noexcept // NOLINT(cppcoreguidelines-pro-type-member-init): push() writes each frame before it is read, so a lexer does not clear its frame stack per call
          : s_(line),
            n_(line.size()),
            table_(syntax.dialect == Dialect::fish ? fish_table : posix_table),
            syntax_(syntax),
            fish_(syntax.dialect == Dialect::fish),
            tokens_(tokens),
            depth_(1),
            cursor_(cursor) {
        frames_[0] = blank_frame;
        if (cursor_ > n_) {
          cursor_done_ = true;
        } else {
          while (cursor_ > 0 && cursor_ < n_ && isContinuation(at(cursor_)) && cursor - cursor_ < 3) {
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
          case FrameKind::root:
          case FrameKind::subshell:
          case FrameKind::group:
          case FrameKind::substitution:
          case FrameKind::backtick:
          case FrameKind::if_block:
          case FrameKind::loop:
          case FrameKind::case_block:
          case FrameKind::fish_block:
          case FrameKind::test:
          case FrameKind::array:
            stepList(frame);
            break;
          }

          stalled = p_ == before ? stalled + 1 : 0;
          if (stalled > 2) {
#if TELAR_DEBUG
            std::abort();
#else
            fail();
#endif
          }
        }

        finish();
        return result();
      }

    private:
      [[nodiscard]] unsigned char at(std::size_t index) const noexcept {
        return static_cast<unsigned char>(s_[index]);
      }

      [[nodiscard]] u8 bits(std::size_t index) const noexcept {
        return table_[at(index)];
      }

      [[nodiscard]] bool next(std::size_t index, char byte) const noexcept {
        return index < n_ && s_[index] == byte;
      }

      [[nodiscard]] std::size_t level() const noexcept {
        return depth_ - 1;
      }

      Frame& top() noexcept {
        return frames_[depth_ - 1];
      }

      // ---- output

      void emit(const Emission& token) noexcept {
        if (capturing_ && token.command == capture_command_ && isPiece(token.kind)) {
          capture_.verbatim(slice(s_, capture_gap_, token.begin));
          capture_.piece(syntax_.dialect, token.kind, token.quote, slice(s_, token.begin, token.end));
          capture_gap_ = token.end;
        }

        if (overflow_) {
          return;
        }

        if (count_ > 0 && isPiece(token.kind) && (token.flags & Token::word_start) == 0) {
          Token& last = tokens_[count_ - 1];
          if (last.end == token.begin && last.kind == token.kind && last.role == token.role && last.command == token.command &&
              last.quote == token.quote && (last.flags | Token::word_start) == (token.flags | Token::word_start)) {
            last.end = static_cast<u32>(token.end);
            return;
          }
        }

        if (count_ == tokens_.size()) {
          overflow_ = true;
          return;
        }

        tokens_[count_++] = Token{.begin = static_cast<u32>(token.begin), .end = static_cast<u32>(token.end), .command = token.command, .kind = token.kind, .role = token.role, .quote = token.quote, .flags = token.flags};
      }

      void control(std::size_t length, TokenKind kind = TokenKind::control) noexcept {
        emit({.kind = kind, .role = kind, .begin = p_, .end = p_ + length});
        p_ += length;
      }

      // A part of the word the frame is building.
      void out(std::size_t frame, TokenKind kind, Quote quote, std::size_t begin, std::size_t end) noexcept {
        out(frame, {.kind = kind, .quote = quote, .begin = begin, .end = end});
      }

      // A part of the word the frame is building, with the flags it adds to the word's.
      void out(std::size_t frame, Emission token) noexcept {
        token.role = frames_[frame].role;
        token.command = frames_[frame].command;
        token.flags = static_cast<u8>(frames_[frame].word_flags | token.flags);
        if (frames_[frame].fresh) {
          token.flags |= Token::word_start;
          frames_[frame].fresh = false;
        }

        emit(token);
      }

      // The rest of the line becomes one error token.
      void fail() noexcept {
        if (p_ < n_) {
          emit({.kind = TokenKind::error, .role = TokenKind::error, .begin = p_, .end = n_});
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

      // Ends the command of the list at index frame, which is also the list's level.
      void endCommand(std::size_t frame, Position position) noexcept {
        frames_[frame].command = no_command;
        frames_[frame].position = position;
        frames_[frame].header = Header::none;
        frames_[frame].header_words = 0;
        frames_[frame].redirect = false;
        frames_[frame].heredoc = false;
        frames_[frame].after_else = false;
        if (cursor_pending_ == frame) {
          cursor_pending_ = no_cursor;
        }
      }

      // At a boundary of the top list: the cursor before this element is
      // between words of the current command.
      void gap(bool inclusive) noexcept {
        if (cursor_done_ || (cursor_ >= p_ && (!inclusive || cursor_ != p_))) {
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

        const char byte = s_[p_];
        if (byte == ' ' || byte == '\t') {
          ++p_;
          while (p_ < n_ && ((bits(p_) & k_blank) != 0)) {
            ++p_;
          }

          return;
        }

        if (byte == '\\' && next(p_ + 1, '\n')) {
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

        if (listOperator(frame)) {
          return;
        }

        gap(false);
        beginWord(frame);
      }

      // An operator, comment, redirection or group at p_ of a list; false when a word starts there.
      bool listOperator(std::size_t frame) noexcept {
        switch (s_[p_]) {
        case '\n':
          gap(true);
          newline(frame);
          return true;
        case ';':
          gap(true);
          semicolon(frame);
          return true;
        case '&':
          gap(true);
          ampersand(frame);
          return true;
        case '|':
          gap(true);
          pipe(frame);
          return true;
        case '<':
        case '>':
          if (!fish_ && next(p_ + 1, '(')) {
            return false;
          }

          gap(true);
          redirection(frame, p_);
          return true;
        case '(':
          return !fish_ && openParen(frame);
        case ')':
          gap(true);
          closeParen(frame);
          return true;
        case '`':
          if (!fish_ && frames_[frame].kind == FrameKind::backtick) {
            gap(true);
            closeList(frame);
            return true;
          }

          return false;
        case '#':
          if (syntax_.comments) {
            gap(true);
            comment();
            return true;
          }

          return false;
        default:
          return numberedRedirection(frame);
        }
      }

      // A posix ( in a list: a function's (), a case pattern's (, a subshell or an arithmetic
      // command; false where it is part of a word.
      bool openParen(std::size_t frame) noexcept {
        if (next(p_ + 1, ')')) {
          gap(true);
          control(2);
          endCommand(frame, Position::start);
          frames_[frame].pending_body = true;
          return true;
        }

        if (frames_[frame].position == Position::pattern) {
          gap(true);
          control(1);
          return true;
        }

        if (frames_[frame].position == Position::start || frames_[frame].position == Position::after_close ||
            (frames_[frame].position == Position::header && frames_[frame].header == Header::loop && frames_[frame].header_words == 0)) {
          gap(true);
          if (next(p_ + 1, '(')) {
            arithmeticCommand(frame);
          } else {
            subshell(frame);
          }

          return true;
        }

        return false;
      }

      // A redirection after a file descriptor, as 2> or 10<; false when the digits start a word.
      bool numberedRedirection(std::size_t frame) noexcept {
        if ((bits(p_) & k_digit) == 0) {
          return false;
        }

        std::size_t end = p_ + 1;

        while (end < n_ && ((bits(end) & k_digit) != 0)) {
          ++end;
        }

        if (end < n_ && (s_[end] == '<' || s_[end] == '>') && (fish_ || !next(end + 1, '('))) {
          gap(true);
          redirection(frame, end);
          return true;
        }

        return false;
      }

      void operatorEnd(std::size_t frame, Operator ending) noexcept {
        control(ending.length);
        endCommand(frame, ending.position);
        frames_[frame].pending_operator = ending.pending;
        frames_[frame].pending_body = false;
      }

      void newline(std::size_t frame) noexcept {
        control(1);
        if (frames_[frame].position != Position::pattern && (frames_[frame].command != no_command || frames_[frame].position != Position::start)) {
          endCommand(frame, Position::start);
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
              operatorEnd(frame, {.length = length, .position = Position::pattern});
            } else {
              control(length, TokenKind::error);
              endCommand(frame, Position::start);
            }

            return;
          }
        }

        operatorEnd(frame, {});
      }

      void ampersand(std::size_t frame) noexcept {
        if (next(p_ + 1, '&')) {
          operatorEnd(frame, {.length = 2, .pending = true});
        } else if (next(p_ + 1, '>')) {
          redirection(frame, p_);
        } else if (next(p_ + 1, '|')) {
          operatorEnd(frame, {.length = 2, .pending = fish_}); // fish pipes both streams; zsh disowns
        } else if (!fish_ && next(p_ + 1, '!')) {
          operatorEnd(frame, {.length = 2});
        } else {
          operatorEnd(frame, {});
        }
      }

      void pipe(std::size_t frame) noexcept {
        const std::size_t length = next(p_ + 1, '|') || (!fish_ && next(p_ + 1, '&')) ? 2 : 1;

        if (frames_[frame].position == Position::pattern) {
          control(length);
          return;
        }

        operatorEnd(frame, {.length = length, .pending = true});
      }

      // p_ starts the redirection (at its file descriptor, if any); sign is its first < > or &.
      void redirection(std::size_t frame, std::size_t sign) noexcept {
        if (fish_ && s_[sign] == '>' && next(sign + 1, '|')) { // 2>| pipes a stream
          operatorEnd(frame, {.length = sign + 2 - p_, .pending = true});
          return;
        }

        const Redirect redirect = redirectAt(sign);
        if (redirect.heredoc && heredoc_count_ == max_heredocs) {
          fail();
          return;
        }

        ensureCommand(level());
        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        emit({.kind = TokenKind::redirection, .role = TokenKind::redirection, .command = frames_[frame].command, .begin = p_, .end = redirect.end});
        p_ = redirect.end;
        frames_[frame].redirect = redirect.target;
        frames_[frame].heredoc = redirect.heredoc;
        frames_[frame].strip_tabs = redirect.strip_tabs;
      }

      [[nodiscard]] Redirect redirectAt(std::size_t sign) const noexcept {
        if (s_[sign] == '&') { // &> &>>
          return {.end = next(sign + 2, '>') ? sign + 3 : sign + 2};
        }

        return s_[sign] == '<' ? inputRedirect(sign) : outputRedirect(sign);
      }

      // < << <<< <<- <& <>
      [[nodiscard]] Redirect inputRedirect(std::size_t sign) const noexcept {
        Redirect redirect{.end = sign + 1};

        if (!fish_ && next(sign + 1, '<')) {
          if (next(sign + 2, '<')) {
            redirect.end = sign + 3;
            return redirect;
          }

          redirect.heredoc = true;
          redirect.end = sign + 2;
          if (next(redirect.end, '-')) {
            redirect.strip_tabs = true;
            ++redirect.end;
          }
        } else if (next(sign + 1, '&')) {
          redirect.end = sign + 2;
          duplicate(redirect);
        } else if (!fish_ && next(sign + 1, '>')) {
          redirect.end = sign + 2;
        }

        return redirect;
      }

      // > >> >& >| and zsh's >! or fish's >?
      [[nodiscard]] Redirect outputRedirect(std::size_t sign) const noexcept {
        Redirect redirect{.end = sign + 1};

        if (next(sign + 1, '&')) {
          redirect.end = sign + 2;
          duplicate(redirect);
        } else if (next(sign + 1, '>') || next(sign + 1, '|') || (fish_ && next(sign + 1, '?')) || (!fish_ && next(sign + 1, '!'))) {
          redirect.end = sign + 2;
        }

        return redirect;
      }

      // &- and &n name a descriptor, not a target word.
      void duplicate(Redirect& redirect) const noexcept {
        if (next(redirect.end, '-')) {
          ++redirect.end;
          redirect.target = false;
        } else if (redirect.end < n_ && ((bits(redirect.end) & k_digit) != 0)) {
          while (redirect.end < n_ && ((bits(redirect.end) & k_digit) != 0)) {
            ++redirect.end;
          }

          redirect.target = false;
        }
      }

      void comment() noexcept {
        std::size_t end = s_.find('\n', p_);
        if (end == std::string_view::npos) {
          end = n_;
        }

        opaque(p_ < cursor_ && cursor_ <= end);
        control(end - p_, TokenKind::comment);
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
        emit({.kind = TokenKind::keyword, .role = TokenKind::keyword, .command = frames_[frame].command, .flags = Token::word_start, .begin = p_, .end = p_ + 2});
        p_ += 2;
        const std::size_t g = push(FrameKind::arithmetic, frames_[frame].command, TokenKind::keyword);

        frames_[g].arithmetic_command = true;
      }

      // A substitution or backtick frame ends at the boundary of its list.
      void closeList(std::size_t frame) noexcept {
        emit({.kind = TokenKind::substitution, .role = frames_[frame].owner_role, .command = frames_[frame].owner, .flags = frames_[frame].owner_flags, .begin = p_, .end = p_ + 1});
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
          endCommand(frame, Position::start);
        } else {
          control(1, TokenKind::error);
        }
      }

      void testElement(std::size_t frame) noexcept {
        const char byte = s_[p_];
        if (byte == '\n') {
          ++p_;
          return;
        }

        if (byte == '&' || byte == '|') {
          gap(true);
          control(next(p_ + 1, byte) ? 2 : 1, next(p_ + 1, byte) ? TokenKind::control : TokenKind::error);
          return;
        }

        if (byte == '<' || byte == '>' || byte == '(' || byte == ')') {
          gap(true);
          control(1);
          return;
        }

        if (byte == ';') {
          gap(true);
          control(1, TokenKind::error);
          return;
        }

        gap(false);
        if (byte == ']' && next(p_ + 1, ']') && (p_ + 2 == n_ || ((bits(p_ + 2) & k_end) != 0))) {
          emit({.kind = TokenKind::keyword, .role = TokenKind::keyword, .command = frames_[frame].command, .flags = Token::word_start, .begin = p_, .end = p_ + 2});
          touch(frames_[frame].command, p_, p_ + 2);
          p_ += 2;
          pop();
          top().position = Position::after_close;
          return;
        }

        startWord(frame, optionOrArgument());
      }

      void arrayElement(std::size_t frame) noexcept {
        const char byte = s_[p_];
        if (byte == '\n') {
          ++p_;
          return;
        }

        if (byte == ')') {
          gap(true);
          out(frame, TokenKind::assignment, Quote::none, p_, p_ + 1);
          ++p_;
          pop();
          return;
        }

        if (byte == '#' && syntax_.comments) {
          gap(true);
          comment();
          return;
        }

        if ((bits(p_) & k_end) != 0) {
          gap(true);
          control(1, TokenKind::error);
          return;
        }

        gap(false);
        frames_[frame].in_word = true;
        frames_[frame].word_begin = static_cast<u32>(p_);
      }

      [[nodiscard]] TokenKind optionOrArgument() const noexcept {
        return s_[p_] == '-' && (p_ + 1 >= n_ || (bits(p_ + 1) & k_end) == 0) ? TokenKind::option : TokenKind::argument;
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

      // Whether the literal run [p_, end) starts an assignment: name=, and in posix name+= or name[...]=.
      [[nodiscard]] bool isAssignment(std::size_t end) const noexcept {
        if ((bits(p_) & k_name_start) == 0) {
          return false;
        }

        std::size_t name_end = p_ + 1;

        while (name_end < end && ((bits(name_end) & k_name) != 0)) {
          ++name_end;
        }

        if (name_end < end && s_[name_end] == '=') {
          return true;
        }

        if (fish_ || name_end >= end) {
          return false;
        }

        if (s_[name_end] == '+') {
          return name_end + 1 < end && s_[name_end + 1] == '=';
        }

        if (s_[name_end] == '[') {
          const std::size_t close = slice(s_, name_end, end).find(']');

          return close != std::string_view::npos && name_end + close + 1 < end && s_[name_end + close + 1] == '=';
        }

        return false;
      }

      void beginWord(std::size_t frame) noexcept {
        std::size_t end = p_;

        while (end < n_ && ((bits(end) & k_stop) == 0)) {
          ++end;
        }

        const bool whole = end == n_ || ((bits(end) & k_end) != 0);
        if (!frames_[frame].redirect && whole && end - p_ <= max_keyword_bytes && end > p_ && keyword(frame, end)) {
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
            if (isAssignment(end)) {
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

        if (end > p_) {
          out(frame, frames_[frame].role, Quote::none, p_, end);
          p_ = end;
          if (!fish_ && frames_[frame].role == TokenKind::assignment && s_[end - 1] == '=' && next(end, '(') && room()) {
            out(frame, TokenKind::assignment, Quote::none, end, end + 1);
            ++p_;
            const std::size_t g = push(FrameKind::array, frames_[frame].command, TokenKind::assignment);

            frames_[g].word_flags = frames_[frame].word_flags;
          }
        }
      }

      // Emits the keyword at [p_, end) and updates the lists; false if the word
      // is not a keyword where it stands.
      bool keyword(std::size_t frame, std::size_t end) noexcept {
        const Keyword found = findKeyword(fish_ ? std::span<const KeywordName>{fish_keywords} : std::span<const KeywordName>{posix_keywords}, slice(s_, p_, end));
        if (found == Keyword::none) {
          return false;
        }

        switch (frames_[frame].position) {
        case Position::start:
        case Position::after_close:
          break;
        case Position::header:
          return headerKeyword(frame, found, end);
        case Position::pattern:
          if (found == Keyword::esac && frames_[frame].command == no_command) {
            close(frame, FrameKind::case_block, end);
            return true;
          }

          return false;
        case Position::prefix:
        case Position::arguments:
          return false;
        }

        frames_[frame].pending_operator = false;
        frames_[frame].pending_body = false;
        return fish_ ? fishKeywordAt(frame, found, end) : posixKeywordAt(frame, found, end);
      }

      // The second word of a for, select or case header: `in`, or a for's `do`.
      bool headerKeyword(std::size_t frame, Keyword found, std::size_t end) noexcept {
        if (found == Keyword::in && frames_[frame].header_words == 1 && (frames_[frame].header == Header::loop || frames_[frame].header == Header::case_word)) {
          wordKeyword(frame, end);
          ++frames_[frame].header_words;
          if (frames_[frame].header == Header::case_word) {
            endCommand(frame, Position::pattern);
          }

          return true;
        }

        if (!fish_ && found == Keyword::do_word && frames_[frame].header_words == 1 && frames_[frame].header == Header::loop) {
          endCommand(frame, Position::start);
          wordKeyword(frame, end);
          return true;
        }

        return false;
      }

      bool posixKeywordAt(std::size_t frame, Keyword found, std::size_t end) noexcept {
        switch (found) {
        case Keyword::if_word:
          open(FrameKind::if_block, Position::start, Header::none, end);
          return true;
        case Keyword::while_word:
        case Keyword::until:
          open(FrameKind::loop, Position::start, Header::none, end);
          return true;
        case Keyword::for_word:
        case Keyword::select:
          open(FrameKind::loop, Position::header, Header::loop, end);
          return true;
        case Keyword::case_word:
          open(FrameKind::case_block, Position::header, Header::case_word, end);
          return true;
        case Keyword::brace_open:
          open(FrameKind::group, Position::start, Header::none, end);
          return true;
        case Keyword::fi:
          close(frame, FrameKind::if_block, end);
          return true;
        case Keyword::done:
          close(frame, FrameKind::loop, end);
          return true;
        case Keyword::esac:
          close(frame, FrameKind::case_block, end);
          return true;
        case Keyword::brace_close:
          close(frame, FrameKind::group, end);
          return true;
        case Keyword::test_open:
          if (room()) {
            ensureCommand(level());
            wordKeyword(frame, end);
            frames_[push(FrameKind::test, frames_[frame].command, TokenKind::argument)].position = Position::arguments;
          }

          return true;
        case Keyword::function:
          wordKeyword(frame, end);
          frames_[frame].position = Position::header;
          frames_[frame].header = Header::function;
          frames_[frame].header_words = 0;
          return true;
        case Keyword::then_word:
        case Keyword::elif_word:
        case Keyword::else_word:
        case Keyword::do_word:
        case Keyword::bang:
        case Keyword::time:
        case Keyword::coproc:
          wordKeyword(frame, end);
          frames_[frame].position = Position::start;
          return true;
        case Keyword::none:
        case Keyword::in:
        case Keyword::begin:
        case Keyword::end:
        case Keyword::switch_word:
        case Keyword::and_word:
        case Keyword::or_word:
        case Keyword::not_word:
          return false;
        }

        return false;
      }

      bool fishKeywordAt(std::size_t frame, Keyword found, std::size_t end) noexcept {
        switch (found) {
        case Keyword::begin:
          open(FrameKind::fish_block, Position::start, Header::none, end);
          return true;
        case Keyword::if_word:
          if (frames_[frame].after_else) {
            wordKeyword(frame, end);
            frames_[frame].position = Position::start;
            frames_[frame].after_else = false;
          } else {
            open(FrameKind::fish_block, Position::start, Header::none, end);
          }

          return true;
        case Keyword::while_word:
          open(FrameKind::fish_block, Position::start, Header::none, end);
          return true;
        case Keyword::for_word:
          open(FrameKind::fish_block, Position::header, Header::loop, end);
          return true;
        case Keyword::function:
        case Keyword::switch_word:
          open(FrameKind::fish_block, Position::header, Header::plain, end);
          return true;
        case Keyword::end:
          close(frame, FrameKind::fish_block, end);
          return true;
        case Keyword::else_word:
          wordKeyword(frame, end);
          frames_[frame].position = Position::start;
          frames_[frame].after_else = true;
          return true;
        case Keyword::case_word:
          wordKeyword(frame, end);
          frames_[frame].position = Position::header;
          frames_[frame].header = Header::plain;
          frames_[frame].header_words = 0;
          return true;
        case Keyword::and_word:
        case Keyword::or_word:
        case Keyword::not_word:
        case Keyword::time:
          wordKeyword(frame, end);
          frames_[frame].position = Position::start;
          return true;
        case Keyword::none:
        case Keyword::then_word:
        case Keyword::elif_word:
        case Keyword::fi:
        case Keyword::until:
        case Keyword::select:
        case Keyword::do_word:
        case Keyword::done:
        case Keyword::esac:
        case Keyword::in:
        case Keyword::coproc:
        case Keyword::bang:
        case Keyword::brace_open:
        case Keyword::brace_close:
        case Keyword::test_open:
          return false;
        }

        return false;
      }

      // A keyword word joins the command that follows it.
      void wordKeyword(std::size_t frame, std::size_t end) noexcept {
        ensureCommand(level());
        emit({.kind = TokenKind::keyword, .role = TokenKind::keyword, .command = frames_[frame].command, .flags = Token::word_start, .begin = p_, .end = end});
        touch(frames_[frame].command, p_, end);
        p_ = end;
      }

      void open(FrameKind kind, Position position, Header header, std::size_t end) noexcept {
        if (!room()) {
          return;
        }

        // A cursor waiting for the next command of this list gets the block's first.
        const bool pending = cursor_pending_ == level();
        const std::size_t g = push(kind, no_command, TokenKind::argument);

        if (pending) {
          cursor_pending_ = level();
        }

        wordKeyword(g, end);
        frames_[g].position = position;
        frames_[g].header = header;
      }

      void close(std::size_t frame, FrameKind kind, std::size_t end) noexcept {
        if (frames_[frame].kind != kind) {
          control(end - p_, TokenKind::error);
          return;
        }

        pop();
        const std::size_t parent = depth_ - 1;

        frames_[parent].command = no_command;
        wordKeyword(parent, end);
        frames_[parent].position = Position::after_close;
      }

      // ---- words

      void stepWord(std::size_t frame) noexcept {
        const char byte = s_[p_];
        if (globByte(frame, byte)) {
          return;
        }

        if (((bits(p_) & k_end) != 0) || (!fish_ && byte == '`' && frames_[frame].kind == FrameKind::backtick)) {
          endWord(frame);
          return;
        }

        switch (byte) {
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
            endWord(frame);
          } else {
            ++frames_[frame].glob;
            out(frame, frames_[frame].role, Quote::none, p_, p_ + 1);
            ++p_;
          }

          return;
        default:
          break;
        }

        std::size_t end = p_ + 1;

        while (end < n_ && ((bits(end) & k_stop) == 0)) {
          ++end;
        }

        out(frame, frames_[frame].role, Quote::none, p_, end);
        p_ = end;
      }

      // ( | ) inside a posix glob group, as *(a|b), belong to the word; false for any other byte.
      bool globByte(std::size_t frame, char byte) noexcept {
        if (fish_ || frames_[frame].glob == 0 || (byte != ')' && byte != '|' && byte != '(')) {
          return false;
        }

        if (byte == ')') {
          --frames_[frame].glob;
        } else if (byte == '(' && frames_[frame].glob < std::numeric_limits<u8>::max()) {
          ++frames_[frame].glob;
        }

        out(frame, frames_[frame].role, Quote::none, p_, p_ + 1);
        ++p_;
        return true;
      }

      // Ends the word of the list at index frame, which is also the list's level.
      void endWord(std::size_t frame) noexcept {
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
          if (frames_[frame].header_words < std::numeric_limits<u8>::max()) {
            ++frames_[frame].header_words;
          }

          if (frames_[frame].header == Header::function && frames_[frame].header_words == 1) {
            endCommand(frame, Position::start);
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

        Heredoc& heredoc = heredocs_[heredoc_count_++];

        heredoc.size = capture_.size();
        heredoc.strip_tabs = strip_tabs;
      }

      // A backslash and the character it escapes, whole even when multibyte.
      void escape(std::size_t frame, TokenKind kind, Quote quote) noexcept {
        // A backslash and a character of up to four bytes.
        constexpr std::size_t max_escape_bytes = 5;
        std::size_t end = p_ + 1;

        if (end < n_) {
          ++end;
          while (end < n_ && isContinuation(at(end)) && end < p_ + max_escape_bytes) {
            ++end;
          }
        }

        out(frame, kind, quote, p_, end);
        p_ = end;
      }

      void singleQuote(std::size_t frame) noexcept {
        std::size_t stop = p_ + 1;

        for (;;) {
          stop = s_.find_first_of(fish_ ? std::string_view{"\\'"} : std::string_view{"'"}, stop);
          if (stop == std::string_view::npos || (s_[stop] == '\\' && stop + 1 == n_)) {
            open_quote_ = true;
            out(frame, {.kind = TokenKind::string, .quote = Quote::single_quoted, .flags = Token::unterminated, .begin = p_, .end = n_});
            p_ = n_;
            return;
          }

          if (s_[stop] == '\'') {
            break;
          }

          stop += 2;
        }

        out(frame, TokenKind::string, Quote::single_quoted, p_, stop + 1);
        p_ = stop + 1;
      }

      void ansiString(std::size_t frame) noexcept {
        std::size_t stop = p_ + 2;

        for (;;) {
          stop = s_.find_first_of("\\'", stop);
          if (stop == std::string_view::npos || (s_[stop] == '\\' && stop + 1 == n_)) {
            open_quote_ = true;
            out(frame, {.kind = TokenKind::string, .quote = Quote::ansi_c, .flags = Token::unterminated, .begin = p_, .end = n_});
            p_ = n_;
            return;
          }

          if (s_[stop] == '\'') {
            break;
          }

          stop += 2;
        }

        out(frame, TokenKind::string, Quote::ansi_c, p_, stop + 1);
        p_ = stop + 1;
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

        const char following = s_[b + 1];
        if (following == '{') {
          openWord(frame, FrameKind::parameter, b + 2, TokenKind::variable, Quote::none);
        } else if (following == '(') {
          if (next(b + 2, '(')) {
            openWord(frame, FrameKind::arithmetic, b + 3, TokenKind::substitution, Quote::none);
          } else {
            openList(frame, FrameKind::substitution, b + 2);
          }
        } else if (unquoted && following == '\'') {
          ansiString(frame);
        } else if (unquoted && following == '"') {
          out(frame, TokenKind::string, Quote::none, b, b + 1);
          p_ = b + 1;
        } else if ((bits(b + 1) & k_name_start) != 0) {
          std::size_t end = b + 2;

          while (end < n_ && ((bits(end) & k_name) != 0)) {
            ++end;
          }

          out(frame, TokenKind::variable, Quote::none, b, end);
          p_ = end;
        } else if (((bits(b + 1) & k_digit) != 0) || following == '@' || following == '*' || following == '#' || following == '?' || following == '$' ||
                   following == '!' || following == '-') {
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

        std::size_t end = b + 1;

        while (end < n_ && s_[end] == '$') {
          ++end;
        }

        if (end == n_ || ((bits(end) & k_name) == 0)) {
          out(frame, end == n_ ? TokenKind::variable : literal, end == n_ ? Quote::none : quote, b, end);
          p_ = end;
          return;
        }

        while (end < n_ && ((bits(end) & k_name) != 0)) {
          ++end;
        }

        if (next(end, '[')) {
          std::size_t r = end + 1;

          while (r < n_ && s_[r] != ']' && ((bits(r) & k_newline) == 0) && s_[r] != '$' && s_[r] != '(' &&
                 s_[r] != '\'' && s_[r] != '"') {
            ++r;
          }

          if (next(r, ']')) {
            end = r + 1;
          }
        }

        out(frame, TokenKind::variable, Quote::none, b, end);
        p_ = end;
      }

      // ---- frames inside a word

      void stepDouble(std::size_t frame) noexcept {
        const char byte = s_[p_];
        if (byte == '"') {
          out(frame, TokenKind::string, Quote::double_quoted, p_, p_ + 1);
          ++p_;
          pop();
          return;
        }

        if (byte == '\\') {
          escape(frame, TokenKind::string, Quote::double_quoted);
          return;
        }

        if (byte == '$') {
          if (fish_) {
            fishDollar(frame, TokenKind::string, Quote::double_quoted);
          } else {
            dollar(frame, TokenKind::string, Quote::double_quoted, false);
          }

          return;
        }

        if (!fish_ && byte == '`') {
          openList(frame, FrameKind::backtick, p_ + 1);
          return;
        }

        std::size_t end = p_ + 1;

        while (end < n_ && ((bits(end) & k_quote_stop) == 0)) {
          ++end;
        }

        out(frame, TokenKind::string, Quote::double_quoted, p_, end);
        p_ = end;
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

        std::size_t end = p_ + 1;

        while (end < n_) {
          const char byte = s_[end];
          if (byte == '}' || byte == '\\' || byte == '"' || byte == '\'' || byte == '$' || byte == '`') {
            break;
          }

          ++end;
        }

        out(frame, TokenKind::variable, Quote::none, p_, end);
        p_ = end;
      }

      void stepArithmetic(std::size_t frame) noexcept {
        const char byte = s_[p_];
        if (byte == '(') {
          ++frames_[frame].parens;
          out(frame, TokenKind::substitution, Quote::none, p_, p_ + 1);
          ++p_;
          return;
        }

        if (byte == ')') {
          if (frames_[frame].parens > 0) {
            --frames_[frame].parens;
            out(frame, TokenKind::substitution, Quote::none, p_, p_ + 1);
            ++p_;
            return;
          }

          const std::size_t length = next(p_ + 1, ')') ? 2 : 1;
          const TokenKind closer = length == 1 ? TokenKind::error : arithmeticCloser(frame);

          out(frame, closer, Quote::none, p_, p_ + length);
          p_ += length;
          pop();
          return;
        }

        if (stepNested(frame, TokenKind::substitution)) {
          return;
        }

        std::size_t end = p_ + 1;

        while (end < n_) {
          const char candidate = s_[end];
          if (candidate == '(' || candidate == ')' || candidate == '\\' || candidate == '"' || candidate == '\'' || candidate == '$' || candidate == '`') {
            break;
          }

          ++end;
        }

        out(frame, TokenKind::substitution, Quote::none, p_, end);
        p_ = end;
      }

      [[nodiscard]] TokenKind arithmeticCloser(std::size_t frame) const noexcept {
        return frames_[frame].arithmetic_command ? TokenKind::keyword : TokenKind::substitution;
      }

      // ---- heredocs

      void readHeredocs() noexcept {
        for (std::size_t i = 0; i < heredoc_count_; ++i) {
          const std::size_t begin = p_;
          const HeredocBody body = heredocBody({heredocs_[i].text.data(), heredocs_[i].size}, heredocs_[i].strip_tabs);

          p_ = body.end;
          if (!body.closed) {
            heredoc_open_ = true;
          }

          opaque(begin <= cursor_ && (cursor_ < p_ || (cursor_ == p_ && (!body.closed || s_[p_ - 1] != '\n'))));
          if (p_ > begin) {
            emit({.kind = TokenKind::heredoc_body, .role = TokenKind::heredoc_body, .flags = body.closed ? u8{0} : Token::unterminated, .begin = begin, .end = p_});
          }
        }

        heredoc_count_ = 0;
      }

      // The lines from p_ up to the one that is delimiter, with leading tabs ignored when strip_tabs.
      [[nodiscard]] HeredocBody heredocBody(std::string_view delimiter, bool strip_tabs) const noexcept {
        std::size_t position = p_;

        while (position < n_) {
          std::size_t line_end = s_.find('\n', position);
          if (line_end == std::string_view::npos) {
            line_end = n_;
          }

          std::size_t line_begin = position;

          if (strip_tabs) {
            while (line_begin < line_end && s_[line_begin] == '\t') {
              ++line_begin;
            }
          }

          position = line_end < n_ ? line_end + 1 : n_;
          if (slice(s_, line_begin, line_end) == delimiter) {
            return {.end = position, .closed = true};
          }
        }

        return {.end = position, .closed = false};
      }

      // ---- end of line

      void finish() noexcept {
        for (std::size_t i = depth_; i-- > 0;) {
          const std::size_t frame = i;
          if (isList(frames_[frame].kind) && frames_[frame].in_word) {
            endWord(frame);
          }
        }

        finishCapture(false);
        if (!cursor_done_) {
          std::size_t list = depth_ - 1;

          while (list > 0 && !isList(frames_[list].kind)) {
            --list;
          }

          cursor_done_ = true;
          cursor_completable_ = true;
          cursor_command_ = frames_[list].command;
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
      tbc::val_self<Unquoter> capture_;
    };

    enum class Gathered : u8 {
      complete,
      invalid, // a token is out of order or outside the line
      full,    // the words or the text ran out
    };

    // The words of one command, gathered from its tokens for commandAt: each word's text is unquoted
    // into a buffer the gatherer borrows, region `a`.
    class WordGatherer {
    public:
      WordGatherer(tbc::val_a<std::string_view> line, Dialect dialect, std::span<Word> words, tbc::val_a<std::span<char>> text, std::size_t cursor) noexcept
          : line_(line),
            dialect_(dialect),
            words_(words),
            unquoter_(text),
            cursor_(cursor) {}

      // Adds the words of command to result.
      [[nodiscard]] Gathered gather(std::span<const Token> tokens, u32 command, CommandAt& result) noexcept {
        // Tokens from another line or out of order are rejected, never read past.
        std::size_t last_end = 0;

        for (std::size_t i = 0; i < tokens.size(); ++i) {
          const Token& token = tokens[i];
          if (token.begin < last_end || token.begin > token.end || token.end > line_.size()) {
            return Gathered::invalid;
          }

          last_end = token.end;
          if (token.command == command && !add(token, i, result)) {
            return Gathered::full;
          }
        }

        return closeWord(tokens.size(), result) ? Gathered::complete : Gathered::full;
      }

      // The unquoted bytes the words take.
      [[nodiscard]] std::size_t textSize() const noexcept {
        return unquoter_.size();
      }

      // The token indexes [first, end) of the word the cursor touches.
      [[nodiscard]] std::size_t currentFirst() const noexcept {
        return current_first_;
      }

      [[nodiscard]] std::size_t currentEnd() const noexcept {
        return current_end_;
      }

    private:
      // A piece joins the open word or starts the next; any other token ends the word.
      [[nodiscard]] bool add(const Token& token, std::size_t index, CommandAt& result) noexcept {
        if (!isPiece(token.kind)) {
          return closeWord(index, result);
        }

        if (!open_ || ((token.flags & Token::word_start) != 0)) {
          if (!closeWord(index, result)) {
            return false;
          }

          open_ = true;
          word_ = Word{.source = {.begin = token.begin, .end = token.end}, .text = {}, .role = token.role, .flags = static_cast<u8>(token.flags & Token::redirect_target)};
          text_begin_ = unquoter_.size();
          gap_ = token.begin;
          first_ = index;
        }

        unquoter_.verbatim(slice(line_, gap_, token.begin));
        unquoter_.piece(dialect_, token.kind, token.quote, slice(line_, token.begin, token.end));
        gap_ = token.end;
        word_.source.end = token.end;
        return true;
      }

      // Ends the open word at token end_token; false when words or text ran out.
      [[nodiscard]] bool closeWord(std::size_t end_token, CommandAt& result) noexcept {
        if (!open_) {
          return true;
        }

        open_ = false;
        if (result.words == words_.size() || unquoter_.overflow()) {
          return false;
        }

        word_.text = unquoter_.text(text_begin_);
        if (!result.in_word && word_.source.begin <= cursor_ && cursor_ <= word_.source.end) {
          result.in_word = true;
          result.current = result.words;
          result.replace = word_.source;
          current_first_ = first_;
          current_end_ = end_token;
        }

        if (result.command_word == no_word && word_.role == TokenKind::command) {
          result.command_word = result.words;
        }

        words_[result.words++] = word_;
        return true;
      }

      std::string_view line_;
      Dialect dialect_;
      std::span<Word> words_;
      Unquoter unquoter_;
      std::size_t cursor_;
      Word word_;
      bool open_ = false;
      std::size_t text_begin_ = 0;
      std::size_t gap_ = 0;
      std::size_t first_ = 0;
      std::size_t current_first_ = 0;
      std::size_t current_end_ = 0;
    };

  }

  Lexed lex(std::string_view line, Syntax syntax, std::span<Token> tokens, std::size_t cursor) noexcept {
    return Lexer{line, syntax, tokens, cursor}.run();
  }

  std::size_t segment(std::span<const Token> tokens, std::span<Segment> segments) noexcept {
    std::size_t count = 0;

    for (std::size_t i = 0; i < tokens.size(); ++i) {
      const Token& token = tokens[i];
      if (token.command == no_command) {
        continue;
      }

      const std::size_t id = token.command;
      // Commands without a token of their own before this one get an empty segment here.
      if (id >= count && id < segments.size()) {
        for (std::size_t j = count; j <= id; ++j) {
          segments[j] = Segment{.source = {.begin = token.begin, .end = token.begin}, .first_token = static_cast<u32>(i), .end_token = static_cast<u32>(i)};
        }
      }

      count = std::max(count, id + 1);
      if (id < segments.size()) {
        Segment& entry = segments[id];

        entry.source.end = std::max(entry.source.end, token.end);
        entry.end_token = static_cast<u32>(i + 1);
      }
    }

    return count;
  }

  tbc::val_a<CommandAt> commandAt(tbc::val_a<std::string_view> line, Syntax syntax, std::span<const Token> tokens, const Lexed& lexed, std::span<Word> words, tbc::val_a<std::span<char>> text) noexcept { // NOLINT(readability-function-size): the exported signature takes six parameters
    CommandAt result;

    if (!lexed.cursor_completable || lexed.cursor > line.size()) {
      return result;
    }

    if (lexed.overflow) {
      result.overflow = true;
      return result;
    }

    const std::size_t cursor = lexed.cursor;
    const u32 command = lexed.cursor_command;

    tokens = tokens.first(std::min(tokens.size(), lexed.tokens));
    result.replace = Range{.begin = static_cast<u32>(cursor), .end = static_cast<u32>(cursor)};
    if (command == no_command) {
      result.current = 0;
      return result;
    }

    WordGatherer gatherer{line, syntax.dialect, words, text, cursor};

    switch (gatherer.gather(tokens, command, result)) {
    case Gathered::complete:
      break;
    case Gathered::invalid:
      result = CommandAt{};
      result.overflow = true;
      return result;
    case Gathered::full:
      result.overflow = true;
      return result;
    }

    if (!result.in_word) {
      std::size_t before = 0;

      while (before < result.words && words[before].source.end < cursor) {
        ++before;
      }

      result.current = before;
      return result;
    }

    // The prefix: the current word's pieces cut result the cursor.
    const std::size_t current_first = gatherer.currentFirst();
    const std::size_t current_end = gatherer.currentEnd();
    Unquoter prefix{text.subspan(gatherer.textSize())};
    std::size_t gap = result.replace.begin;

    for (std::size_t i = current_first; i < current_end && gap < cursor; ++i) {
      const Token& token = tokens[i];
      if (token.command != command || !isPiece(token.kind)) {
        continue;
      }

      const std::size_t begin = std::min<std::size_t>(token.begin, cursor);
      const std::size_t end = std::min<std::size_t>(token.end, cursor);

      prefix.verbatim(slice(line, gap, begin));
      prefix.piece(syntax.dialect, token.kind, token.quote, slice(line, begin, end));
      gap = end;
    }

    if (prefix.overflow()) {
      result.overflow = true;
      return result;
    }

    result.prefix = prefix.text(0);
    return result;
  }

}
