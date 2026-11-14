module;
#include "tbc/annotations.hpp"
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits.h>

export module telar.machines;

// The machines a client can open: their profiles on disk, how they are named and reached, and
// what discovery learns of the runtime on each.
import std;

export import telar.base.text.json;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text;
import telar.base.text.utf8;
import telar.client;

// Interface: telar_machines/number_radix.cppm
export {
  namespace telar::runtime::machines {

    enum class NumberRadix : std::uint8_t {
      decimal = 10,
      hexadecimal = 16,
    };

  }
}

// Interface: telar_machines/binary_fraction.cppm
export {
  namespace telar::runtime::machines {

    template <std::size_t MaximumExponent>
    class BinaryFraction {
    public:
      explicit BinaryFraction(std::size_t exponent, NumberRadix radix = NumberRadix::decimal);

      [[nodiscard]] unsigned digit(std::size_t position) const noexcept;
      [[nodiscard]] unsigned complementDigit(std::size_t position, NumberRadix radix) const noexcept;
      [[nodiscard]] std::size_t size() const noexcept;

    private:
      static constexpr unsigned decimal_radix = 10;
      static constexpr unsigned hexadecimal_bits = 4;
      static constexpr unsigned decimal_limb_digits = 9;
      static constexpr std::uint64_t decimal_limb_base = 1'000'000'000;
      static constexpr std::uint64_t half_decimal_radix = decimal_radix / 2;
      static constexpr std::size_t limb_capacity = ((MaximumExponent + decimal_limb_digits - 1) / decimal_limb_digits) + 1;

      void deriveDecimal(std::size_t exponent);

      std::array<std::uint8_t, MaximumExponent> digits_{};
      std::size_t length_ = 0;
    };

  }
}

// Interface: telar_machines/bounded_text.cppm
export {
  namespace telar::runtime::machines {

    // Stays in the interface: a small fixed-capacity text on the GUI's key encoder and runtime link
    // paths, used with dozens of caller-chosen capacities.
    template <std::size_t Capacity>
    class TBC_HOT_PATH BoundedText {
    public:
      inline void append(std::string_view text) {
        if (text.size() > Capacity - length_) {
          throw std::length_error{"Text capacity exceeded"};
        }

        if (!text.empty()) {
          std::memmove(storage_.data() + length_, text.data(), text.size());
          length_ += text.size();
        }
      }

      template <std::unsigned_integral Number>
      inline void appendDecimal(Number number) {
        const auto result = std::to_chars(storage_.data() + length_, storage_.data() + Capacity, number);
        if (result.ec != std::errc{}) {
          throw std::length_error{"Text capacity exceeded"};
        }

        length_ = static_cast<std::size_t>(result.ptr - storage_.data());
      }

      inline void truncate(std::size_t length) {
        if (length > length_) {
          throw std::out_of_range{"Text truncation exceeds length"};
        }

        length_ = length;
      }

      [[nodiscard]] inline std::string_view view() const noexcept {
        return {storage_.data(), length_};
      }

    private:
      std::array<char, Capacity> storage_{};
      std::size_t length_ = 0;
    };

  }
}

// Interface: telar_machines/failure.cppm
export {
  namespace telar::runtime::machines {

    enum class MachineError : std::uint8_t {
      invalid_id,
      invalid_label,
      invalid_destination,
      invalid_color,
      invalid_program,
      invalid_profiles,
      incompatible_profiles,
      too_many,
      duplicate_id,
      duplicate_label,
      duplicate_destination,
      unknown_machine,
      discovery_unreadable,
      host_key_rejected,
      authentication_failed,
      remote_program_missing,
      remote_program_incompatible,
      remote_runtime_incompatible,
      endpoint_unavailable,
      incompatible_schema,
      runtime_already_running,
      invalid_runtime_directory,
    };

    class MachineFailure final : public std::runtime_error {
    public:
      explicit MachineFailure(MachineError code);

      [[nodiscard]] MachineError code() const noexcept;
      [[nodiscard]] static const char* name(MachineError code);

      // The error a name() spells, for an error that crossed a boundary as its text.
      [[nodiscard]] static std::optional<MachineError> named(std::string_view text) noexcept;

      // What a person reads for an error a saved machine's profile caused; none for the others.
      [[nodiscard]] static std::optional<std::string_view> description(MachineError code) noexcept;

      // machines.json refused for its owner or mode.
      static constexpr std::string_view insecure_file = "machines.json must be a regular file only its owner can read and write (chmod 600)";

    private:
      MachineError code_;
    };

  }
}

