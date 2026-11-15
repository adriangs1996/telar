export module telar.gui.config.gui_query;

import std;
import telar.tbc;

import telar.gui.presentation.client_view_state;
import telar.gui.core.metrics;
import telar.gui.core.json_writer;

import telar.config.gui;
import telar.gui.input.copy_pointer;
import telar.wire.vocabulary;

// Interface: config/query.cppm
export {
  namespace telar::gui {

    struct ConfigurationQuery {
      static constexpr std::size_t capacity = 4096;

      enum class Section : std::uint8_t {
        client,
        theme,
        gui,
        input,
        runtime,
        binding,
      };

      Section section = Section::client;
      std::int64_t index = 0;

      static constexpr auto sections = std::to_array<std::pair<std::string_view, Section>>({
          {"client", Section::client},
          {"theme", Section::theme},
          {"gui", Section::gui},
          {"input", Section::input},
          {"runtime", Section::runtime},
          {"binding", Section::binding},
      });

      [[nodiscard]] static ConfigurationQuery parse(std::string_view name, std::int64_t index);
    };

  }
}

// Interface: config/client_query.cppm
export {
  namespace telar::gui {

    struct ClientQueryContext {
      std::optional<std::string_view> source;
      std::optional<std::string_view> profile;
      std::uint64_t generation = 0;
      ClientViewState view;
    };

    class ClientQuery {
    public:
      // Each query is written into the output, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const Configuration& configuration, const ClientQueryContext& context, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void writeOptionalBytes(JsonWriter& writer, std::optional<std::string_view> text);
      static void writeSound(JsonWriter& writer, SoundPolicy policy);
      static void writeSections(JsonWriter& writer);
    };

  }
}

// Interface: config/gui_query.cppm
export {
  namespace telar::gui {

    class GuiQuery {
    public:
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const Configuration& configuration, tbc::view<std::span<char>, tbc::lt::a> output, bool default_titlebar);

    private:
      static void writeFont(JsonWriter& writer, const FontConfiguration& font);
      static void writeWindow(JsonWriter& writer, const Configuration& configuration, bool default_titlebar);

      // CursorShape leads with the terminal's default, which a configuration cannot choose.
      static std::string_view cursorStyle(CursorShape cursor);
    };

  }
}

// Interface: config/palette_actions.cppm
export {
  namespace telar::gui {

    struct PaletteAction {
      BindingActionKind action;
      std::string_view label;
    };

    inline constexpr auto palette_actions = std::to_array<PaletteAction>({
        {.action = BindingActionKind::split_horizontal, .label = "Split right"},
        {.action = BindingActionKind::split_vertical, .label = "Split down"},
        {.action = BindingActionKind::focus_left, .label = "Focus pane left"},
        {.action = BindingActionKind::focus_right, .label = "Focus pane right"},
        {.action = BindingActionKind::focus_up, .label = "Focus pane up"},
        {.action = BindingActionKind::focus_down, .label = "Focus pane down"},
        {.action = BindingActionKind::toggle_pane_fullscreen, .label = "Toggle pane fullscreen"},
        {.action = BindingActionKind::close_pane, .label = "Close pane"},
        {.action = BindingActionKind::new_tab, .label = "New tab"},
        {.action = BindingActionKind::rename_tab, .label = "Rename tab"},
        {.action = BindingActionKind::close_tab, .label = "Close tab"},
        {.action = BindingActionKind::next_tab, .label = "Next tab"},
        {.action = BindingActionKind::previous_tab, .label = "Previous tab"},
        {.action = BindingActionKind::move_tab_previous, .label = "Move tab left"},
        {.action = BindingActionKind::move_tab_next, .label = "Move tab right"},
        {.action = BindingActionKind::new_workspace, .label = "New context"},
        {.action = BindingActionKind::rename_workspace, .label = "Rename context"},
        {.action = BindingActionKind::toggle_sidebar, .label = "Toggle sidebar"},
        {.action = BindingActionKind::toggle_workspace_list, .label = "Toggle context list"},
        {.action = BindingActionKind::leave_worktree, .label = "Leave worktree for its project"},
        {.action = BindingActionKind::forget_gone_worktrees, .label = "Forget gone worktrees"},
        {.action = BindingActionKind::copy_mode, .label = "Enter copy mode"},
        {.action = BindingActionKind::history_palette, .label = "Search command history"},
        {.action = BindingActionKind::suggest_command, .label = "Suggest a command…"},
        {.action = BindingActionKind::path_picker, .label = "Insert a path"},
        {.action = BindingActionKind::machine_picker, .label = "Switch machine"},
        {.action = BindingActionKind::next_machine, .label = "Next machine"},
        {.action = BindingActionKind::previous_machine, .label = "Previous machine"},
        {.action = BindingActionKind::add_machine, .label = "Add machine"},
    });

  }
}

