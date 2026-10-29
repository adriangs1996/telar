#pragma once

#include <array>
#include <span>
#include <cstdint>
#include <string_view>

namespace telar::runtime::control {

struct Capability {
  std::string_view name;
  std::string_view value;
  bool has_value;
};

// Capability facts: Ghostty df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137.
// MIT attribution: vendor/ghostty-query-data.LICENSE. Query parsing
// and hex serialization are implemented by Telar. TN follows the child TERM.
inline constexpr auto capabilities = std::to_array<Capability>({
    {"AX", "", false},
    {"BD", "\033[?2004l", true},
    {"BE", "\033[?2004h", true},
    {"Clmg", "\033[s", true},
    {"Cmg", "\134E[%i%p1%d;%p2%ds", true},
    {"Co", "256", true},
    {"Dsmg", "\033[?69l", true},
    {"E3", "\033[3J", true},
    {"Enmg", "\033[?69h", true},
    {"Ms", "\134E]52;%p1%s;%p2%s\134007", true},
    {"PE", "\033[201~", true},
    {"PS", "\033[200~", true},
    {"RGB", "8", true},
    {"RV", "\033[>c", true},
    {"Rmol", "\033[55m", true},
    {"Se", "\033[0 q", true},
    {"Setulc", "\134E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m", true},
    {"Smol", "\033[53m", true},
    {"Smulx", "\134E[4:%p1%dm", true},
    {"Ss", "\134E[%p1%d q", true},
    {"Su", "", false},
    {"Sync", "\134E[?2026%?%p1%{1}%-%tl%eh%;", true},
    {"TN", "xterm-256color", true},
    {"Tc", "", false},
    {"XM", "\134E[?1006;1000%?%p1%{1}%=%th%el%;", true},
    {"XR", "\033[>0q", true},
    {"XT", "", false},
    {"acsc", "++\134,\134,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~", true},
    {"am", "", false},
    {"bce", "", false},
    {"bel", "\007", true},
    {"blink", "\033[5m", true},
    {"bold", "\033[1m", true},
    {"cbt", "\033[Z", true},
    {"ccc", "", false},
    {"civis", "\033[?25l", true},
    {"clear", "\033[H\033[2J", true},
    {"cnorm", "\033[?12l\033[?25h", true},
    {"colors", "256", true},
    {"cols", "80", true},
    {"cr", "\134r", true},
    {"csr", "\134E[%i%p1%d;%p2%dr", true},
    {"cub", "\134E[%p1%dD", true},
    {"cub1", "\010", true},
    {"cud", "\134E[%p1%dB", true},
    {"cud1", "\012", true},
    {"cuf", "\134E[%p1%dC", true},
    {"cuf1", "\033[C", true},
    {"cup", "\134E[%i%p1%d;%p2%dH", true},
    {"cuu", "\134E[%p1%dA", true},
    {"cuu1", "\033[A", true},
    {"cvvis", "\033[?12;25h", true},
    {"dch", "\134E[%p1%dP", true},
    {"dch1", "\033[P", true},
    {"dim", "\033[2m", true},
    {"dl", "\134E[%p1%dM", true},
    {"dl1", "\033[M", true},
    {"dsl", "\033]2;\134007", true},
    {"ech", "\134E[%p1%dX", true},
    {"ed", "\033[J", true},
    {"el", "\033[K", true},
    {"el1", "\033[1K", true},
    {"fd", "\033[?1004l", true},
    {"fe", "\033[?1004h", true},
    {"flash", "\033[?5h$<100/>\033[?5l", true},
    {"fsl", "\007", true},
    {"fullkbd", "", false},
    {"home", "\033[H", true},
    {"hpa", "\134E[%i%p1%dG", true},
    {"hs", "", false},
    {"ht", "\011", true},
    {"hts", "\033H", true},
    {"ich", "\134E[%p1%d@", true},
    {"ich1", "\033[@", true},
    {"il", "\134E[%p1%dL", true},
    {"il1", "\033[L", true},
    {"ind", "\134n", true},
    {"indn", "\134E[%p1%dS", true},
    {"initc", "\134E]4;%p1%d;rgb\134:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\134E\134\134", true},
    {"invis", "\033[8m", true},
    {"it", "8", true},
    {"kDC", "\033[3;2~", true},
    {"kDC3", "\033[3;3~", true},
    {"kDC4", "\033[3;4~", true},
    {"kDC5", "\033[3;5~", true},
    {"kDC6", "\033[3;6~", true},
    {"kDC7", "\033[3;7~", true},
    {"kDN", "\033[1;2B", true},
    {"kDN3", "\033[1;3B", true},
    {"kDN4", "\033[1;4B", true},
    {"kDN5", "\033[1;5B", true},
    {"kDN6", "\033[1;6B", true},
    {"kDN7", "\033[1;7B", true},
    {"kEND", "\033[1;2F", true},
    {"kEND3", "\033[1;3F", true},
    {"kEND4", "\033[1;4F", true},
    {"kEND5", "\033[1;5F", true},
    {"kEND6", "\033[1;6F", true},
    {"kEND7", "\033[1;7F", true},
    {"kHOM", "\033[1;2H", true},
    {"kHOM3", "\033[1;3H", true},
    {"kHOM4", "\033[1;4H", true},
    {"kHOM5", "\033[1;5H", true},
    {"kHOM6", "\033[1;6H", true},
    {"kHOM7", "\033[1;7H", true},
    {"kIC", "\033[2;2~", true},
    {"kIC3", "\033[2;3~", true},
    {"kIC4", "\033[2;4~", true},
    {"kIC5", "\033[2;5~", true},
    {"kIC6", "\033[2;6~", true},
    {"kIC7", "\033[2;7~", true},
    {"kLFT", "\033[1;2D", true},
    {"kLFT3", "\033[1;3D", true},
    {"kLFT4", "\033[1;4D", true},
    {"kLFT5", "\033[1;5D", true},
    {"kLFT6", "\033[1;6D", true},
    {"kLFT7", "\033[1;7D", true},
    {"kNXT", "\033[6;2~", true},
    {"kNXT3", "\033[6;3~", true},
    {"kNXT4", "\033[6;4~", true},
    {"kNXT5", "\033[6;5~", true},
    {"kNXT6", "\033[6;6~", true},
    {"kNXT7", "\033[6;7~", true},
    {"kPRV", "\033[5;2~", true},
    {"kPRV3", "\033[5;3~", true},
    {"kPRV4", "\033[5;4~", true},
    {"kPRV5", "\033[5;5~", true},
    {"kPRV6", "\033[5;6~", true},
    {"kPRV7", "\033[5;7~", true},
    {"kRIT", "\033[1;2C", true},
    {"kRIT3", "\033[1;3C", true},
    {"kRIT4", "\033[1;4C", true},
    {"kRIT5", "\033[1;5C", true},
    {"kRIT6", "\033[1;6C", true},
    {"kRIT7", "\033[1;7C", true},
    {"kUP", "\033[1;2A", true},
    {"kUP3", "\033[1;3A", true},
    {"kUP4", "\033[1;4A", true},
    {"kUP5", "\033[1;5A", true},
    {"kUP6", "\033[1;6A", true},
    {"kUP7", "\033[1;7A", true},
    {"kbs", "\177", true},
    {"kcbt", "\033[Z", true},
    {"kcub1", "\033OD", true},
    {"kcud1", "\033OB", true},
    {"kcuf1", "\033OC", true},
    {"kcuu1", "\033OA", true},
    {"kdch1", "\033[3~", true},
    {"kend", "\033OF", true},
    {"kent", "\033OM", true},
    {"kf1", "\033OP", true},
    {"kf10", "\033[21~", true},
    {"kf11", "\033[23~", true},
    {"kf12", "\033[24~", true},
    {"kf13", "\033[1;2P", true},
    {"kf14", "\033[1;2Q", true},
    {"kf15", "\033[1;2R", true},
    {"kf16", "\033[1;2S", true},
    {"kf17", "\033[15;2~", true},
    {"kf18", "\033[17;2~", true},
    {"kf19", "\033[18;2~", true},
    {"kf2", "\033OQ", true},
    {"kf20", "\033[19;2~", true},
    {"kf21", "\033[20;2~", true},
    {"kf22", "\033[21;2~", true},
    {"kf23", "\033[23;2~", true},
    {"kf24", "\033[24;2~", true},
    {"kf25", "\033[1;5P", true},
    {"kf26", "\033[1;5Q", true},
    {"kf27", "\033[1;5R", true},
    {"kf28", "\033[1;5S", true},
    {"kf29", "\033[15;5~", true},
    {"kf3", "\033OR", true},
    {"kf30", "\033[17;5~", true},
    {"kf31", "\033[18;5~", true},
    {"kf32", "\033[19;5~", true},
    {"kf33", "\033[20;5~", true},
    {"kf34", "\033[21;5~", true},
    {"kf35", "\033[23;5~", true},
    {"kf36", "\033[24;5~", true},
    {"kf37", "\033[1;6P", true},
    {"kf38", "\033[1;6Q", true},
    {"kf39", "\033[1;6R", true},
    {"kf4", "\033OS", true},
    {"kf40", "\033[1;6S", true},
    {"kf41", "\033[15;6~", true},
    {"kf42", "\033[17;6~", true},
    {"kf43", "\033[18;6~", true},
    {"kf44", "\033[19;6~", true},
    {"kf45", "\033[20;6~", true},
    {"kf46", "\033[21;6~", true},
    {"kf47", "\033[23;6~", true},
    {"kf48", "\033[24;6~", true},
    {"kf49", "\033[1;3P", true},
    {"kf5", "\033[15~", true},
    {"kf50", "\033[1;3Q", true},
    {"kf51", "\033[1;3R", true},
    {"kf52", "\033[1;3S", true},
    {"kf53", "\033[15;3~", true},
    {"kf54", "\033[17;3~", true},
    {"kf55", "\033[18;3~", true},
    {"kf56", "\033[19;3~", true},
    {"kf57", "\033[20;3~", true},
    {"kf58", "\033[21;3~", true},
    {"kf59", "\033[23;3~", true},
    {"kf6", "\033[17~", true},
    {"kf60", "\033[24;3~", true},
    {"kf61", "\033[1;4P", true},
    {"kf62", "\033[1;4Q", true},
    {"kf63", "\033[1;4R", true},
    {"kf7", "\033[18~", true},
    {"kf8", "\033[19~", true},
    {"kf9", "\033[20~", true},
    {"khome", "\033OH", true},
    {"kich1", "\033[2~", true},
    {"kind", "\033[1;2B", true},
    {"km", "", false},
    {"kmous", "\033[<", true},
    {"knp", "\033[6~", true},
    {"kpp", "\033[5~", true},
    {"kri", "\033[1;2A", true},
    {"kxIN", "\033[I", true},
    {"kxOUT", "\033[O", true},
    {"lines", "24", true},
    {"mc5i", "", false},
    {"mir", "", false},
    {"msgr", "", false},
    {"npc", "", false},
    {"oc", "\033]104\134007", true},
    {"op", "\033[39;49m", true},
    {"pairs", "32767", true},
    {"rc", "\0338", true},
    {"rep", "%p1%c\134E[%p2%{1}%-%db", true},
    {"rev", "\033[7m", true},
    {"ri", "\033M", true},
    {"rin", "\134E[%p1%dT", true},
    {"ritm", "\033[23m", true},
    {"rmacs", "\033(B", true},
    {"rmam", "\033[?7l", true},
    {"rmcup", "\033[?1049l", true},
    {"rmir", "\033[4l", true},
    {"rmkx", "\033[?1l\033>", true},
    {"rmso", "\033[27m", true},
    {"rmul", "\033[24m", true},
    {"rmxx", "\033[29m", true},
    {"rs1", "\033]\033\134\134\033c", true},
    {"rv", "\033\134\134[[0-9]+;[0-9]+;[0-9]+c", true},
    {"sc", "\0337", true},
    {"setab", "\134E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m", true},
    {"setaf", "\134E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m", true},
    {"setrgbb", "\134E[48:2:%p1%d:%p2%d:%p3%dm", true},
    {"setrgbf", "\134E[38:2:%p1%d:%p2%d:%p3%dm", true},
    {"sgr", "%?%p9%t\134E(0%e\134E(B%;\134E[0%?%p6%t;1%;%?%p5%t;2%;%?%p2%t;4%;%?%p1%p3%|%t;7%;%?%p4%t;5%;%?%p7%t;8%;m", true},
    {"sgr0", "\033(B\033[m", true},
    {"sitm", "\033[3m", true},
    {"smacs", "\033(0", true},
    {"smam", "\033[?7h", true},
    {"smcup", "\033[?1049h", true},
    {"smir", "\033[4h", true},
    {"smkx", "\033[?1h\033=", true},
    {"smso", "\033[7m", true},
    {"smul", "\033[4m", true},
    {"smxx", "\033[9m", true},
    {"tbc", "\033[3g", true},
    {"tsl", "\033]2;", true},
    {"u6", "\134E[%i%d;%dR", true},
    {"u7", "\033[6n", true},
    {"u8", "\134E[?%[;0123456789]c", true},
    {"u9", "\033[c", true},
    {"vpa", "\134E[%i%p1%dd", true},
    {"xenl", "", false},
    {"xm", "\134E[<%i%p3%d;%p1%d;%p2%d;%?%p4%tM%em%;", true},
    {"xr", "\033P>\134\134|[ -~]+a\033\134\134", true},
});

struct EncodedCapability {
  std::array<std::uint8_t, 256> bytes{};
  std::size_t size = 0;

