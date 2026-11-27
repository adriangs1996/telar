export module telar.msgpack;

import std;
import telar.base.ds;
import telar.tbc;

// MessagePack as an untrusted peer writes it: values are read in place from the bytes received,
// nothing is copied or allocated, and every length is checked against the bytes that are there.
export namespace telar::msgpack {

  enum class Kind : std::uint8_t {
    nil,
    boolean,
    // Zero or more, whichever integer family encoded it.
    unsigned_integer,
    negative_integer,
    floating,
    string,
    binary,
    array,
    map,
    extension,
  };

  // The head of one value. An array's items and a map's keys and values are the values that
  // follow it; a string's, a binary's and an extension's bytes view the input.
  struct Token {
    Kind kind = Kind::nil;
    std::int8_t extension = 0;
    // A boolean as 0 or 1, an integer in two's complement, a float's IEEE 754 double, and the
    // items of an array or the pairs of a map.
    std::uint64_t bits = 0;
    tbc::val_a<std::span<const std::uint8_t>> bytes;

    [[nodiscard]] constexpr bool boolean() const noexcept {
      return bits != 0;
    }

    [[nodiscard]] constexpr std::int64_t integer() const noexcept {
      return static_cast<std::int64_t>(bits);
    }

    [[nodiscard]] constexpr double floating() const noexcept {
      return std::bit_cast<double>(bits);
    }

    [[nodiscard]] constexpr std::uint32_t count() const noexcept {
      return static_cast<std::uint32_t>(bits);
    }

    // The bytes as the text they spell, which the token views as it views them.
    [[nodiscard]] tbc::val_a<std::string_view> text() const noexcept;
  };

  enum class Status : std::uint8_t {
    ok,
    // The input ends inside the value.
    incomplete,
    malformed,
  };

  // What reading one head came to, and the head when it was read.
  struct Read {
    Status status = Status::incomplete;
    tbc::val_a<Token> token;
  };

  // The containers a value nests before it is refused.
  inline constexpr unsigned max_depth = 32;

  // The bytes of a number that follows a type byte.
  enum class Width : std::uint8_t {
    none = 0,
    one = 1,
    two = 2,
    four = 4,
    eight = 8,
  };

  // Reads the values of a buffer one head at a time. A typed read that finds another kind, or
  // the end of the input, fails the reader for good: a caller reads a whole message and asks
  // `failed()` once.
  class [[tbc::hot_path]] Reader {
  public:
    constexpr explicit Reader(tbc::val_a<std::span<const std::uint8_t>> input) noexcept
        : input_(input) {}

    // The head of the next value, whose bytes view the input the reader was given.
    inline tbc::val_a<Read> next() noexcept {
      if (offset_ >= input_.size()) {
        return {};
      }

      const auto head = input_[offset_];
      if (head <= positive_fixint_last) {
        return produce({.kind = Kind::unsigned_integer, .bits = head}, 1);
      }

      if (head >= negative_fixint_first) {
        return produce({.kind = Kind::negative_integer, .bits = static_cast<std::uint64_t>(static_cast<std::int64_t>(static_cast<std::int8_t>(head)))}, 1);
      }

      if (head >= fixstr_first && head <= fixstr_last) {
        return payload(Kind::string, {.head = 1, .length = static_cast<std::uint64_t>(head) & fixstr_length});
      }

      if (head >= fixarray_first && head <= fixarray_last) {
        return produce({.kind = Kind::array, .bits = static_cast<std::uint64_t>(head) & fixcontainer_length}, 1);
      }

      if (head >= fixmap_first && head <= fixmap_last) {
        return produce({.kind = Kind::map, .bits = static_cast<std::uint64_t>(head) & fixcontainer_length}, 1);
      }

      return tagged(head);
    }

    // The head of the next value; none, failing the reader, when the input ends or is malformed.
    inline tbc::val_a<ds::Option<Token>> value() noexcept {
      if (failed_) {
        return ds::none;
      }

      const auto read = next();
      if (read.status != Status::ok) {
        fail();
        return ds::none;
      }

      return read.token;
    }

