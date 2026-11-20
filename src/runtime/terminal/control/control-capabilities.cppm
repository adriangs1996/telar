export module telar.runtime.terminal.control:capabilities;

import std;
import telar.base.ds;

export namespace telar::runtime::control {

  struct Capability {
    std::string_view name;
    std::string_view value;
    bool has_value;
  };

  // Capability facts: Ghostty df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137.
  // MIT attribution: vendor/ghostty-query-data.LICENSE. Query parsing
  // and hex serialization are implemented by Telar. TN follows the child TERM.
  inline constexpr auto capabilities = ds::Array<Capability, 273>{
      {
          {.name = "AX", .value = "", .has_value = false},
          {.name = "BD", .value = "\033[?2004l", .has_value = true},
          {.name = "BE", .value = "\033[?2004h", .has_value = true},
          {.name = "Clmg", .value = "\033[s", .has_value = true},
          {.name = "Cmg", .value = R"(\E[%i%p1%d;%p2%ds)", .has_value = true},
          {.name = "Co", .value = "256", .has_value = true},
          {.name = "Dsmg", .value = "\033[?69l", .has_value = true},
          {.name = "E3", .value = "\033[3J", .has_value = true},
          {.name = "Enmg", .value = "\033[?69h", .has_value = true},
          {.name = "Ms", .value = R"(\E]52;%p1%s;%p2%s\007)", .has_value = true},
          {.name = "PE", .value = "\033[201~", .has_value = true},
          {.name = "PS", .value = "\033[200~", .has_value = true},
          {.name = "RGB", .value = "8", .has_value = true},
          {.name = "RV", .value = "\033[>c", .has_value = true},
          {.name = "Rmol", .value = "\033[55m", .has_value = true},
          {.name = "Se", .value = "\033[0 q", .has_value = true},
          {.name = "Setulc", .value = R"(\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m)", .has_value = true},
          {.name = "Smol", .value = "\033[53m", .has_value = true},
          {.name = "Smulx", .value = R"(\E[4:%p1%dm)", .has_value = true},
          {.name = "Ss", .value = R"(\E[%p1%d q)", .has_value = true},
          {.name = "Su", .value = "", .has_value = false},
          {.name = "Sync", .value = R"(\E[?2026%?%p1%{1}%-%tl%eh%;)", .has_value = true},
          {.name = "TN", .value = "xterm-256color", .has_value = true},
          {.name = "Tc", .value = "", .has_value = false},
          {.name = "XM", .value = R"(\E[?1006;1000%?%p1%{1}%=%th%el%;)", .has_value = true},
          {.name = "XR", .value = "\033[>0q", .has_value = true},
          {.name = "XT", .value = "", .has_value = false},
          {.name = "acsc", .value = R"(++\,\,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~)", .has_value = true},
          {.name = "am", .value = "", .has_value = false},
          {.name = "bce", .value = "", .has_value = false},
          {.name = "bel", .value = "\007", .has_value = true},
          {.name = "blink", .value = "\033[5m", .has_value = true},
          {.name = "bold", .value = "\033[1m", .has_value = true},
          {.name = "cbt", .value = "\033[Z", .has_value = true},
          {.name = "ccc", .value = "", .has_value = false},
          {.name = "civis", .value = "\033[?25l", .has_value = true},
          {.name = "clear", .value = "\033[H\033[2J", .has_value = true},
          {.name = "cnorm", .value = "\033[?12l\033[?25h", .has_value = true},
          {.name = "colors", .value = "256", .has_value = true},
          {.name = "cols", .value = "80", .has_value = true},
          {.name = "cr", .value = R"(\r)", .has_value = true},
          {.name = "csr", .value = R"(\E[%i%p1%d;%p2%dr)", .has_value = true},
          {.name = "cub", .value = R"(\E[%p1%dD)", .has_value = true},
          {.name = "cub1", .value = "\010", .has_value = true},
          {.name = "cud", .value = R"(\E[%p1%dB)", .has_value = true},
          {.name = "cud1", .value = "\012", .has_value = true},
          {.name = "cuf", .value = R"(\E[%p1%dC)", .has_value = true},
          {.name = "cuf1", .value = "\033[C", .has_value = true},
          {.name = "cup", .value = R"(\E[%i%p1%d;%p2%dH)", .has_value = true},
          {.name = "cuu", .value = R"(\E[%p1%dA)", .has_value = true},
          {.name = "cuu1", .value = "\033[A", .has_value = true},
          {.name = "cvvis", .value = "\033[?12;25h", .has_value = true},
          {.name = "dch", .value = R"(\E[%p1%dP)", .has_value = true},
          {.name = "dch1", .value = "\033[P", .has_value = true},
          {.name = "dim", .value = "\033[2m", .has_value = true},
          {.name = "dl", .value = R"(\E[%p1%dM)", .has_value = true},
          {.name = "dl1", .value = "\033[M", .has_value = true},
          {.name = "dsl", .value = "\033]2;\134007", .has_value = true},
          {.name = "ech", .value = R"(\E[%p1%dX)", .has_value = true},
          {.name = "ed", .value = "\033[J", .has_value = true},
          {.name = "el", .value = "\033[K", .has_value = true},
          {.name = "el1", .value = "\033[1K", .has_value = true},
          {.name = "fd", .value = "\033[?1004l", .has_value = true},
          {.name = "fe", .value = "\033[?1004h", .has_value = true},
          {.name = "flash", .value = "\033[?5h$<100/>\033[?5l", .has_value = true},
          {.name = "fsl", .value = "\007", .has_value = true},
          {.name = "fullkbd", .value = "", .has_value = false},
          {.name = "home", .value = "\033[H", .has_value = true},
          {.name = "hpa", .value = R"(\E[%i%p1%dG)", .has_value = true},
          {.name = "hs", .value = "", .has_value = false},
          {.name = "ht", .value = "\011", .has_value = true},
          {.name = "hts", .value = "\033H", .has_value = true},
          {.name = "ich", .value = R"(\E[%p1%d@)", .has_value = true},
          {.name = "ich1", .value = "\033[@", .has_value = true},
          {.name = "il", .value = R"(\E[%p1%dL)", .has_value = true},
          {.name = "il1", .value = "\033[L", .has_value = true},
          {.name = "ind", .value = R"(\n)", .has_value = true},
          {.name = "indn", .value = R"(\E[%p1%dS)", .has_value = true},
          {.name = "initc", .value = R"(\E]4;%p1%d;rgb\:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\E\\)", .has_value = true},
          {.name = "invis", .value = "\033[8m", .has_value = true},
          {.name = "it", .value = "8", .has_value = true},
          {.name = "kDC", .value = "\033[3;2~", .has_value = true},
          {.name = "kDC3", .value = "\033[3;3~", .has_value = true},
          {.name = "kDC4", .value = "\033[3;4~", .has_value = true},
          {.name = "kDC5", .value = "\033[3;5~", .has_value = true},
          {.name = "kDC6", .value = "\033[3;6~", .has_value = true},
          {.name = "kDC7", .value = "\033[3;7~", .has_value = true},
          {.name = "kDN", .value = "\033[1;2B", .has_value = true},
          {.name = "kDN3", .value = "\033[1;3B", .has_value = true},
          {.name = "kDN4", .value = "\033[1;4B", .has_value = true},
          {.name = "kDN5", .value = "\033[1;5B", .has_value = true},
          {.name = "kDN6", .value = "\033[1;6B", .has_value = true},
          {.name = "kDN7", .value = "\033[1;7B", .has_value = true},
          {.name = "kEND", .value = "\033[1;2F", .has_value = true},
          {.name = "kEND3", .value = "\033[1;3F", .has_value = true},
          {.name = "kEND4", .value = "\033[1;4F", .has_value = true},
          {.name = "kEND5", .value = "\033[1;5F", .has_value = true},
          {.name = "kEND6", .value = "\033[1;6F", .has_value = true},
          {.name = "kEND7", .value = "\033[1;7F", .has_value = true},
          {.name = "kHOM", .value = "\033[1;2H", .has_value = true},
          {.name = "kHOM3", .value = "\033[1;3H", .has_value = true},
          {.name = "kHOM4", .value = "\033[1;4H", .has_value = true},
          {.name = "kHOM5", .value = "\033[1;5H", .has_value = true},
          {.name = "kHOM6", .value = "\033[1;6H", .has_value = true},
          {.name = "kHOM7", .value = "\033[1;7H", .has_value = true},
          {.name = "kIC", .value = "\033[2;2~", .has_value = true},
          {.name = "kIC3", .value = "\033[2;3~", .has_value = true},
          {.name = "kIC4", .value = "\033[2;4~", .has_value = true},
          {.name = "kIC5", .value = "\033[2;5~", .has_value = true},
          {.name = "kIC6", .value = "\033[2;6~", .has_value = true},
          {.name = "kIC7", .value = "\033[2;7~", .has_value = true},
          {.name = "kLFT", .value = "\033[1;2D", .has_value = true},
          {.name = "kLFT3", .value = "\033[1;3D", .has_value = true},
          {.name = "kLFT4", .value = "\033[1;4D", .has_value = true},
          {.name = "kLFT5", .value = "\033[1;5D", .has_value = true},
          {.name = "kLFT6", .value = "\033[1;6D", .has_value = true},
          {.name = "kLFT7", .value = "\033[1;7D", .has_value = true},
          {.name = "kNXT", .value = "\033[6;2~", .has_value = true},
          {.name = "kNXT3", .value = "\033[6;3~", .has_value = true},
          {.name = "kNXT4", .value = "\033[6;4~", .has_value = true},
          {.name = "kNXT5", .value = "\033[6;5~", .has_value = true},
          {.name = "kNXT6", .value = "\033[6;6~", .has_value = true},
          {.name = "kNXT7", .value = "\033[6;7~", .has_value = true},
          {.name = "kPRV", .value = "\033[5;2~", .has_value = true},
          {.name = "kPRV3", .value = "\033[5;3~", .has_value = true},
          {.name = "kPRV4", .value = "\033[5;4~", .has_value = true},
          {.name = "kPRV5", .value = "\033[5;5~", .has_value = true},
          {.name = "kPRV6", .value = "\033[5;6~", .has_value = true},
          {.name = "kPRV7", .value = "\033[5;7~", .has_value = true},
          {.name = "kRIT", .value = "\033[1;2C", .has_value = true},
          {.name = "kRIT3", .value = "\033[1;3C", .has_value = true},
          {.name = "kRIT4", .value = "\033[1;4C", .has_value = true},
          {.name = "kRIT5", .value = "\033[1;5C", .has_value = true},
          {.name = "kRIT6", .value = "\033[1;6C", .has_value = true},
          {.name = "kRIT7", .value = "\033[1;7C", .has_value = true},
          {.name = "kUP", .value = "\033[1;2A", .has_value = true},
          {.name = "kUP3", .value = "\033[1;3A", .has_value = true},
          {.name = "kUP4", .value = "\033[1;4A", .has_value = true},
          {.name = "kUP5", .value = "\033[1;5A", .has_value = true},
          {.name = "kUP6", .value = "\033[1;6A", .has_value = true},
          {.name = "kUP7", .value = "\033[1;7A", .has_value = true},
          {.name = "kbs", .value = "\177", .has_value = true},
          {.name = "kcbt", .value = "\033[Z", .has_value = true},
          {.name = "kcub1", .value = "\033OD", .has_value = true},
          {.name = "kcud1", .value = "\033OB", .has_value = true},
          {.name = "kcuf1", .value = "\033OC", .has_value = true},
          {.name = "kcuu1", .value = "\033OA", .has_value = true},
          {.name = "kdch1", .value = "\033[3~", .has_value = true},
          {.name = "kend", .value = "\033OF", .has_value = true},
          {.name = "kent", .value = "\033OM", .has_value = true},
          {.name = "kf1", .value = "\033OP", .has_value = true},
          {.name = "kf10", .value = "\033[21~", .has_value = true},
          {.name = "kf11", .value = "\033[23~", .has_value = true},
          {.name = "kf12", .value = "\033[24~", .has_value = true},
          {.name = "kf13", .value = "\033[1;2P", .has_value = true},
          {.name = "kf14", .value = "\033[1;2Q", .has_value = true},
          {.name = "kf15", .value = "\033[1;2R", .has_value = true},
          {.name = "kf16", .value = "\033[1;2S", .has_value = true},
          {.name = "kf17", .value = "\033[15;2~", .has_value = true},
          {.name = "kf18", .value = "\033[17;2~", .has_value = true},
          {.name = "kf19", .value = "\033[18;2~", .has_value = true},
          {.name = "kf2", .value = "\033OQ", .has_value = true},
          {.name = "kf20", .value = "\033[19;2~", .has_value = true},
          {.name = "kf21", .value = "\033[20;2~", .has_value = true},
          {.name = "kf22", .value = "\033[21;2~", .has_value = true},
          {.name = "kf23", .value = "\033[23;2~", .has_value = true},
          {.name = "kf24", .value = "\033[24;2~", .has_value = true},
          {.name = "kf25", .value = "\033[1;5P", .has_value = true},
          {.name = "kf26", .value = "\033[1;5Q", .has_value = true},
          {.name = "kf27", .value = "\033[1;5R", .has_value = true},
          {.name = "kf28", .value = "\033[1;5S", .has_value = true},
          {.name = "kf29", .value = "\033[15;5~", .has_value = true},
          {.name = "kf3", .value = "\033OR", .has_value = true},
          {.name = "kf30", .value = "\033[17;5~", .has_value = true},
          {.name = "kf31", .value = "\033[18;5~", .has_value = true},
          {.name = "kf32", .value = "\033[19;5~", .has_value = true},
          {.name = "kf33", .value = "\033[20;5~", .has_value = true},
          {.name = "kf34", .value = "\033[21;5~", .has_value = true},
          {.name = "kf35", .value = "\033[23;5~", .has_value = true},
          {.name = "kf36", .value = "\033[24;5~", .has_value = true},
          {.name = "kf37", .value = "\033[1;6P", .has_value = true},
          {.name = "kf38", .value = "\033[1;6Q", .has_value = true},
          {.name = "kf39", .value = "\033[1;6R", .has_value = true},
          {.name = "kf4", .value = "\033OS", .has_value = true},
          {.name = "kf40", .value = "\033[1;6S", .has_value = true},
          {.name = "kf41", .value = "\033[15;6~", .has_value = true},
          {.name = "kf42", .value = "\033[17;6~", .has_value = true},
          {.name = "kf43", .value = "\033[18;6~", .has_value = true},
          {.name = "kf44", .value = "\033[19;6~", .has_value = true},
          {.name = "kf45", .value = "\033[20;6~", .has_value = true},
          {.name = "kf46", .value = "\033[21;6~", .has_value = true},
          {.name = "kf47", .value = "\033[23;6~", .has_value = true},
          {.name = "kf48", .value = "\033[24;6~", .has_value = true},
          {.name = "kf49", .value = "\033[1;3P", .has_value = true},
          {.name = "kf5", .value = "\033[15~", .has_value = true},
          {.name = "kf50", .value = "\033[1;3Q", .has_value = true},
          {.name = "kf51", .value = "\033[1;3R", .has_value = true},
          {.name = "kf52", .value = "\033[1;3S", .has_value = true},
          {.name = "kf53", .value = "\033[15;3~", .has_value = true},
          {.name = "kf54", .value = "\033[17;3~", .has_value = true},
          {.name = "kf55", .value = "\033[18;3~", .has_value = true},
          {.name = "kf56", .value = "\033[19;3~", .has_value = true},
          {.name = "kf57", .value = "\033[20;3~", .has_value = true},
          {.name = "kf58", .value = "\033[21;3~", .has_value = true},
          {.name = "kf59", .value = "\033[23;3~", .has_value = true},
          {.name = "kf6", .value = "\033[17~", .has_value = true},
          {.name = "kf60", .value = "\033[24;3~", .has_value = true},
          {.name = "kf61", .value = "\033[1;4P", .has_value = true},
          {.name = "kf62", .value = "\033[1;4Q", .has_value = true},
          {.name = "kf63", .value = "\033[1;4R", .has_value = true},
          {.name = "kf7", .value = "\033[18~", .has_value = true},
          {.name = "kf8", .value = "\033[19~", .has_value = true},
          {.name = "kf9", .value = "\033[20~", .has_value = true},
          {.name = "khome", .value = "\033OH", .has_value = true},
          {.name = "kich1", .value = "\033[2~", .has_value = true},
          {.name = "kind", .value = "\033[1;2B", .has_value = true},
          {.name = "km", .value = "", .has_value = false},
          {.name = "kmous", .value = "\033[<", .has_value = true},
          {.name = "knp", .value = "\033[6~", .has_value = true},
          {.name = "kpp", .value = "\033[5~", .has_value = true},
          {.name = "kri", .value = "\033[1;2A", .has_value = true},
          {.name = "kxIN", .value = "\033[I", .has_value = true},
          {.name = "kxOUT", .value = "\033[O", .has_value = true},
          {.name = "lines", .value = "24", .has_value = true},
          {.name = "mc5i", .value = "", .has_value = false},
          {.name = "mir", .value = "", .has_value = false},
          {.name = "msgr", .value = "", .has_value = false},
          {.name = "npc", .value = "", .has_value = false},
          {.name = "oc", .value = "\033]104\134007", .has_value = true},
          {.name = "op", .value = "\033[39;49m", .has_value = true},
          {.name = "pairs", .value = "32767", .has_value = true},
          {.name = "rc", .value = "\0338", .has_value = true},
          {.name = "rep", .value = R"(%p1%c\E[%p2%{1}%-%db)", .has_value = true},
          {.name = "rev", .value = "\033[7m", .has_value = true},
          {.name = "ri", .value = "\033M", .has_value = true},
          {.name = "rin", .value = R"(\E[%p1%dT)", .has_value = true},
          {.name = "ritm", .value = "\033[23m", .has_value = true},
          {.name = "rmacs", .value = "\033(B", .has_value = true},
          {.name = "rmam", .value = "\033[?7l", .has_value = true},
          {.name = "rmcup", .value = "\033[?1049l", .has_value = true},
          {.name = "rmir", .value = "\033[4l", .has_value = true},
          {.name = "rmkx", .value = "\033[?1l\033>", .has_value = true},
          {.name = "rmso", .value = "\033[27m", .has_value = true},
          {.name = "rmul", .value = "\033[24m", .has_value = true},
          {.name = "rmxx", .value = "\033[29m", .has_value = true},
          {.name = "rs1", .value = "\033]\033\134\134\033c", .has_value = true},
          {.name = "rv", .value = "\033\134\134[[0-9]+;[0-9]+;[0-9]+c", .has_value = true},
          {.name = "sc", .value = "\0337", .has_value = true},
          {.name = "setab", .value = R"(\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m)", .has_value = true},
          {.name = "setaf", .value = R"(\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m)", .has_value = true},
          {.name = "setrgbb", .value = R"(\E[48:2:%p1%d:%p2%d:%p3%dm)", .has_value = true},
          {.name = "setrgbf", .value = R"(\E[38:2:%p1%d:%p2%d:%p3%dm)", .has_value = true},
          {.name = "sgr", .value = R"(%?%p9%t\E(0%e\E(B%;\E[0%?%p6%t;1%;%?%p5%t;2%;%?%p2%t;4%;%?%p1%p3%|%t;7%;%?%p4%t;5%;%?%p7%t;8%;m)", .has_value = true},
          {.name = "sgr0", .value = "\033(B\033[m", .has_value = true},
          {.name = "sitm", .value = "\033[3m", .has_value = true},
          {.name = "smacs", .value = "\033(0", .has_value = true},
          {.name = "smam", .value = "\033[?7h", .has_value = true},
          {.name = "smcup", .value = "\033[?1049h", .has_value = true},
          {.name = "smir", .value = "\033[4h", .has_value = true},
          {.name = "smkx", .value = "\033[?1h\033=", .has_value = true},
          {.name = "smso", .value = "\033[7m", .has_value = true},
          {.name = "smul", .value = "\033[4m", .has_value = true},
          {.name = "smxx", .value = "\033[9m", .has_value = true},
          {.name = "tbc", .value = "\033[3g", .has_value = true},
          {.name = "tsl", .value = "\033]2;", .has_value = true},
          {.name = "u6", .value = R"(\E[%i%d;%dR)", .has_value = true},
          {.name = "u7", .value = "\033[6n", .has_value = true},
          {.name = "u8", .value = R"(\E[?%[;0123456789]c)", .has_value = true},
          {.name = "u9", .value = "\033[c", .has_value = true},
          {.name = "vpa", .value = R"(\E[%i%p1%dd)", .has_value = true},
          {.name = "xenl", .value = "", .has_value = false},
          {.name = "xm", .value = R"(\E[<%i%p3%d;%p1%d;%p2%d;%?%p4%tM%em%;)", .has_value = true},
          {.name = "xr", .value = "\033P>\134\134|[ -~]+a\033\134\134", .has_value = true},
      },
  };