// Interface: telar_machines/discovery.cppm
export {
  namespace telar::runtime::machines {

    template <std::size_t MaximumPathBytes>
    class MachineDiscovery {
    public:
      static constexpr std::size_t path_count = 3;
      static constexpr std::size_t max_output_bytes = (path_count * (MaximumPathBytes + 1)) + SchemaId{}.size() + 1;

      [[nodiscard]] static MachineDiscovery parse(std::string_view output);

      [[nodiscard]] std::string_view home() const noexcept;
      [[nodiscard]] std::string_view shell() const noexcept;
      [[nodiscard]] std::string_view endpoint() const noexcept;
      [[nodiscard]] const SchemaId& schema() const noexcept;
      [[nodiscard]] bool compatible(const SchemaId& expected = handshake::schema_id) const noexcept;

    private:
      static bool asciiAlphanumeric(char character) noexcept;
      static void validatePath(std::string_view path, bool socket_path);

      runtime::FixedText<MaximumPathBytes> home_;
      runtime::FixedText<MaximumPathBytes> shell_;
      runtime::FixedText<MaximumPathBytes> endpoint_;
      SchemaId schema_{};
    };

    // The native path limit, the one capacity the CLI and the GUI discover with.
    extern template class MachineDiscovery<PATH_MAX>;

  }
}

// Interface: telar_machines/limits.cppm
export {
  namespace telar::runtime::machines {

    struct MachineLimits {
      static constexpr std::size_t profiles = 16;
      static constexpr std::size_t window_slots = profiles + 1;
      static constexpr std::size_t label_bytes = 32;
      static constexpr std::size_t destination_bytes = 255;
      static constexpr std::size_t color_bytes = 24;
      static constexpr std::size_t program_bytes = 255;
      static constexpr std::size_t file_bytes = std::size_t{32} * 1024;
      static constexpr std::size_t failure_bytes = 256;
    };

  }
}

// Interface: telar_machines/field_rules.cppm
export {
  namespace telar::runtime::machines {

    struct MachineFieldRules {
      static void label(std::string_view text);
      static void destination(std::string_view text);
      static void profileDestination(std::string_view text);
      static void color(std::string_view text);
      static void program(std::string_view text);

    private:
      static constexpr unsigned char delete_byte = 0x7f;
      static constexpr std::size_t minimum_program_bytes = 2;

      static bool decimal(char byte) noexcept;
      static bool alphanumeric(char byte) noexcept;
    };

  }
}

// Interface: telar_machines/identity.cppm
export {
  namespace telar::runtime::machines {

    template <typename Random>
    concept MachineIdentityRandom = requires(Random& random, std::span<std::uint8_t> bytes) {
      { random.fill(bytes) } -> std::same_as<void>;
    };

    class MachineId {
    public:
      static constexpr std::string_view prefix = "m-";
      static constexpr std::size_t hex_digits = 12;
      static constexpr std::size_t text_bytes = prefix.size() + hex_digits;
      static constexpr unsigned bits_per_digit = 4;
      static constexpr unsigned value_bits = hex_digits * bits_per_digit;
      static constexpr auto maximum_value = (std::uint64_t{1} << value_bits) - 1;

      [[nodiscard]] static MachineId fromRaw(std::uint64_t value);
      [[nodiscard]] static MachineId parse(std::string_view text);

      // Generic over the caller's random source, so it stays here and hands the work to draw.
      template <MachineIdentityRandom Random>
      [[nodiscard]] TBC_HOT_PATH static MachineId generate(Random& random) {
        return draw(std::addressof(random), [](void* source, std::span<std::uint8_t> bytes) {
          static_cast<Random*>(source)->fill(bytes);
        });
      }

      [[nodiscard]] BoundedText<text_bytes> format() const;
      [[nodiscard]] std::uint64_t value() const noexcept;

      bool operator==(const MachineId&) const = default;

    private:
      static MachineId draw(void* random, void (*fill)(void*, std::span<std::uint8_t>));

      static constexpr std::string_view digits = "0123456789abcdef";
      static constexpr auto digit_mask = (std::uint64_t{1} << bits_per_digit) - 1;
      std::uint64_t value_ = 0;
    };

  }
}

