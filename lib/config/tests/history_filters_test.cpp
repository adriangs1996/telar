#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.lua;
import telar.config.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // The filters `runtime.history` sets in `source`, or none when reading them refused it.
  ds::Option<HistoryFilters> filtersOf(std::string_view source) {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    lua::Vm<Memory> vm{memory};
    HistoryFilters filters;

    vm.execute(source, "@config.lua");
    const lua::Value history{vm.state(), -1, "history"};

    try {
      config::readHistoryFilters(history, filters);
    } catch (const std::exception&) {
      return ds::none;
    }

    return filters;
  }

  FilteredCommand pane(const HistoryFilters& filters, std::string_view command, std::span<char> scratch) {
    return filters.filterPane(command, "/tmp", scratch);
  }

  // A `{ regex = ... }` entry refuses what it matches, anchored only where it says so; a string
  // entry still refuses what contains it.
  void regexFiltersRefuseWhatTheyMatch() {
    const auto filters = filtersOf(R"(return {command_filters = {"vault login", {regex = "^ssh .*prod"}}, cwd_filters = {{regex = "/secrets?/"}}})");

    check(filters.hasValue());
    check(!filters->allowsPane("ssh web-prod", "/tmp"));
    check(filters->allowsPane("echo ssh prod", "/tmp"));
    check(!filters->allowsPane("sudo vault login", "/tmp"));
    check(!filters->allowsPane("ls", "/home/me/secret/x"));
    check(filters->allowsPane("ls", "/home/me/secrecy"));
  }

  // A pattern that does not compile, or one past the bounds, refuses the configuration.
  void invalidOrTooManyExpressionsRefuseTheConfiguration() {
    check(!filtersOf(R"(return {command_filters = {{regex = "("}}})"));
    check(!filtersOf(R"(return {command_filters = {{regex = "x", other = 1}}})"));
    check(!filtersOf(R"(local list = {} for i = 1, 17 do list[i] = {regex = "p" .. i} end return {command_filters = list})"));
    check(filtersOf(R"(local list = {} for i = 1, 16 do list[i] = {regex = "p" .. i} end return {command_filters = list})").hasValue());
  }

  // `retention` reads how many runs of each command stay, and refuses a count past its bound.
  void retentionKeepsRunsOfEachCommand() {
    const auto filters = filtersOf(R"(return {retention = {keep_runs = 3}})");

    check(filters.hasValue() && filters->retention.keep_runs == 3);
    check(filtersOf("return {}")->retention.keep_runs == 0, "every run stays unless asked");
    check(!filtersOf(R"(return {retention = {keep_runs = -1}})"));
    check(!filtersOf(R"(return {retention = {keep_runs = 1000001}})"));
  }

  // A trivial command is not recorded when it is the whole command line; with arguments it is.
  void trivialCommandsAreNotRecorded() {
    const auto filters = filtersOf(R"(return {trivial_commands = {"ls", "clear", "cd .."}})");

    check(filters.hasValue());
    check(!filters->allowsPane("ls", "/tmp") && !filters->allowsPane("clear\n", "/tmp") && !filters->allowsPane("cd ..", "/tmp"));
    check(filters->allowsPane("ls -la", "/tmp") && filters->allowsPane("cd src", "/tmp"));
    check(!filters->allowsAgent("ls", "/tmp"));
    check(filtersOf("return {}").hasValue() && filtersOf("return {}")->allowsPane("ls", "/tmp"));
  }

  // A command that uses a secret is kept with the secret replaced; one that is mostly a key is
  // not kept at all.
  void secretsAreRedactedOrTheCommandDropped() {
    const HistoryFilters filters;
    std::array<char, 1024> scratch{};

    const auto assignment = pane(filters, "export API_TOKEN=abc123 && make", scratch);
    check(assignment.verdict == HistoryVerdict::redact && assignment.text == "export API_TOKEN=[redacted] && make");

    const auto bearer = pane(filters, "curl -H 'Authorization: Bearer sk-ant-" + std::string(40, 'x') + "' https://api.example.com/v1/messages", scratch);
    check(bearer.verdict == HistoryVerdict::redact && bearer.text == "curl -H 'Authorization: Bearer [redacted]' https://api.example.com/v1/messages");

    check(pane(filters, "ghp_" + std::string(36, 'x'), scratch).verdict == HistoryVerdict::drop);
    check(pane(filters, "echo ghp_" + std::string(20, 'x'), scratch).verdict == HistoryVerdict::drop);
    check(pane(filters, "git status", scratch).verdict == HistoryVerdict::keep);
    check(pane(filters, " export TOKEN=x", scratch).verdict == HistoryVerdict::drop);

    HistoryFilters off;

    off.secrets = false;
    check(pane(off, "export API_TOKEN=abc123", scratch).verdict == HistoryVerdict::keep);
  }

  // A command the history records only redacted is recorded, but not as written, so nothing
  // offers it back with its secret, as a suggestion would.
  void redactedCommandsAreRecordedButNotAsWritten() {
    const HistoryFilters filters;

    check(filters.recordsPane("export API_TOKEN=abc123 && make", "/tmp") && !filters.allowsPane("export API_TOKEN=abc123 && make", "/tmp"));
    check(filters.recordsAgent("token=abc", "/tmp") && !filters.allowsAgent("token=abc", "/tmp"));
    check(!filters.recordsPane("ghp_" + std::string(36, 'x'), "/tmp") && !filters.allowsPane("ghp_" + std::string(36, 'x'), "/tmp"));
    check(filters.recordsPane("make", "/tmp") && filters.allowsPane("make", "/tmp"));
  }

  // Output keeps everything but its secrets, and never grows past the limit it is given: what a
  // redaction adds is cut from its front, at a character.
  void outputKeepsAllButItsSecrets() {
    const HistoryFilters filters;
    std::array<char, 1024> scratch{};

    check(filters.filterOutput("A=1\nGITHUB_TOKEN=xyz\nB=2\n", scratch, 1024) == "A=1\nGITHUB_TOKEN=[redacted]\nB=2\n");
    check(filters.filterOutput("plain output\n", scratch, 1024) == "plain output\n");
    check(filters.filterOutput("\xc3\xa9token=a", scratch, 17) == "token=[redacted]");

    std::array<char, 8> small{};

    check(filters.filterOutput("token=abcdef", small, 1024).empty());
  }

  const telar::testing::Case case_regex{"history_filters.regex_filters_refuse_what_they_match", regexFiltersRefuseWhatTheyMatch};
  const telar::testing::Case case_invalid{"history_filters.invalid_or_too_many_expressions_refuse_the_configuration", invalidOrTooManyExpressionsRefuseTheConfiguration};
  const telar::testing::Case case_trivial{"history_filters.trivial_commands_are_not_recorded", trivialCommandsAreNotRecorded};
  const telar::testing::Case case_secrets{"history_filters.secrets_are_redacted_or_the_command_dropped", secretsAreRedactedOrTheCommandDropped};
  const telar::testing::Case case_not_as_written{"history_filters.redacted_commands_are_recorded_but_not_as_written", redactedCommandsAreRecordedButNotAsWritten};
  const telar::testing::Case case_output{"history_filters.output_keeps_all_but_its_secrets", outputKeepsAllButItsSecrets};
  const telar::testing::Case case_retention_keep{"history_filters.retention_keeps_runs_of_each_command", retentionKeepsRunsOfEachCommand};

}