  struct EncodedCapability {
    static constexpr std::size_t maximum_bytes = 256;
    ds::Array<std::uint8_t, maximum_bytes> bytes{};
    std::size_t size = 0;

    [[nodiscard]] constexpr std::span<const std::uint8_t> view() const noexcept {
      return std::span<const std::uint8_t>{bytes}.first(size);
    }

    // Appends text as it is, or spelled in uppercase hexadecimal digits.
    constexpr void append(std::string_view value, bool hex) {
      constexpr std::string_view digits = "0123456789ABCDEF";
      constexpr unsigned low_nibble = 0x0f;

      for (const auto byte : value) {
        const auto code = static_cast<unsigned char>(byte);

        if (hex) {
          bytes.atCheckedMut(size++) = static_cast<std::uint8_t>(digits[code >> 4U]);
          bytes.atCheckedMut(size++) = static_cast<std::uint8_t>(digits[code & low_nibble]);
        } else {
          bytes.atCheckedMut(size++) = code;
        }
      }
    }
  };

  consteval auto encodeCapabilities() {
    ds::Array<EncodedCapability, capabilities.size()> result;

    for (std::size_t index = 0; index < capabilities.size(); ++index) {
      auto& output = result.atMut(index);

      output.append("\033P1+r", false);
      output.append(capabilities[index].name, true);
      if (capabilities[index].has_value) {
        output.append("=", false);
        output.append(capabilities[index].value, true);
      }

      output.append("\033\\", false);
    }

    return result;
  }

  inline constexpr auto encoded_capabilities = encodeCapabilities();

  std::span<const std::uint8_t> capability(std::string_view hex) noexcept;

}