    // Skips one whole value with what it holds, nested no deeper than `depth`.
    bool skip(unsigned depth = max_depth) noexcept;

    inline bool array(std::uint32_t& count) noexcept {
      const auto token = take(Kind::array);
      if (!token) {
        return false;
      }

      count = token->count();
      return true;
    }

    inline bool map(std::uint32_t& count) noexcept {
      const auto token = take(Kind::map);
      if (!token) {
        return false;
      }

      count = token->count();
      return true;
    }

    // An array of exactly `count` items.
    inline bool tuple(std::uint32_t count) noexcept {
      std::uint32_t found = 0;

      return array(found) && (found == count || fail());
    }

    inline bool unsignedInteger(std::uint64_t& value) noexcept {
      const auto token = take(Kind::unsigned_integer);
      if (!token) {
        return false;
      }

      value = token->bits;
      return true;
    }

    // Any integer an int64 holds.
    inline bool integer(std::int64_t& value) noexcept {
      const auto token = this->value();
      if (!token) {
        return false;
      }

      if (token->kind == Kind::negative_integer || (token->kind == Kind::unsigned_integer && std::in_range<std::int64_t>(token->bits))) {
        value = token->integer();
        return true;
      }

      return fail();
    }

    // A float, or an integer as the float it equals.
    bool number(double& value) noexcept;

    inline bool boolean(bool& value) noexcept {
      const auto token = take(Kind::boolean);
      if (!token) {
        return false;
      }

      value = token->boolean();
      return true;
    }

    // A string or a binary as text; none, failing the reader, for any other value.
    inline tbc::val_a<ds::Option<std::string_view>> string() noexcept {
      const auto token = value();
      if (!token) {
        return ds::none;
      }

      if (token->kind != Kind::string && token->kind != Kind::binary) {
        fail();
        return ds::none;
      }

      return token->text();
    }

    // The kind of the next value without reading it; nil at the end of the input.
    [[nodiscard]] Kind peek() const noexcept;

    [[nodiscard]] constexpr bool failed() const noexcept {
      return failed_;
    }

    [[nodiscard]] constexpr std::size_t offset() const noexcept {
      return offset_;
    }

    [[nodiscard]] constexpr bool atEnd() const noexcept {
      return offset_ >= input_.size();
    }

    constexpr bool fail() noexcept {
      failed_ = true;
      return false;
    }

  private:
    static constexpr std::uint8_t positive_fixint_last = 0x7f;
    static constexpr std::uint8_t fixmap_first = 0x80;
    static constexpr std::uint8_t fixmap_last = 0x8f;
    static constexpr std::uint8_t fixarray_first = 0x90;
    static constexpr std::uint8_t fixarray_last = 0x9f;
    static constexpr std::uint8_t fixstr_first = 0xa0;
    static constexpr std::uint8_t fixstr_last = 0xbf;
    static constexpr std::uint8_t negative_fixint_first = 0xe0;
    static constexpr std::uint64_t fixcontainer_length = 0x0f;
    static constexpr std::uint64_t fixstr_length = 0x1f;

    // A value's bytes after its head: where they start and how many they are.
    struct Body {
      std::size_t head = 1;
      std::uint64_t length = 0;
    };

    // The head of the next value when it is of `kind`; none, failing the reader, otherwise.
    inline tbc::val_a<ds::Option<Token>> take(Kind kind) noexcept {
      const auto token = value();
      if (!token) {
        return ds::none;
      }

      if (token->kind != kind) {
        fail();
        return ds::none;
      }

      return *token;
    }

    // A value read whole in `size` bytes.
    inline tbc::val_a<Read> produce(tbc::val_a<Token> value, std::size_t size) noexcept {
      offset_ += size;
      return {.status = Status::ok, .token = value};
    }

    inline tbc::val_a<Read> payload(Kind kind, Body body) noexcept {
      const auto remaining = input_.size() - offset_;
      if (remaining < body.head || remaining - body.head < body.length) {
        return {};
      }

      const auto length = static_cast<std::size_t>(body.length);
      const Token token{.kind = kind, .bits = body.length, .bytes = input_.subspan(offset_ + body.head, length)};

      offset_ += body.head + length;
      return {.status = Status::ok, .token = token};
    }