  constexpr std::span<const std::uint8_t> view() const noexcept {
    return std::span<const std::uint8_t>{bytes}.first(size);
  }
};

consteval auto encodeCapabilities() {
  std::array<EncodedCapability, capabilities.size()> result;
  constexpr std::string_view digits = "0123456789ABCDEF";
  for (std::size_t index = 0; index < capabilities.size(); ++index) {
    auto &output = result[index];
    const auto append = [&](std::string_view value, bool hex) {
      for (const auto byte : value) {
        if (hex) {
          output.bytes.at(output.size++) = digits[static_cast<unsigned char>(byte) >> 4];
          output.bytes.at(output.size++) = digits[static_cast<unsigned char>(byte) & 15];
        } else {
          output.bytes.at(output.size++) = byte;
        }
      }
    };
    append("\033P1+r", false);
    append(capabilities[index].name, true);
    if (capabilities[index].has_value) {
      append("=", false);
      append(capabilities[index].value, true);
    }
    append("\033\\", false);
  }
  return result;
}

inline constexpr auto encoded_capabilities = encodeCapabilities();

inline std::span<const std::uint8_t> capability(std::string_view hex) noexcept {
  std::array<char, 32> decoded;
  if (hex.size() % 2 != 0 || hex.size() > decoded.size() * 2) {
    return {};
  }

  const auto digit = [](char value) -> int {
    if (value >= '0' && value <= '9') {
      return value - '0';
    }
    if (value >= 'A' && value <= 'F') {
      return value - 'A' + 10;
    }
    if (value >= 'a' && value <= 'f') {
      return value - 'a' + 10;
    }
    return -1;
  };
  for (std::size_t index = 0; index < hex.size(); index += 2) {
    const auto high = digit(hex[index]);
    const auto low = digit(hex[index + 1]);
    if (high < 0 || low < 0) {
      return {};
    }
    decoded[index / 2] = static_cast<char>(high * 16 + low);
  }

  const std::string_view name{decoded.data(), hex.size() / 2};
  std::size_t first = 0;
  std::size_t last = capabilities.size();
  while (first != last) {
    const auto middle = first + (last - first) / 2;
    if (capabilities[middle].name < name) {
      first = middle + 1;
    } else {
      last = middle;
    }
  }
  return first < capabilities.size() && capabilities[first].name == name ? encoded_capabilities[first].view() : std::span<const std::uint8_t>{};
}

}