// Interface: config/theme_presets.cppm
export {
  namespace telar::gui {

    struct ThemePreset {
      std::string_view name;
      ThemeValues values;
    };

    inline constexpr std::array<ThemePreset, 10> theme_presets{{
        {
            "shade",
            {
                .base = ThemeName::shade,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {136, 192, 208}},
                    {},
                    {.kind = CellColor::Kind::rgb, .channels = {36, 41, 51}},
                    {.kind = CellColor::Kind::rgb, .channels = {59, 66, 82}},
                    {.kind = CellColor::Kind::rgb, .channels = {28, 31, 37}},
                    {.kind = CellColor::Kind::rgb, .channels = {76, 86, 106}},
                    {.kind = CellColor::Kind::rgb, .channels = {97, 110, 136}},
                    {.kind = CellColor::Kind::rgb, .channels = {216, 222, 233}},
                    {.kind = CellColor::Kind::rgb, .channels = {123, 136, 161}},
                    {.kind = CellColor::Kind::rgb, .channels = {180, 142, 173}},
                    {.kind = CellColor::Kind::rgb, .channels = {163, 190, 140}},
                    {.kind = CellColor::Kind::rgb, .channels = {235, 203, 139}},
                    {.kind = CellColor::Kind::rgb, .channels = {191, 97, 106}},
                    {.kind = CellColor::Kind::rgb, .channels = {129, 161, 193}},
                    {.kind = CellColor::Kind::rgb, .channels = {143, 188, 187}},
                    {.kind = CellColor::Kind::rgb, .channels = {136, 192, 208}},
                }},
                .terminal = {
                    .foreground = {216, 222, 233},
                    .background = {25, 28, 34},
                    .cursor_color = ThemeRgb{216, 222, 233},
                    .cursor_text_color = ThemeRgb{25, 28, 34},
                    .palette = {{
                        {59, 66, 82},
                        {191, 97, 106},
                        {163, 190, 140},
                        {235, 203, 139},
                        {129, 161, 193},
                        {180, 142, 173},
                        {136, 192, 208},
                        {229, 233, 240},
                        {97, 110, 136},
                        {191, 97, 106},
                        {163, 190, 140},
                        {235, 203, 139},
                        {129, 161, 193},
                        {180, 142, 173},
                        {143, 188, 187},
                        {236, 239, 244},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {216, 222, 233}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {129, 161, 193}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {163, 190, 140}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {180, 142, 173}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {97, 110, 136}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {208, 135, 112}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {208, 135, 112}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {136, 192, 208}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {136, 192, 208}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {143, 188, 187}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {216, 222, 233}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {235, 203, 139}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {216, 222, 233}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {129, 161, 193}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {236, 239, 244}}, .italic = false},
                }},
            },
        },
        {
            "vesper",
            {
                .base = ThemeName::vesper,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {255, 199, 153}},
                    {.kind = CellColor::Kind::rgb, .channels = {26, 26, 26}},
                    {.kind = CellColor::Kind::rgb, .channels = {35, 35, 35}},
                    {.kind = CellColor::Kind::rgb, .channels = {40, 40, 40}},
                    {.kind = CellColor::Kind::rgb, .channels = {16, 16, 16}},
                    {.kind = CellColor::Kind::rgb, .channels = {92, 92, 92}},
                    {.kind = CellColor::Kind::rgb, .channels = {126, 126, 126}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 255, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {160, 160, 160}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 209, 168}},
                    {.kind = CellColor::Kind::rgb, .channels = {153, 255, 228}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 199, 153}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 128, 128}},
                    {.kind = CellColor::Kind::rgb, .channels = {176, 176, 176}},
                    {.kind = CellColor::Kind::rgb, .channels = {102, 221, 204}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 199, 153}},
                }},
                .terminal = {
                    .foreground = {255, 255, 255},
                    .background = {16, 16, 16},
                    .cursor_color = ThemeRgb{255, 199, 153},
                    .cursor_text_color = std::nullopt,
                    .palette = {{
                        {16, 16, 16},
                        {245, 161, 145},
                        {144, 185, 159},
                        {230, 185, 157},
                        {172, 161, 207},
                        {226, 158, 202},
                        {234, 131, 165},
                        {160, 160, 160},
                        {126, 126, 126},
                        {255, 128, 128},
                        {153, 255, 228},
                        {255, 199, 153},
                        {185, 174, 218},
                        {236, 170, 214},
                        {245, 145, 178},
                        {255, 255, 255},
                    }},
                },
                .syntax_styles = {{
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                }},
            },
        },
        {
            "catppuccin",
            {
                .base = ThemeName::catppuccin,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {137, 180, 250}},
                    {.kind = CellColor::Kind::rgb, .channels = {24, 24, 37}},
                    {.kind = CellColor::Kind::rgb, .channels = {49, 50, 68}},
                    {.kind = CellColor::Kind::rgb, .channels = {69, 71, 90}},
                    {.kind = CellColor::Kind::rgb, .channels = {30, 30, 46}},
                    {.kind = CellColor::Kind::rgb, .channels = {108, 112, 134}},
                    {.kind = CellColor::Kind::rgb, .channels = {127, 132, 156}},
                    {.kind = CellColor::Kind::rgb, .channels = {205, 214, 244}},
                    {.kind = CellColor::Kind::rgb, .channels = {166, 173, 200}},
                    {.kind = CellColor::Kind::rgb, .channels = {203, 166, 247}},
                    {.kind = CellColor::Kind::rgb, .channels = {166, 227, 161}},
                    {.kind = CellColor::Kind::rgb, .channels = {249, 226, 175}},
                    {.kind = CellColor::Kind::rgb, .channels = {243, 139, 168}},
                    {.kind = CellColor::Kind::rgb, .channels = {137, 180, 250}},
                    {.kind = CellColor::Kind::rgb, .channels = {148, 226, 213}},
                    {.kind = CellColor::Kind::rgb, .channels = {250, 179, 135}},
                }},
                .terminal = {
                    .foreground = {205, 214, 244},
                    .background = {30, 30, 46},
                    .cursor_color = ThemeRgb{245, 224, 220},
                    .cursor_text_color = ThemeRgb{17, 17, 27},
                    .palette = {{
                        {69, 71, 90},
                        {243, 139, 168},
                        {166, 227, 161},
                        {249, 226, 175},
                        {137, 180, 250},
                        {245, 194, 231},
                        {148, 226, 213},
                        {166, 173, 200},
                        {88, 91, 112},
                        {243, 139, 168},
                        {166, 227, 161},
                        {249, 226, 175},
                        {137, 180, 250},
                        {245, 194, 231},
                        {148, 226, 213},
                        {186, 194, 222},
                    }},
                },
                .syntax_styles = {{
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                }},
            },
        },
        {
            "tokyo-night",
            {
                .base = ThemeName::tokyo_night,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {122, 162, 247}},
                    {.kind = CellColor::Kind::rgb, .channels = {26, 27, 38}},
                    {.kind = CellColor::Kind::rgb, .channels = {36, 40, 59}},
                    {.kind = CellColor::Kind::rgb, .channels = {65, 72, 104}},
                    {.kind = CellColor::Kind::rgb, .channels = {26, 27, 38}},
                    {.kind = CellColor::Kind::rgb, .channels = {86, 95, 137}},
                    {.kind = CellColor::Kind::rgb, .channels = {105, 113, 150}},
                    {.kind = CellColor::Kind::rgb, .channels = {192, 202, 245}},
                    {.kind = CellColor::Kind::rgb, .channels = {169, 177, 214}},
                    {.kind = CellColor::Kind::rgb, .channels = {187, 154, 247}},
                    {.kind = CellColor::Kind::rgb, .channels = {158, 206, 106}},
                    {.kind = CellColor::Kind::rgb, .channels = {224, 175, 104}},
                    {.kind = CellColor::Kind::rgb, .channels = {247, 118, 142}},
                    {.kind = CellColor::Kind::rgb, .channels = {122, 162, 247}},
                    {.kind = CellColor::Kind::rgb, .channels = {125, 207, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 158, 100}},
                }},
                .terminal = {
                    .foreground = {192, 202, 245},
                    .background = {26, 27, 38},
                    .cursor_color = ThemeRgb{192, 202, 245},
                    .cursor_text_color = std::nullopt,
                    .palette = {{
                        {21, 22, 30},
                        {247, 118, 142},
                        {158, 206, 106},
                        {224, 175, 104},
                        {122, 162, 247},
                        {187, 154, 247},
                        {125, 207, 255},
                        {169, 177, 214},
                        {65, 72, 104},
                        {255, 137, 157},
                        {159, 224, 68},
                        {250, 186, 74},
                        {141, 176, 255},
                        {199, 169, 255},
                        {164, 218, 255},
                        {192, 202, 245},
                    }},
                },
                .syntax_styles = {{
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                }},
            },
        },
        {
            "pierre-dark",
            {
                .base = ThemeName::pierre_dark,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {0, 159, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {16, 16, 16}},
                    {.kind = CellColor::Kind::rgb, .channels = {29, 29, 29}},
                    {.kind = CellColor::Kind::rgb, .channels = {38, 38, 38}},
                    {.kind = CellColor::Kind::rgb, .channels = {10, 10, 10}},
                    {.kind = CellColor::Kind::rgb, .channels = {99, 99, 99}},
                    {.kind = CellColor::Kind::rgb, .channels = {115, 115, 115}},
                    {.kind = CellColor::Kind::rgb, .channels = {229, 229, 229}},
                    {.kind = CellColor::Kind::rgb, .channels = {163, 163, 163}},
                    {.kind = CellColor::Kind::rgb, .channels = {123, 67, 248}},
                    {.kind = CellColor::Kind::rgb, .channels = {7, 196, 128}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 202, 0}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 46, 63}},
                    {.kind = CellColor::Kind::rgb, .channels = {0, 159, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {8, 192, 239}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 163, 89}},
                }},
                .terminal = {
                    .foreground = {229, 229, 229},
                    .background = {10, 10, 10},
                    .cursor_color = ThemeRgb{0, 159, 255},
                    .cursor_text_color = ThemeRgb{10, 10, 10},
                    .palette = {{
                        {23, 23, 23},
                        {255, 46, 63},
                        {13, 190, 78},
                        {255, 202, 0},
                        {0, 159, 255},
                        {225, 48, 172},
                        {8, 192, 239},
                        {188, 188, 188},
                        {23, 23, 23},
                        {255, 46, 63},
                        {134, 196, 39},
                        {255, 202, 0},
                        {0, 159, 255},
                        {225, 48, 172},
                        {8, 192, 239},
                        {188, 188, 188},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {229, 229, 229}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 103, 141}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {94, 204, 113}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {104, 205, 242}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {115, 115, 115}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 212, 82}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {104, 205, 242}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 171, 22}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {157, 106, 251}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {213, 104, 234}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 163, 89}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 212, 82}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 171, 22}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {8, 192, 239}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {99, 99, 99}}, .italic = false},
                }},
            },
        },
        {
            "pierre-dark-soft",
            {
                .base = ThemeName::pierre_dark_soft,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {105, 177, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {16, 16, 16}},
                    {.kind = CellColor::Kind::rgb, .channels = {38, 38, 38}},
                    {.kind = CellColor::Kind::rgb, .channels = {44, 44, 44}},
                    {.kind = CellColor::Kind::rgb, .channels = {23, 23, 23}},
                    {.kind = CellColor::Kind::rgb, .channels = {82, 82, 82}},
                    {.kind = CellColor::Kind::rgb, .channels = {99, 99, 99}},
                    {.kind = CellColor::Kind::rgb, .channels = {212, 212, 212}},
                    {.kind = CellColor::Kind::rgb, .channels = {138, 138, 138}},
                    {.kind = CellColor::Kind::rgb, .channels = {157, 106, 251}},
                    {.kind = CellColor::Kind::rgb, .channels = {96, 209, 153}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 212, 82}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 103, 98}},
                    {.kind = CellColor::Kind::rgb, .channels = {105, 177, 255}},
                    {.kind = CellColor::Kind::rgb, .channels = {104, 205, 242}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 186, 130}},
                }},
                .terminal = {
                    .foreground = {212, 212, 212},
                    .background = {23, 23, 23},
                    .cursor_color = ThemeRgb{105, 177, 255},
                    .cursor_text_color = ThemeRgb{23, 23, 23},
                    .palette = {{
                        {23, 23, 23},
                        {255, 46, 63},
                        {13, 190, 78},
                        {255, 202, 0},
                        {0, 159, 255},
                        {225, 48, 172},
                        {8, 192, 239},
                        {188, 188, 188},
                        {23, 23, 23},
                        {255, 46, 63},
                        {134, 196, 39},
                        {255, 202, 0},
                        {0, 159, 255},
                        {225, 48, 172},
                        {8, 192, 239},
                        {188, 188, 188},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {212, 212, 212}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 145, 168}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {140, 218, 148}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {150, 217, 246}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {99, 99, 99}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 222, 128}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {150, 217, 246}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 222, 128}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {186, 143, 253}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {226, 144, 240}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 186, 130}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 222, 128}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 222, 128}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {104, 205, 242}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {115, 115, 115}}, .italic = false},
                }},
            },
        },
        {
            "kanagawa",
            {
                .base = ThemeName::kanagawa,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {126, 156, 216}},
                    {.kind = CellColor::Kind::rgb, .channels = {31, 31, 40}},
                    {.kind = CellColor::Kind::rgb, .channels = {42, 42, 55}},
                    {.kind = CellColor::Kind::rgb, .channels = {54, 54, 70}},
                    {.kind = CellColor::Kind::rgb, .channels = {22, 22, 29}},
                    {.kind = CellColor::Kind::rgb, .channels = {84, 84, 109}},
                    {.kind = CellColor::Kind::rgb, .channels = {114, 113, 105}},
                    {.kind = CellColor::Kind::rgb, .channels = {220, 215, 186}},
                    {.kind = CellColor::Kind::rgb, .channels = {200, 192, 147}},
                    {.kind = CellColor::Kind::rgb, .channels = {149, 127, 184}},
                    {.kind = CellColor::Kind::rgb, .channels = {152, 187, 108}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 158, 59}},
                    {.kind = CellColor::Kind::rgb, .channels = {232, 36, 36}},
                    {.kind = CellColor::Kind::rgb, .channels = {126, 156, 216}},
                    {.kind = CellColor::Kind::rgb, .channels = {143, 164, 158}},
                    {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}},
                }},
                .terminal = {
                    .foreground = {220, 215, 186},
                    .background = {31, 31, 40},
                    .cursor_color = ThemeRgb{220, 215, 186},
                    .cursor_text_color = ThemeRgb{31, 31, 40},
                    .palette = {{
                        {22, 22, 29},
                        {195, 64, 67},
                        {118, 148, 106},
                        {192, 163, 110},
                        {126, 156, 216},
                        {149, 127, 184},
                        {106, 149, 137},
                        {200, 192, 147},
                        {114, 113, 105},
                        {232, 36, 36},
                        {152, 187, 108},
                        {230, 195, 132},
                        {127, 180, 202},
                        {147, 138, 169},
                        {122, 168, 159},
                        {220, 215, 186},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {220, 215, 186}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {149, 127, 184}}, .italic = true},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {152, 187, 108}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {114, 113, 105}}, .italic = true},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {255, 160, 102}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {126, 156, 216}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {143, 164, 158}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {184, 180, 208}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {230, 195, 132}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {192, 163, 110}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {156, 171, 202}}, .italic = false},
                }},
            },
        },
        {
            "kanagawa-dragon",
            {
                .base = ThemeName::kanagawa_dragon,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {139, 164, 176}},
                    {.kind = CellColor::Kind::rgb, .channels = {24, 22, 22}},
                    {.kind = CellColor::Kind::rgb, .channels = {40, 39, 39}},
                    {.kind = CellColor::Kind::rgb, .channels = {57, 56, 54}},
                    {.kind = CellColor::Kind::rgb, .channels = {13, 12, 12}},
                    {.kind = CellColor::Kind::rgb, .channels = {98, 94, 90}},
                    {.kind = CellColor::Kind::rgb, .channels = {115, 124, 115}},
                    {.kind = CellColor::Kind::rgb, .channels = {197, 201, 197}},
                    {.kind = CellColor::Kind::rgb, .channels = {200, 192, 147}},
                    {.kind = CellColor::Kind::rgb, .channels = {138, 147, 176}},
                    {.kind = CellColor::Kind::rgb, .channels = {138, 154, 123}},
                    {.kind = CellColor::Kind::rgb, .channels = {255, 158, 59}},
                    {.kind = CellColor::Kind::rgb, .channels = {232, 36, 36}},
                    {.kind = CellColor::Kind::rgb, .channels = {139, 164, 176}},
                    {.kind = CellColor::Kind::rgb, .channels = {143, 164, 158}},
                    {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}},
                }},
                .terminal = {
                    .foreground = {197, 201, 197},
                    .background = {24, 22, 22},
                    .cursor_color = ThemeRgb{197, 201, 197},
                    .cursor_text_color = ThemeRgb{24, 22, 22},
                    .palette = {{
                        {13, 12, 12},
                        {196, 116, 110},
                        {138, 154, 123},
                        {196, 178, 138},
                        {139, 164, 176},
                        {162, 146, 163},
                        {143, 164, 158},
                        {200, 192, 147},
                        {166, 166, 156},
                        {228, 104, 118},
                        {135, 169, 135},
                        {230, 195, 132},
                        {127, 180, 202},
                        {147, 138, 169},
                        {122, 168, 159},
                        {197, 201, 197},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {197, 201, 197}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {138, 147, 176}}, .italic = true},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {138, 154, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {115, 124, 115}}, .italic = true},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {139, 164, 176}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {143, 164, 158}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {166, 166, 156}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {196, 178, 138}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {182, 146, 123}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {196, 116, 110}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {158, 155, 147}}, .italic = false},
                }},
            },
        },
        {
            "terminal",
            {
                .base = ThemeName::terminal,
                .palette = {{
                    {.kind = CellColor::Kind::indexed, .channels = {4, 0, 0}},
                    {},
                    {.kind = CellColor::Kind::indexed, .channels = {0, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {8, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {8, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {8, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {7, 0, 0}},
                    {},
                    {.kind = CellColor::Kind::indexed, .channels = {7, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {5, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {2, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {3, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {9, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {4, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {6, 0, 0}},
                    {.kind = CellColor::Kind::indexed, .channels = {3, 0, 0}},
                }},
                .terminal = {
                    .foreground = {229, 229, 229},
                    .background = {24, 24, 27},
                    .cursor_color = std::nullopt,
                    .cursor_text_color = std::nullopt,
                    .palette = {{
                        {0, 0, 0},
                        {205, 49, 49},
                        {13, 188, 121},
                        {229, 229, 16},
                        {36, 114, 200},
                        {188, 63, 188},
                        {17, 168, 205},
                        {229, 229, 229},
                        {102, 102, 102},
                        {241, 76, 76},
                        {35, 209, 139},
                        {245, 245, 67},
                        {59, 142, 234},
                        {214, 112, 214},
                        {41, 184, 219},
                        {255, 255, 255},
                    }},
                },
                .syntax_styles = {{
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                    std::nullopt,
                }},
            },
        },
        {
            "cybervenom",
            {
                .base = ThemeName::cybervenom,
                .palette = {{
                    {.kind = CellColor::Kind::rgb, .channels = {170, 135, 245}},
                    {.kind = CellColor::Kind::rgb, .channels = {33, 27, 47}},
                    {.kind = CellColor::Kind::rgb, .channels = {49, 43, 62}},
                    {.kind = CellColor::Kind::rgb, .channels = {55, 50, 69}},
                    {.kind = CellColor::Kind::rgb, .channels = {26, 22, 39}},
                    {.kind = CellColor::Kind::rgb, .channels = {56, 53, 70}},
                    {.kind = CellColor::Kind::rgb, .channels = {94, 93, 116}},
                    {.kind = CellColor::Kind::rgb, .channels = {171, 168, 182}},
                    {.kind = CellColor::Kind::rgb, .channels = {142, 137, 157}},
                    {.kind = CellColor::Kind::rgb, .channels = {175, 153, 233}},
                    {.kind = CellColor::Kind::rgb, .channels = {95, 176, 149}},
                    {.kind = CellColor::Kind::rgb, .channels = {217, 204, 126}},
                    {.kind = CellColor::Kind::rgb, .channels = {243, 121, 134}},
                    {.kind = CellColor::Kind::rgb, .channels = {170, 135, 245}},
                    {.kind = CellColor::Kind::rgb, .channels = {130, 195, 211}},
                    {.kind = CellColor::Kind::rgb, .channels = {236, 156, 99}},
                }},
                .terminal = {
                    .foreground = {171, 168, 182},
                    .background = {33, 27, 47},
                    .cursor_color = ThemeRgb{170, 135, 245},
                    .cursor_text_color = ThemeRgb{33, 27, 47},
                    .palette = {{
                        {56, 53, 70},
                        {243, 121, 134},
                        {95, 176, 149},
                        {217, 204, 126},
                        {153, 186, 248},
                        {170, 135, 245},
                        {130, 195, 211},
                        {171, 168, 182},
                        {124, 118, 144},
                        {254, 169, 175},
                        {153, 194, 172},
                        {229, 202, 147},
                        {184, 210, 255},
                        {199, 178, 255},
                        {179, 215, 225},
                        {229, 227, 238},
                    }},
                },
                .syntax_styles = {{
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {171, 168, 182}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {175, 153, 233}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {95, 176, 149}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {236, 156, 99}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {124, 118, 144}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {236, 156, 99}}, .italic = false},
                    std::nullopt,
                    std::nullopt,
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {153, 186, 248}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {229, 202, 147}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {228, 146, 201}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {179, 215, 225}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {229, 202, 147}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {165, 136, 233}}, .italic = false},
                    SyntaxStyleValues{.color = {.kind = CellColor::Kind::rgb, .channels = {161, 162, 169}}, .italic = false},
                }},
            },
        },
    }};

    inline constexpr ThemeValues default_theme_values = theme_presets[0].values;

  }
}

// Interface: config/theme_query.cppm
export {
  namespace telar::gui {

    class ThemeQuery {
    public:
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const ThemeSelection& selection, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void byteValue(JsonWriter& writer, ThemeRgb bytes);
      static void writeColor(JsonWriter& writer, CellColor color);
      static void writeTheme(JsonWriter& writer, const ThemeValues& theme);
      static void writePalette(JsonWriter& writer, const ThemeValues& theme);
      static void writeOptionalRgb(JsonWriter& writer, const std::optional<ThemeRgb>& color);
      static void writeTerminal(JsonWriter& writer, const TerminalThemeValues& terminal);
      static void writeRgbPalette(JsonWriter& writer, std::span<const ThemeRgb> colors);
      static void writeSyntaxStyles(JsonWriter& writer, const ThemeValues& theme);
      static void writeStyles(JsonWriter& writer, const ThemeValues& theme);
      static void writeStyle(JsonWriter& writer, const SyntaxStyleValues& style);
      static void writeOptionalTheme(JsonWriter& writer, const std::optional<ThemeValues>& theme);
    };

  }
}
