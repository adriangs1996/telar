module telar.cli.console.command_limit;

import telar.sys.posix;
import telar.tbc;
import telar.wire.vocabulary;
import telar.platform.error;
import telar.platform.primitives;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime::cli {

  // NOLINTNEXTLINE(cppcoreguidelines-pro-type-member-init): push writes each byte of buffer_ before flush reads it, so zeroing its 4 KiB for every writer is work the output never needs.
  DescriptorWriter::DescriptorWriter(int descriptor) noexcept
      : descriptor_(descriptor) {}

  void DescriptorWriter::flush() {
    if (used_ != 0) {
      const auto used = std::exchange(used_, 0);

      writeText({buffer_.data(), used}, descriptor_);
    }
  }

  [[noreturn]] void usage(const char* error) {
    throw std::invalid_argument{error};
  }

  namespace {

    // The names of an enum's values, one for each from 0 to `Last`.
    template <auto Last>
    using EnumNames = ds::Array<std::string_view, std::size_t{std::to_underlying(Last)} + 1>;

  }

  template <typename Integer>
  Integer parseDecimal(std::string_view text, Sign sign) {
    const bool negative = sign == Sign::accepted && text.starts_with('-');
    if (sign == Sign::accepted && (text.starts_with('+') || negative)) {
      text.remove_prefix(1);
    }

    if (text.empty() || text.front() == '_' || text.back() == '_') {
      usage("InvalidCharacter");
    }

    using Unsigned = std::make_unsigned_t<Integer>;
    constexpr auto positive_limit = static_cast<Unsigned>(std::numeric_limits<Integer>::max());
    constexpr auto negative_limit = std::is_signed_v<Integer> ? static_cast<Unsigned>(positive_limit + 1) : Unsigned{0};
    const auto limit = negative ? negative_limit : positive_limit;
    const auto parsed = unsignedNumber<Unsigned>(text, limit);
    if (!parsed) {
      usage(parsed.error() == NumberError::overflow ? "Overflow" : "InvalidCharacter");
    }

    const auto value = *parsed;

    if constexpr (std::is_signed_v<Integer>) {
      if (negative) {
        return value == negative_limit ? std::numeric_limits<Integer>::min() : static_cast<Integer>(-static_cast<Integer>(value));
      }
    }

    return static_cast<Integer>(value);
  }

  template <typename Integer>
  Integer parseInt(std::string_view text) {
    return parseDecimal<Integer>(text, Sign::accepted);
  }

  template <typename Integer>
  Integer parseUnsigned(std::string_view text) {
    return parseDecimal<Integer>(text, Sign::rejected);
  }

  template <typename Integer>
  ds::Option<Integer> maybeUnsigned(std::string_view text) noexcept {
    try {
      return parseUnsigned<Integer>(text);
    } catch (const std::invalid_argument&) {
      return ds::none;
    }
  }

  template <typename Integer>
  Integer number(std::string_view text, const char* error) {
    const auto value = maybeUnsigned<Integer>(text);
    if (!value) {
      usage(error);
    }

    return *value;
  }

  template <typename Integer>
  Integer signedNumber(std::string_view text, const char* error) {
    try {
      return parseInt<Integer>(text);
    } catch (const std::invalid_argument&) {
      usage(error);
    }
  }

  std::uint64_t positive(std::string_view text, const char* error) {
    const auto value = number(text, error);
    if (value == 0) {
      usage(error);
    }

    return value;
  }

  template <typename Enum, std::size_t Size>
  Enum choice(std::string_view text, const char* error, const ds::Array<std::string_view, Size>& names) {
    const auto found = std::ranges::find(names, text);
    if (found == names.end()) {
      usage(error);
    }

    return static_cast<Enum>(found - names.begin());
  }

  void writeBytes(int descriptor, std::span<const Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::write(descriptor, bytes.data(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        throw std::runtime_error{"WriteFailed"};
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }
  }

  void writeText(std::string_view text, int descriptor) {
    writeBytes(descriptor, byteView(text));
  }

  std::string_view textBytes(std::span<const Byte> bytes) {
    return textView(bytes);
  }

  std::uint64_t randomIdentity() {
    std::uint64_t value = 0;

    while (value == 0) {
      randomBytes(&value, sizeof(value));
    }

    return value;
  }

  const char* jsonBoolean(bool value) {
    return value ? "true" : "false";
  }

  std::string_view commandErrorName(const std::exception& error) {
    if (const auto* system = dynamic_cast<const SystemError*>(&error)) {
      return sys::errorName(system->code());
    }

    if (std::string_view{error.what()} == "Runtime receive timed out") {
      return "RuntimeTimeout";
    }

    return error.what();
  }

  void reportCommandLimit(const LimitReach& reach) {
    constexpr std::size_t line_capacity = 512;

    ds::Array<char, line_capacity> line{};
    const auto written = std::format_to_n(line.dataMut(), line.size(), "telar: Limit reached: {}\n", limitDescription(reach));

    writeText({line.data(), std::min(static_cast<std::size_t>(written.size), line.size())}, STDERR_FILENO);
  }

  template int parseInt<int>(std::string_view text);
  template long parseInt<long>(std::string_view text);
  template long long parseInt<long long>(std::string_view text);
  template unsigned short parseInt<unsigned short>(std::string_view text);
  template unsigned int parseInt<unsigned int>(std::string_view text);
  template unsigned long parseInt<unsigned long>(std::string_view text);
  template unsigned long long parseInt<unsigned long long>(std::string_view text);

  template unsigned short parseUnsigned<unsigned short>(std::string_view text);
  template ds::Option<unsigned short> maybeUnsigned<unsigned short>(std::string_view text) noexcept;
  template unsigned short number<unsigned short>(std::string_view text, const char* error);
  template unsigned int parseUnsigned<unsigned int>(std::string_view text);
  template ds::Option<unsigned int> maybeUnsigned<unsigned int>(std::string_view text) noexcept;
  template unsigned int number<unsigned int>(std::string_view text, const char* error);
  template unsigned long parseUnsigned<unsigned long>(std::string_view text);
  template ds::Option<unsigned long> maybeUnsigned<unsigned long>(std::string_view text) noexcept;
  template unsigned long number<unsigned long>(std::string_view text, const char* error);
  template unsigned long long parseUnsigned<unsigned long long>(std::string_view text);
  template ds::Option<unsigned long long> maybeUnsigned<unsigned long long>(std::string_view text) noexcept;
  template unsigned long long number<unsigned long long>(std::string_view text, const char* error);

  template int signedNumber<int>(std::string_view text, const char* error);
  template long signedNumber<long>(std::string_view text, const char* error);
  template long long signedNumber<long long>(std::string_view text, const char* error);

  template PaneDirection choice<PaneDirection>(std::string_view text, const char* error, const EnumNames<PaneDirection::down>& names);
  template AgentStatus choice<AgentStatus>(std::string_view text, const char* error, const EnumNames<AgentStatus::done>& names);
  template AgentSessionFileKind choice<AgentSessionFileKind>(std::string_view text, const char* error, const EnumNames<AgentSessionFileKind::cursor_meta>& names);
  template AgentReportState choice<AgentReportState>(std::string_view text, const char* error, const EnumNames<AgentReportState::interrupted>& names);
  template AgentCommandPhase choice<AgentCommandPhase>(std::string_view text, const char* error, const EnumNames<AgentCommandPhase::finished>& names);
  template AgentBlockedReason choice<AgentBlockedReason>(std::string_view text, const char* error, const EnumNames<AgentBlockedReason::other>& names);

  Cursor::Cursor(tbc::val_a<Arguments> words) noexcept
      : words_(words) {}

  bool Cursor::empty() const noexcept {
    return words_.empty();
  }

  tbc::val_a<ds::Option<std::string_view>> Cursor::next() noexcept {
    if (words_.empty()) {
      return ds::none;
    }

    const std::string_view word = words_.front();

    words_ = words_.subspan(1);
    return word;
  }

  tbc::val_a<std::string_view> Cursor::take(const char* missing) {
    const auto word = next();
    if (!word) {
      usage(missing);
    }

    return *word;
  }

  tbc::val_a<Arguments> Cursor::rest() const noexcept {
    return words_;
  }

}