// Interface: telar_machines/radix_number.cppm
export {
  namespace telar::runtime::machines {

    template <Allocator Memory>
    class RadixNumber {
    public:
      static constexpr unsigned decimal_radix = static_cast<unsigned>(NumberRadix::decimal);
      static constexpr unsigned hexadecimal_radix = static_cast<unsigned>(NumberRadix::hexadecimal);
      static constexpr unsigned hexadecimal_bits = 4;

      RadixNumber(Memory& memory, std::string_view text, bool floating_syntax);

      [[nodiscard]] bool negative() const noexcept;
      [[nodiscard]] NumberRadix radix() const noexcept;
      [[nodiscard]] bool zero() const noexcept;
      [[nodiscard]] bool integral() const noexcept;
      [[nodiscard]] std::size_t fractionLeadingZeros() const noexcept;
      [[nodiscard]] std::uint32_t integerPart(std::uint32_t maximum) const;

      template <typename Fraction>
      [[nodiscard]] int compareFraction(const Fraction& threshold, bool complement = false) const noexcept;

    private:
      static constexpr std::string_view digit_symbols = "0123456789abcdef";
      static constexpr std::size_t hexadecimal_prefix_bytes = 2;
      static constexpr std::ptrdiff_t minimum_exponent_budget = 20'000;

      [[noreturn]] static void invalid();
      [[nodiscard]] unsigned digitAt(std::ptrdiff_t position) const noexcept;
      static bool validDigit(char byte, unsigned radix) noexcept;
      void readMantissa(std::string_view text, bool floating_syntax);
      static std::ptrdiff_t exponent(std::string_view text, std::size_t source_bytes);
      void applyExponent(std::ptrdiff_t value);
      void normalize();

      String<Memory> digits_;
      std::ptrdiff_t point_ = 0;
      unsigned radix_ = decimal_radix;
      bool negative_ = false;
    };

    extern template class RadixNumber<Memory>;
    extern template class RadixNumber<ConcurrentMemory>;

  }
}

// Interface: telar_machines/json_unsigned_integer.cppm
export {
  namespace telar::runtime::machines {

    struct JsonUnsignedInteger {
      static constexpr unsigned binary128_significand_bits = 113;
      static constexpr unsigned binary128_minimum_normal_exponent = 16382;
      static constexpr unsigned zero_half_exponent = binary128_minimum_normal_exponent + binary128_significand_bits;
      static constexpr unsigned ordinary_half_exponent = binary128_significand_bits + 1;
      static constexpr unsigned hexadecimal_bits = 4;

      [[nodiscard]] static bool integerSyntax(std::string_view text) noexcept;

      template <std::unsigned_integral Number, Allocator Memory>
      [[nodiscard]] static Number parse(Memory& memory, std::string_view text, bool allow_float = true);

    private:
      [[noreturn]] static void invalid();

      template <Allocator Memory>
      static std::uint32_t rounded(const RadixNumber<Memory>& number, std::uint32_t integral, std::uint32_t maximum);
    };

    // The two half-interval widths rounded() compares against.
    extern template class BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>;
    extern template class BinaryFraction<JsonUnsignedInteger::zero_half_exponent>;

    extern template int RadixNumber<Memory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>&, bool) const noexcept;
    extern template int RadixNumber<Memory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::zero_half_exponent>&, bool) const noexcept;
    extern template int RadixNumber<ConcurrentMemory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::ordinary_half_exponent>&, bool) const noexcept;
    extern template int RadixNumber<ConcurrentMemory>::compareFraction(const BinaryFraction<JsonUnsignedInteger::zero_half_exponent>&, bool) const noexcept;

    extern template std::uint8_t JsonUnsignedInteger::parse<std::uint8_t, Memory>(Memory&, std::string_view, bool);
    extern template std::uint8_t JsonUnsignedInteger::parse<std::uint8_t, ConcurrentMemory>(ConcurrentMemory&, std::string_view, bool);
    extern template std::uint16_t JsonUnsignedInteger::parse<std::uint16_t, Memory>(Memory&, std::string_view, bool);
    extern template std::uint16_t JsonUnsignedInteger::parse<std::uint16_t, ConcurrentMemory>(ConcurrentMemory&, std::string_view, bool);

  }
}

