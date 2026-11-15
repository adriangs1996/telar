export module telar.runtime.diagnostics.line;

import std;
import telar.base.diagnostics;

export namespace telar::runtime::diagnostics {

  using ::telar::accumulate;
  using ::telar::TimedScope;
  using ::telar::Timing;

  // One diagnostics record as a line of JSON, written into a fixed buffer: reset, then fields,
  // then finish. A line past the capacity throws std::length_error.
  class Line {
  public:
    static constexpr std::size_t capacity = 12288;

    void reset() noexcept;
    void field(std::string_view name, std::uint64_t value);
    void field(std::string_view name, std::optional<std::uint64_t> value);
    void literal(std::string_view name, std::string_view value);
    // The average and the maximum of `value`, in microseconds.
    void timing(std::string_view average_name, std::string_view maximum_name, const Timing& value);
    std::string_view finish();

  private:
    void key(std::string_view name);
    void append(std::string_view text);

    std::array<char, capacity> bytes_;
    std::size_t length_ = 0;
  };

}
