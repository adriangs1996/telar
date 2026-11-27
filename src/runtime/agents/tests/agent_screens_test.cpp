import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.runtime.agents.screen_inference;
import telar.runtime.terminal.text_reader;
import telar.wire.vocabulary;
import telar.base.ds;

// Screens Claude Code 2.1.332, Codex 0.169.0 and Antigravity CLI 1.5.17 drew in a 100x32 terminal, their last rows with
// their title and cursor, recorded from real sessions; paths and account details are replaced.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Claude idle at its prompt, the cursor after it.
  constexpr std::string_view claude_idle =
      "\x1b[2J"
      "\x1b]0;✳ Claude Code\x1b\\"
      "\x1b[1;1H ▐▛███▛█   Claude Code v2.1.332"
      "\x1b[2;1H▝▜██████▀  Haiku 5.5 · Claude Pro"
      "\x1b[3;1H ▝▝   ▝▝   /tmp/demo"
      "\x1b[6;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[7;1H❯\u00a0Try \"write a test for <filepath>\""
      "\x1b[8;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[9;1H  -- INSERT -- ⏸ manual mode on · ← for agents                                  ◐ medium · /effort"
      "\x1b[7;3H"
      "\x1b[?25h";

  // Claude running a tool: its title spins, the composer keeps the cursor.
  constexpr std::string_view claude_running =
      "\x1b[2J"
      "\x1b]0;◐ Marker2.txt touch and sleep\x1b\\"
      "\x1b[1;1H ▐▛███▛█   Claude Code v2.1.332"
      "\x1b[2;1H▝▜██████▀  Haiku 5.5 · Claude Pro"
      "\x1b[3;1H ▝▝   ▝▝   /tmp/demo"
      "\x1b[6;1H❯ Use the Bash tool to run exactly: touch marker2.txt && sleep 25"
      "\x1b[8;1H  Bash(touch marker2.txt && sleep 25)"
      "\x1b[9;1H  ⎿ \u00a0Running…"
      "\x1b[11;1H✢ Crafting… (4s · ↓ 97 tokens)"
      "\x1b[13;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[14;1H❯\u00a0"
      "\x1b[15;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[16;1H  -- INSERT -- ⏸ manual mode on · ← for agents"
      "\x1b[14;3H"
      "\x1b[?25h";

  // Claude asks permission for a shell command.
  constexpr std::string_view claude_permission =
      "\x1b[2J"
      "\x1b]0;✳ Touch marker and sleep command\x1b\\"
      "\x1b[12;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[13;1H Bash command"
      "\x1b[14;1H Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below"
      "\x1b[15;1H Create marker file, wait 20 seconds, print finished"
      "\x1b[16;1H╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
      "\x1b[17;1H touch marker.txt && sleep 20 && echo finished"
      "\x1b[18;1H╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
      "\x1b[19;1H Do you want to proceed?"
      "\x1b[20;1H ❯ 1. Yes"
      "\x1b[21;1H   2. Yes, and always allow access to /tmp/demo"
      "\x1b[22;1H       from this project"
      "\x1b[23;1H   3. Yes, and switch to auto mode · auto mode handles these prompts for you"
      "\x1b[24;1H   4. No"
      "\x1b[26;1H Esc to cancel · Tab to amend"
      "\x1b[20;2H"
      "\x1b[?25l";

  // Claude asks permission to create a file.
  constexpr std::string_view claude_create_file =
      "\x1b[2J"
      "\x1b]0;✳ Touch marker and sleep command\x1b\\"
      "\x1b[14;1H⏺ Write(notes.txt)"
      "\x1b[16;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[17;1H Create file"
      "\x1b[18;1H notes.txt"
      "\x1b[19;1H╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
      "\x1b[20;1H  1 hello"
      "\x1b[21;1H╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
      "\x1b[22;1H Do you want to create notes.txt?"
      "\x1b[23;1H ❯ 1. Yes"
      "\x1b[24;1H   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this"
      "\x1b[25;1H      session (shift+tab)"
      "\x1b[26;1H   3. No"
      "\x1b[28;1H Esc to cancel · Tab to amend"
      "\x1b[23;2H"
      "\x1b[?25l";

  // Claude after the user denied a file write.
  constexpr std::string_view claude_denied =
      "\x1b[2J"
      "\x1b]0;✳ Touch marker and sleep command\x1b\\"
      "\x1b[6;1H❯ Use the Bash tool to run exactly this command and nothing else: touch marker.txt && sleep 20 &&"
      "\x1b[7;1H  echo finished"
      "\x1b[9;1H⏺ Bash(touch marker.txt && sleep 20 && echo finished)"
      "\x1b[10;1H  ⎿ \u00a0finished"
      "\x1b[12;1H❯ Use the Write tool to create a file named notes.txt containing the word hello"
      "\x1b[14;1H⏺ Write(notes.txt)"
      "\x1b[15;1H  ⎿ \u00a0Rejected write to notes.txt"
      "\x1b[16;1H      1 hello"
      "\x1b[18;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[19;1H❯\u00a0"
      "\x1b[20;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[21;1H  -- INSERT -- ⏸ manual mode on"
      "\x1b[19;3H"
      "\x1b[?25h";

  // Claude asks the user a question.
  constexpr std::string_view claude_question =
      "\x1b[2J"
      "\x1b]0;✳ Touch marker and sleep command\x1b\\"
      "\x1b[17;1H❯ e the AskUserQuestion tool to ask me whether I prefer red or blue"
      "\x1b[18;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[19;1H ☐ Color"
      "\x1b[21;1HDo you prefer red or blue?"
      "\x1b[23;1H❯ 1. Red"
      "\x1b[24;1H     Choose red"
      "\x1b[25;1H  2. Blue"
      "\x1b[26;1H     Choose blue"
      "\x1b[27;1H  3. Type something."
      "\x1b[28;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[29;1H  4. Chat about this"
      "\x1b[31;1HEnter to select · ↑/↓ to navigate · Esc to cancel"
      "\x1b[23;1H"
      "\x1b[?25l";

  // Claude after the user pressed Esc during a tool.
  constexpr std::string_view claude_interrupted =
      "\x1b[2J"
      "\x1b]0;✳ Marker2.txt touch and sleep\x1b\\"
      "\x1b[1;1H ▐▛███▛█   Claude Code v2.1.332"
      "\x1b[2;1H▝▜██████▀  Haiku 5.5 · Claude Pro"
      "\x1b[3;1H ▝▝   ▝▝   /tmp/demo"
      "\x1b[6;1H❯ Use the Bash tool to run exactly: touch marker2.txt && sleep 25"
      "\x1b[8;1H⏺ Bash(touch marker2.txt && sleep 25)"
      "\x1b[9;1H  ⎿ \u00a0Interrupted · What should Claude do instead?"
      "\x1b[11;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[12;1H❯\u00a0"
      "\x1b[13;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[14;1H  ⏸ manual mode on · ? for shortcuts"
      "\x1b[12;3H"
      "\x1b[?25h";

  // Claude idle with a draft typed into its prompt.
  constexpr std::string_view claude_draft =
      "\x1b[2J"
      "\x1b]0;✳ Marker2.txt touch and sleep\x1b\\"
      "\x1b[1;1H ▐▛███▛█   Claude Code v2.1.332"
      "\x1b[2;1H▝▜██████▀  Haiku 5.5 · Claude Pro"
      "\x1b[3;1H ▝▝   ▝▝   /tmp/demo"
      "\x1b[6;1H❯ Use the Bash tool to run exactly: touch marker2.txt && sleep 25"
      "\x1b[8;1H⏺ Bash(touch marker2.txt && sleep 25)"
      "\x1b[9;1H  ⎿ \u00a0Interrupted · What should Claude do instead?"
      "\x1b[11;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[12;1H❯\u00a0draft text left in the prompt"
      "\x1b[13;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[14;1H  -- INSERT -- ⏸ manual mode on"
      "\x1b[12;32H"
      "\x1b[?25h";

  // Claude asks whether to trust the workspace.
  constexpr std::string_view claude_trust =
      "\x1b[2J"
      "\x1b[5;1H /tmp/demo"
      "\x1b[6;1H cratchpad/proj-claude"
      "\x1b[8;1H Quick safety check: Is this a project you created or one you trust? (Like your own code, a"
      "\x1b[9;1H well-known open source project, or work from your team). If not, take a moment to review what's in"
      "\x1b[10;1H this folder first."
      "\x1b[12;1H Claude Code'll be able to read, edit, and execute files here."
      "\x1b[14;1H Security guide"
      "\x1b[16;1H ❯ No, exit"
      "\x1b[17;1H   Yes, I trust this folder"
      "\x1b[19;1H Enter to confirm · Esc to cancel"
      "\x1b[16;2H"
      "\x1b[?25l";

  // Claude done with a background shell still running.
  constexpr std::string_view claude_shell_left =
      "\x1b[2J"
      "\x1b]0;✳ Background sleep command\x1b\\"
      "\x1b[6;1H❯ Use the Bash tool with run_in_background set to true to run: sleep 45. Then reply with one word"
      "\x1b[7;1H  and stop."
      "\x1b[9;1H⏺ Bash(sleep 45)"
      "\x1b[10;1H  ⎿ \u00a0Running in the background (↓ to manage)"
      "\x1b[12;1H⏺ The sleep 45 is running in the background. I'll send the one-word reply once it finishes."
      "\x1b[14;1H✻ Sautéed for 3s · done 2:18 PM · 1 shell still running"
      "\x1b[16;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[17;1H❯\u00a0"
      "\x1b[18;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[19;1H  -- INSERT -- ⏸ manual mode on · 1 shell · ← for agents                        ◐ medium · /effort"
      "\x1b[17;3H"
      "\x1b[?25h";

  // Codex idle at its composer.
  constexpr std::string_view codex_idle =
      "\x1b[2J"
      "\x1b[17;1H                                  ⠈⢿⣿⣿⣦⡀⠈⠛⠿⣿⣿⣿⣿⣄⡀  ⢀⣠⣼⣿⣿  ⣿⣿⡇  ⣿⣿⣿⠇"
      "\x1b[18;1H                                    ⢻⣿⣿⣿⣷⣦⣀⠈⠙⠻⣿⣿⣿⣶⣶⣿⣿⣿⣿⣿  ⣿⣿⡇ ⣠⣿⣿⣿"
      "\x1b[19;1H                                    ⢸⣿⣿⡿⢿⣿⣿⣿⣦⣠⣴⣿⣿⣿⡿⠟⠋⢸⣿⣿  ⣿⣿⣷⣴⣿⣿⣿⠃"
      "\x1b[20;1H                                    ⠘⣿⣿⣷ ⠈⠛⢿⣿⣿⣿⠿⠋⠉ ⣠⣴⣿⣿⣿  ⣿⣿⣿⣿⣿⠟⠁"
      "\x1b[21;1H                                     ⠻⣿⣿⣿⣤⣀ ⠈⠉ ⢀⣤⣶⣿⣿⣿⠿⠟⠁ ⣰⣿⣿⡟⠋⠁"
      "\x1b[22;1H                                      ⠈⠿⣿⣿⣿⣿⣶⣾⣿⣿⣿⣿⠟⠋⠁  ⣠⣼⣿⣿⡟"
      "\x1b[23;1H                                         ⠙⠛⠛⠛⠻⠛⢿⣿⣿⣿⣿⣷⣾⣿⣿⣿⡿⠏"
      "\x1b[24;1H                                                ⠈⠙⠛⠿⠿⠿⠿⠛⠉"
      "\x1b[30;1H› Ask Codex to do anything"
      "\x1b[32;1H  ? for shortcuts"
      "\x1b[30;3H"
      "\x1b[?25h";

  // Codex running an approved command.
  constexpr std::string_view codex_working =
      "\x1b[2J"
      "\x1b]0;⠸ Run the shell command | proj-codex\x1b\\"
      "\x1b[25;1H• Working (13s • esc to interrupt)"
      "\x1b[28;1H› Ask Codex to do anything"
      "\x1b[30;1H  gpt-5 high · /tmp/demo"
      "\x1b[31;1H   · Context 2% used · "
      "\x1b[32;1H  ← for agents · ? for shortcuts                                           ⚠ 1 warning · f2 to view"
      "\x1b[28;3H"
      "\x1b[?25h";

  // Codex asks to approve a command.
  constexpr std::string_view codex_approval =
      "\x1b[2J"
      "\x1b]0;[ . ] Action Required | Run the shell command | proj-codex\x1b\\"
      "\x1b[19;1H  Would you like to run the following command?"
      "\x1b[21;1H  Environment: local"
      "\x1b[23;1H  Reason: Run it outside the read-only sandbox to create marker.txt?"
      "\x1b[25;1H  $ touch marker.txt && sleep 15 && echo finished"
      "\x1b[28;1H› 1. Yes, proceed (y)"
      "\x1b[29;1H  2. Yes, and don't ask again for commands that start with `touch marker.txt` (p)"
      "\x1b[30;1H  3. No, and tell Codex what to do differently (esc)"
      "\x1b[32;1H  Press enter to confirm or esc to cancel"
      "\x1b[32;101H"
      "\x1b[?25l";

  // Codex after the user pressed Esc.
  constexpr std::string_view codex_interrupted =
      "\x1b[2J"
      "\x1b]0;Run the shell command | proj-codex\x1b\\"
      "\x1b[27;1H› Write a 500 word essay about terminals directly in your answer"
      "\x1b[30;1H  gpt-5 high · /tmp/demo"
      "\x1b[31;1H   · Context 2% used · "
      "\x1b[32;1H                                                                           ⚠ 1 warning · f2 to view"
      "\x1b[28;3H"
      "\x1b[?25h";

  // Antigravity CLI 1.5.17 idle: its composer between two rules, the footer below them.
  constexpr std::string_view antigravity_idle =
      "\x1b[2J"
      "\x1b[1;1H      ▄▀▀▄        Antigravity CLI 1.5.17"
      "\x1b[2;1H     ▀▀▀▀▀▀       Gemini 4 Neon (High)"
      "\x1b[3;1H    ▀▀▀▀▀▀▀▀      /tmp/demo"
      "\x1b[28;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[29;1H> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"
      "\x1b[30;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[31;1H? for shortcuts                                                          auto · Gemini 4 Neon · high"
      "\x1b[29;3H"
      "\x1b[?25h";

  // Antigravity running a turn: the footer offers to cancel it.
  constexpr std::string_view antigravity_working =
      "\x1b[2J"
      "\x1b[22;1H> Run exactly: rm -rf ./scratch-dir && mkdir scratch-dir"
      "\x1b[24;1H● Ran (rm -rf ./scratch-dir && mkdir scratch-dir) (ctrl+o to expand)"
      "\x1b[25;1H⡿  Running command... 1s"
      "\x1b[26;1H└ Tip: Press ctrl+b to send a long task to the background."
      "\x1b[28;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[29;1H>"
      "\x1b[30;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[31;1Hesc to cancel                                                            auto · Gemini 4 Neon · high"
      "\x1b[29;3H"
      "\x1b[?25h";

  // Antigravity asks permission for a shell command.
  constexpr std::string_view antigravity_permission =
      "\x1b[2J"
      "\x1b[16;1H● Ran (rm -rf ./scratch-dir && mkdir scratch-dir && touch scratch-dir/a) (ctrl+o to expand)"
      "\x1b[18;1HCommand"
      "\x1b[19;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[21;1HRequesting permission for:"
      "\x1b[22;1H   rm -rf ./scratch-dir && mkdir scratch-dir && touch scratch-dir/a"
      "\x1b[24;1HRun this command?"
      "\x1b[25;1H> 1. Yes, run command"
      "\x1b[26;1H  2. Yes, and always allow in this conversation for commands that start with 'rm -rf'"
      "\x1b[27;1H  3. Yes, and always allow for commands that start with 'rm -rf' (Persist to settings.json)"
      "\x1b[28;1H  4. No, cancel"
      "\x1b[30;1H  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command"
      "\x1b[31;1Hesc to cancel                                                                   Gemini 4 Neon · high"
      "\x1b[?25l";

  // Antigravity asks whether to trust a new workspace.
  constexpr std::string_view antigravity_trust =
      "\x1b[2J"
      "\x1b[1;1HAccessing workspace:"
      "\x1b[3;1H/tmp/demo"
      "\x1b[5;1HDo you trust the contents of this project?"
      "\x1b[7;1HAntigravity CLI requires permission to read, edit, and execute files here."
      "\x1b[9;1H> Yes, I trust this folder"
      "\x1b[10;1H  No, exit"
      "\x1b[12;1H  ↑/↓ Navigate · enter Confirm"
      "\x1b[13;1H                                                                         auto · Gemini 4 Neon · high"
      "\x1b[?25l";

  // Antigravity asks to create a file.
  constexpr std::string_view antigravity_create_file =
      "\x1b[2J"
      "\x1b[18;1HCreate file"
      "\x1b[19;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[21;1H/tmp/demo/notes.txt  +1"
      "\x1b[22;1H  1  +  hola"
      "\x1b[24;1HAllow creation of this file?"
      "\x1b[25;1H> 1. Yes, allow creation"
      "\x1b[26;1H  2. No, deny creation"
      "\x1b[28;1H  ↑/↓ Navigate · f full diff"
      "\x1b[29;1Hesc to cancel                                                                   Gemini 4 Neon · high"
      "\x1b[?25l";

  // Antigravity asks to read a file outside the workspace: its footer names no other key.
  constexpr std::string_view antigravity_file_access =
      "\x1b[2J"
      "\x1b[18;1HFile access"
      "\x1b[19;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[21;1HRead: /home/user/notes/SKILL.md"
      "\x1b[22;1HReason: outside workspace"
      "\x1b[24;1HAllow access to this file?"
      "\x1b[25;1H> 1. Yes, allow access"
      "\x1b[26;1H  2. Yes, and always allow non-workspace access"
      "\x1b[27;1H  3. No, deny access"
      "\x1b[29;1H  ↑/↓ Navigate"
      "\x1b[30;1Hesc to cancel                                                                   Gemini 4 Neon · high"
      "\x1b[?25l";

  // Antigravity's command menu, open as the user types a slash: not a question.
  constexpr std::string_view antigravity_menu =
      "\x1b[2J"
      "\x1b[20;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[21;1H> /"
      "\x1b[22;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[23;1H> /add-dir                        Add a directory to the workspace"
      "\x1b[24;1H  /agents                         List available custom agents"
      "\x1b[25;1H   ↓ 85 more"
      "\x1b[27;1H  ↑/↓ Navigate · enter Select · tab Complete"
      "\x1b[28;1Hesc to cancel                                                                   Gemini 4 Neon · high"
      "\x1b[21;4H"
      "\x1b[?25h";

  // Antigravity after Esc, with a draft in its composer: the footer drops its hint.
  constexpr std::string_view antigravity_interrupted_draft =
      "\x1b[2J"
      "\x1b[24;1H> Write a 2000 word essay about terminals in your reply (no tools)."
      "\x1b[26;1H  ⎿  Interrupted · What should Antigravity CLI do instead?"
      "\x1b[27;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[28;1H> un borrador que"
      "\x1b[29;1H  sigue en otra fila"
      "\x1b[30;1H────────────────────────────────────────────────────────────────────────────────────────────────────"
      "\x1b[31;1H                                                                         auto · Gemini 4 Neon · high"
      "\x1b[29;20H"
      "\x1b[?25h";

  struct Screen {
    Screen()
        : terminal(memory, TerminalSize{100, 32, 8, 16}) {}

    void draw(std::string_view text) {
      terminal.feed({reinterpret_cast<const Byte*>(text.data()), text.size()});
      terminal.refresh();
    }

    ds::Option<AgentSignal> read(AgentProvider provider) {
      return inference.observe(terminal, builtinManifests(), provider);
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Terminal terminal;
    AgentScreenInference inference;
  };

  // What a screen says of the agent, read alone.
  ds::Option<AgentStatus> statusOf(AgentProvider provider, std::string_view drawn) {
    Screen screen;

    screen.draw(drawn);
    const auto signal = screen.read(provider);

    return signal ? ds::Option{signal->status} : ds::none;
  }

  bool reads(AgentProvider provider, std::string_view drawn, AgentStatus status) {
    return statusOf(provider, drawn) == status;
  }

  // The title spins while a turn runs, and the status line says so when the title does not.
  void claudeWork() {
    check(reads(AgentProvider::claude, claude_running, AgentStatus::working), "a running Claude reads as idle");
    check(reads(AgentProvider::claude, std::string{claude_running} + "\x1b]0;\xe2\x9c\xb3 Claude Code\x1b\\", AgentStatus::working), "Claude's status line reads as idle without its spinning title");
    check(reads(AgentProvider::claude, claude_idle, AgentStatus::ready), "an idle Claude reads as busy");
    check(reads(AgentProvider::claude, claude_shell_left, AgentStatus::ready), "the line a turn ends with reads as a running turn");
  }

  // Claude's dialogs: a permission, a file it creates, a question and the workspace's trust.
  void claudeDialogs() {
    check(reads(AgentProvider::claude, claude_permission, AgentStatus::blocked), "a permission dialog does not block Claude");
    check(reads(AgentProvider::claude, claude_create_file, AgentStatus::blocked), "a file permission does not block Claude");
    check(reads(AgentProvider::claude, claude_question, AgentStatus::blocked), "a question does not block Claude");
    check(reads(AgentProvider::claude, claude_trust, AgentStatus::blocked), "the trust dialog does not block Claude");
  }

  // Esc during a tool, a denied permission and a draft left in the prompt end at the idle prompt.
  void claudeStops() {
    check(reads(AgentProvider::claude, claude_interrupted, AgentStatus::ready), "an interrupted Claude reads as busy");
    check(reads(AgentProvider::claude, claude_denied, AgentStatus::ready), "a denied permission leaves Claude busy");
    check(reads(AgentProvider::claude, claude_draft, AgentStatus::ready), "a draft in the prompt hides the idle prompt");
  }

  // The conversation quotes any phrase; only the rows Claude draws its dialogs in are read.
  void claudeConversationQuotes() {
    const auto quoted = std::string{claude_denied} + "\x1b[10;1H\xe2\x8f\xba Do you want to proceed? Type [y/n] at the prompt." + "\x1b[19;3H";

    check(reads(AgentProvider::claude, quoted, AgentStatus::ready), "a question in the conversation blocks Claude");

    // A conversation about Codex is still Claude's screen.
    const auto named = std::string{claude_running} + "\x1b[7;1H\xe2\x8f\xba codex prints Working (3s \xe2\x80\xa2 esc to interrupt)" + "\x1b]0;\xe2\x9c\xb3 Claude Code\x1b\\" + "\x1b[14;3H";
    Screen screen;

    screen.draw(named);
    const auto signal = screen.read(AgentProvider::claude);

    check(signal && signal->status == AgentStatus::working && signal->provider == AgentProvider::claude, "a Claude screen that names Codex reads as Codex");
  }

  void codexScreens() {
    check(reads(AgentProvider::codex, codex_idle, AgentStatus::ready), "an idle Codex reads as busy");
    check(reads(AgentProvider::codex, codex_working, AgentStatus::working), "a running Codex reads as idle");
    check(reads(AgentProvider::codex, codex_approval, AgentStatus::blocked), "an approval does not block Codex");
    check(reads(AgentProvider::codex, std::string{codex_approval} + "\x1b]0;proj-codex\x1b\\", AgentStatus::blocked), "an approval's footer does not block Codex without its title");
    check(reads(AgentProvider::codex, codex_interrupted, AgentStatus::ready), "an interrupted Codex reads as busy");
  }

  // A screen is said once, and when it stops showing what it said the observer says so once.
  void screenChanges() {
    Screen screen;

    screen.draw(claude_running);
    check(screen.read(AgentProvider::claude)->status == AgentStatus::working);
    check(!screen.read(AgentProvider::claude), "an unchanged screen is said again");
    screen.draw("\x1b]0;editor\x1b\\\x1b[2J\x1b[1;1H~\x1b[2;1H~\x1b[1;1H");

    const auto lost = screen.read(AgentProvider::claude);

    check(lost && lost->status == AgentStatus::unknown && lost->provider == AgentProvider::claude, "a screen that no longer shows the agent's state goes unsaid");
    check(!screen.read(AgentProvider::claude), "a lost screen is said twice");
    screen.draw(claude_idle);
    check(screen.read(AgentProvider::claude)->status == AgentStatus::ready);
  }

  // A question Codex asks right after the observer lost its screen is still the user's to answer.
  void codexQuestionAfterReset() {
    Screen screen;

    screen.inference.reset();
    screen.draw(codex_approval);
    check(screen.read(AgentProvider::codex)->status == AgentStatus::blocked, "a reset hides Codex's approval");
  }

  // Another agent's phrases in Cursor's output do not block Cursor.
  void cursorReadsItsOwnPhrases() {
    constexpr std::string_view output = "\x1b[2J\x1b[18;1HOverwrite build/? [y/n] (answered y)\x1b[20;1HDo you want to proceed? yes\x1b[22;1H\xe2\x86\x92 Add a follow-up";

    check(reads(AgentProvider::cursor, output, AgentStatus::ready), "Claude's phrases in Cursor's output block Cursor");
  }

  // Antigravity's footer tells a running turn from an idle composer; its dialogs' footers block it,
  // and the conversation above the composer, which may quote them, does not.
  void antigravityScreens() {
    check(reads(AgentProvider::antigravity, antigravity_idle, AgentStatus::ready), "an idle Antigravity reads as busy");
    check(reads(AgentProvider::antigravity, antigravity_working, AgentStatus::working), "a running Antigravity reads as idle");
    check(reads(AgentProvider::antigravity, antigravity_permission, AgentStatus::blocked), "a permission does not block Antigravity");
    check(reads(AgentProvider::antigravity, antigravity_trust, AgentStatus::blocked), "the trust dialog does not block Antigravity");
    check(reads(AgentProvider::antigravity, antigravity_create_file, AgentStatus::blocked), "a file creation does not block Antigravity");
    check(reads(AgentProvider::antigravity, antigravity_file_access, AgentStatus::blocked), "access outside the workspace does not block Antigravity");
    check(statusOf(AgentProvider::antigravity, antigravity_menu) != ds::Option{AgentStatus::blocked}, "the command menu blocks Antigravity");
    check(reads(AgentProvider::antigravity, antigravity_interrupted_draft, AgentStatus::ready), "a draft after an interrupt hides the idle composer");

    const auto quoted = std::string{antigravity_working} + "\x1b[20;1H  the footer says ↑/↓ Navigate · tab Amend" + "\x1b[29;3H";

    check(reads(AgentProvider::antigravity, quoted, AgentStatus::working), "a dialog quoted in the conversation blocks Antigravity");
  }

  const telar::testing::Case case_claude_work{"agent_screens.claude_work", claudeWork};
  const telar::testing::Case case_claude_dialogs{"agent_screens.claude_dialogs", claudeDialogs};
  const telar::testing::Case case_claude_stops{"agent_screens.claude_stops", claudeStops};
  const telar::testing::Case case_claude_conversation_quotes{"agent_screens.claude_conversation_quotes", claudeConversationQuotes};
  const telar::testing::Case case_codex_screens{"agent_screens.codex_screens", codexScreens};
  const telar::testing::Case case_screen_changes{"agent_screens.screen_changes", screenChanges};
  const telar::testing::Case case_codex_question_after_reset{"agent_screens.codex_question_after_reset", codexQuestionAfterReset};
  const telar::testing::Case case_antigravity_screens{"agent_screens.antigravity_screens", antigravityScreens};
  const telar::testing::Case case_cursor_reads_its_own_phrases{"agent_screens.cursor_reads_its_own_phrases", cursorReadsItsOwnPhrases};

}