// Interface: telar_machines/profile.cppm
export {
  namespace telar::runtime::machines {

    enum class MachineLogin : std::uint8_t {
      pending,
      done,
      failed,
    };
    enum class MachineAgent : std::uint8_t {
      claude,
      codex,
      pi,
      cursor,
      opencode,
    };

    inline constexpr std::array machine_agents{MachineAgent::claude, MachineAgent::codex, MachineAgent::pi, MachineAgent::cursor, MachineAgent::opencode};
    inline constexpr std::array<std::string_view, machine_agents.size()> machine_agent_names{"claude", "codex", "pi", "cursor", "opencode"};
    inline constexpr auto machine_login_names = std::to_array<std::string_view>({"pending", "done", "failed"});

    struct MachineProfileFields {
      std::string_view label;
      std::string_view destination;
      std::optional<std::string_view> color = std::nullopt;
      bool enabled = true;
      std::optional<std::string_view> program = std::nullopt;
    };

    class MachineProfile {
    public:
      [[nodiscard]] static MachineProfile create(MachineId identity, MachineProfileFields fields);

      [[nodiscard]] MachineId identity() const noexcept;
      [[nodiscard]] std::string_view label() const noexcept;
      [[nodiscard]] std::string_view destination() const noexcept;
      [[nodiscard]] std::optional<std::string_view> color() const noexcept;
      [[nodiscard]] std::optional<std::string_view> program() const noexcept;
      [[nodiscard]] bool enabled() const noexcept;

      void enable(bool enabled) noexcept;
      void relabel(std::string_view label);
      void placeProgram(std::string_view path);
      void recordLogin(MachineAgent agent, std::optional<MachineLogin> login);
      [[nodiscard]] std::optional<MachineLogin> login(MachineAgent agent) const;

    private:
      static std::optional<std::string_view> optional(std::string_view value) noexcept;

      MachineId identity_;
      runtime::FixedText<MachineLimits::label_bytes> label_;
      runtime::FixedText<MachineLimits::destination_bytes> destination_;
      runtime::FixedText<MachineLimits::color_bytes> color_;
      runtime::FixedText<MachineLimits::program_bytes> program_;
      std::array<std::optional<MachineLogin>, machine_agents.size()> logins_{};
      bool enabled_ = true;
    };

  }
}

