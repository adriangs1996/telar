export module telar.runtime.diagnostics.line;

import std;
import telar.base.diagnostics;
import telar.base.ds;

export namespace telar::runtime::diagnostics {

  using ::telar::accumulate;
  using ::telar::TimedScope;
  using ::telar::Timing;

  // A value already written as JSON, which a line copies as it is.
  struct RawJson {
    std::string_view text;
  };

  // The names of the two fields a timing writes.
  struct TimingFields {
    std::string_view average;
    std::string_view maximum;
  };

  // One diagnostics record as a line of JSON, written into a fixed buffer: reset, then fields,
  // then finish. A line past the capacity throws std::length_error.
  class Line { // NOLINT(cppcoreguidelines-pro-type-member-init): a line writes its bytes before it reads them, so constructing one leaves its 12 KiB unwritten
  public:
    static constexpr std::size_t capacity = 12288;

    void reset() noexcept;
    void field(std::string_view name, std::uint64_t value);
    void field(std::string_view name, ds::Option<std::uint64_t> value);
    void literal(std::string_view name, RawJson value);
    // The average and the maximum of `value`, in microseconds.
    void timing(TimingFields names, const Timing& value);
    std::string_view finish();

  private:
    void key(std::string_view name);
    void append(std::string_view text);

    ds::Array<char, capacity> bytes_;
    std::size_t length_ = 0;
  };

}