    // The big-endian number of `width` bytes that starts `skip` bytes into the value; none when
    // the input ends before it.
    [[nodiscard]] ds::Option<std::uint64_t> load(Width width, std::size_t skip = 1) const noexcept;

    // The values whose first byte names their type and the width of what follows it.
    tbc::val_a<Read> tagged(std::uint8_t head) noexcept;
    tbc::val_a<Read> extension(Body body) noexcept;

    tbc::val_a<std::span<const std::uint8_t>> input_;
    std::size_t offset_ = 0;
    bool failed_ = false;
  };

  // Finds where each top-level value ends in a stream that arrives in pieces, without keeping
  // its bytes: a caller buffers a piece and decodes the buffer once the value is whole.
  class Scanner {
  public:
    struct Progress {
      // The bytes of the piece that belong to the value being read.
      std::size_t consumed = 0;
      // ok once the value ended at `consumed`, incomplete while it needs more bytes.
      Status status = Status::incomplete;
    };

    Progress feed(std::span<const std::uint8_t> bytes) noexcept;

    void reset() noexcept;

  private:
    // The longest head: a type byte and the eight bytes of a 64-bit number.
    static constexpr std::size_t head_capacity = 9;

    // What a head leaves to read before its value ends.
    struct Rest {
      std::uint64_t children = 0;
      std::uint64_t payload = 0;
    };

    // What reading a little more of a piece came to.
    enum class Step : std::uint8_t {
      advanced,
      // The top-level value ended.
      ended,
      // The piece ended inside a head.
      starved,
      malformed,
    };

    // Reads the payload being skipped or one head, moving `consumed` past what it read.
    Step step(std::span<const std::uint8_t> bytes, std::size_t& consumed) noexcept;
    // Takes the bytes of a head from the piece: advanced once the head is whole.
    Step gather(std::span<const std::uint8_t> bytes, std::size_t& consumed) noexcept;
    [[nodiscard]] Rest rest() const noexcept;
    // Whether the value that just ended was the top-level one.
    bool valueEnded() noexcept;

    ds::Array<std::uint64_t, max_depth> pending_{};
    ds::Array<std::uint8_t, head_capacity> head_{};
    std::uint64_t skip_ = 0;
    std::uint8_t depth_ = 0;
    std::uint8_t head_size_ = 0;
    std::uint8_t head_need_ = 0;
  };

  // Writes values into a buffer of the caller's, in the smallest encoding each has. A write past
  // the buffer's end writes nothing and leaves the writer overflowed.
  class Writer {
  public:
    explicit Writer(tbc::val_a<std::span<std::uint8_t>> output) noexcept;

    void nil() noexcept;
    void boolean(bool value) noexcept;
    void unsignedInteger(std::uint64_t value) noexcept;
    void integer(std::int64_t value) noexcept;
    void floating(double value) noexcept;
    void string(std::string_view value) noexcept;
    void binary(std::span<const std::uint8_t> value) noexcept;
    void array(std::uint32_t count) noexcept;
    void map(std::uint32_t count) noexcept;

    [[nodiscard]] bool overflowed() const noexcept;
    [[nodiscard]] tbc::val_a<std::span<const std::uint8_t>> written() const noexcept;

  private:
    // A type byte and the big-endian number of `width` bytes after it.
    void put(std::uint8_t head, Width width = Width::none, std::uint64_t value = 0) noexcept;
    // A head that carries `size` in the narrowest of the three widths `heads` are for, or the
    // overflow of a size none holds.
    bool sized(std::size_t size, ds::Array<std::uint8_t, 3> heads) noexcept;
    void append(std::span<const std::uint8_t> bytes) noexcept;

    tbc::val_a<std::span<std::uint8_t>> output_;
    std::size_t size_ = 0;
    bool overflowed_ = false;
  };

}