// Interface: telar_machines/profiles.cppm
export {
  namespace telar::runtime::machines {

    class MachineProfiles {
    public:
      static constexpr std::uint16_t plain_format_version = 1;
      static constexpr std::uint16_t extended_format_version = 2;

      [[nodiscard]] std::span<const MachineProfile> rows() const noexcept;
      [[nodiscard]] std::optional<std::string_view> localLabel() const noexcept;
      void relabelLocal(std::string_view label);
      [[nodiscard]] std::optional<std::size_t> find(std::string_view label) const noexcept;
      [[nodiscard]] std::optional<std::size_t> findDestination(std::string_view destination) const noexcept;
      void add(const MachineProfile& profile);
      void remove(std::string_view label);
      void rename(std::string_view label, std::string_view replacement);
      void enable(std::string_view label, bool enabled);
      void recordLogin(std::string_view label, MachineAgent agent, MachineLogin login);
      void placeProgram(std::string_view label, std::string_view path);
      [[nodiscard]] std::uint16_t version() const;

    private:
      [[nodiscard]] std::size_t require(std::string_view label) const;
      void requireFreeLabel(std::string_view label) const;

      std::array<MachineProfile, MachineLimits::profiles> rows_;
      runtime::FixedText<MachineLimits::label_bytes> local_label_;
      std::size_t length_ = 0;
    };

  }
}

// Interface: telar_machines/profile_codec.cppm
export {
  namespace telar::runtime::machines {

    struct MachineProfileCodec {
      template <Allocator Memory>
      [[nodiscard]] static MachineProfiles parse(Memory& memory, std::string_view source);

      template <Allocator Memory>
      [[nodiscard]] static String<Memory> format(Memory& memory, const MachineProfiles& profiles);

    private:
      static constexpr auto file_fields = std::to_array<std::string_view>({"version", "local_label", "machines"});
      static constexpr auto profile_fields = std::to_array<std::string_view>({"id", "label", "destination", "color", "enabled", "telar_path", "logins"});

      static bool isNull(const runtime::JsonValue& value) noexcept;

      template <Allocator Memory>
      static std::uint16_t readVersion(Memory& memory, const runtime::JsonValue& value, String<Memory>& scratch);

      template <Allocator Memory>
      static void validateOptionalString(const std::optional<runtime::JsonValue>& value, String<Memory>& scratch);

      template <Allocator Memory>
      static MachineLogin readLogin(const runtime::JsonValue& value, String<Memory>& scratch);

      template <Allocator Memory>
      static void validateProfile(Memory& memory, const runtime::JsonValue& value, String<Memory>& scratch);

      template <Allocator Memory>
      static String<Memory> readString(Memory& memory, const runtime::JsonValue& value);

      template <Allocator Memory>
      static MachineProfile readProfile(Memory& memory, const runtime::JsonValue& value);

    public:
      template <Allocator Memory>
      static void appendProfile(String<Memory>& output, const MachineProfile& profile);
    };

    extern template MachineProfiles MachineProfileCodec::parse<Memory>(Memory&, std::string_view);
    extern template MachineProfiles MachineProfileCodec::parse<ConcurrentMemory>(ConcurrentMemory&, std::string_view);
    extern template String<Memory> MachineProfileCodec::format<Memory>(Memory&, const MachineProfiles&);
    extern template String<ConcurrentMemory> MachineProfileCodec::format<ConcurrentMemory>(ConcurrentMemory&, const MachineProfiles&);
    extern template void MachineProfileCodec::appendProfile<Memory>(String<Memory>&, const MachineProfile&);
    extern template void MachineProfileCodec::appendProfile<ConcurrentMemory>(String<ConcurrentMemory>&, const MachineProfile&);

  }
}

// Interface: telar_machines/remote_command.cppm
export {
  namespace telar::runtime::machines {

    class MachineRemoteCommand {
      static constexpr std::string_view discovery_prefix = R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec )";
      static constexpr std::string_view discovery_suffix = " server endpoint'";
      static constexpr std::string_view bridge_prefix = "exec ";
      static constexpr std::string_view bridge_suffix = " server bridge";

    public:
      static constexpr std::size_t max_bytes = discovery_prefix.size() + MachineLimits::program_bytes + discovery_suffix.size();
      using Text = BoundedText<max_bytes>;

      [[nodiscard]] static Text discovery(std::optional<std::string_view> program = std::nullopt);
      [[nodiscard]] static Text bridge(std::optional<std::string_view> program = std::nullopt);

    private:
      static Text format(std::string_view prefix, std::optional<std::string_view> program, std::string_view suffix);
    };

  }
}
