#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.text.json;
import telar.cli.machine_ssh;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using telar::testing::expect;

  using namespace telar::runtime::cli;
  using telar::Memory;
  namespace ds = telar::ds;

  // Memory for the texts a test builds, released with it.
  struct TestMemory {
    telar::testing::TestMemory adapter;

    Memory& get() noexcept {
      return adapter;
    }
  };

  // The sync writes, and sends, only files under an agent's configuration root: never a
  // shell profile, an SSH key list, another tool's configuration or an absolute path.
  void receiveRefusesPathsOutsideAgentRoots() {
    for (const std::string_view path : {
             ".ssh/authorized_keys",
             ".bashrc",
             ".config/git/config",
             "/etc/passwd",
             ".claude\\x",
             ".claude/a\x01",
             ".claude/",
         }) {
      expect(!config_receive::acceptable(path), path);
    }

    check(config_receive::acceptable(".claude/settings.json"));
    check(config_receive::acceptable(".agents/skills/a/SKILL.md"));
  }

  // Names that hold credentials stay on their machine, wherever they sit under a root.
  void receiveRefusesCredentialNames() {
    for (const std::string_view path : {
             ".claude/x.env",
             ".claude/.env.local",
             ".claude/id_ed25519",
             ".claude/mcp-auth.json",
             ".claude/skills/gcloud/a",
             ".claude/skills/Keychains/a",
             ".claude/skills/my_token.txt",
         }) {
      expect(!config_receive::acceptable(path), path);
    }

    check(config_receive::acceptable(".claude/skills/a/SKILL.md"));
  }

  // What /bin/sh prints for `printf %s WORD`, WORD being the quoted value.
  std::string printed(const std::string& word) {
    const auto command = "printf %s " + word;
    FILE* pipe = ::popen(command.c_str(), "r");

    check(pipe != nullptr, command);
    std::string output;
    telar::ds::Array<char, 256> buffer;

    while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), pipe)) {
      output.append(buffer.data(), count);
    }

    check(::pclose(pipe) == 0, command);
    return output;
  }

  // A quoted value reaches the remote shell as one word, byte for byte.
  void quoteSurvivesTheShell() {
    for (const std::string_view value : {
             "a'b $(exit 4)\n",
             "'",
             "''\\'",
             "$HOME `id` \\n; exit 3",
             "",
         }) {
      TestMemory memory;

      expect(printed(std::string{launch::quote(memory.get(), value).view()}) == value, value);
    }
  }

  // Each line that carries a secret holds the file back, at its line; ordinary settings
  // and placeholders do not.
  void findsSecrets() {
    struct Sample {
      std::string_view text;
      std::size_t line;
    };

    const auto samples = telar::ds::Array<Sample, 9>{{
        {"a\nb\n-----BEGIN OPENSSH PRIVATE KEY-----\n", 3},
        {"remote = ghp_0123456789abcdefghijABCDEFGHIJ012345\n", 1},
        {"x\ngithub_pat_11ABCDEFG0123456789_abcdefghijklmnop\n", 2},
        {"curl -H 'Authorization: Bearer abcdefgh123'\n", 1},
        {"see https://user:pw@example.invalid/path\n", 1},
        {"run\nmysql -pS3cret db\n", 2},
        {"curl -u user:pw https://example.invalid\n", 1},
        {"API_KEY=literal-secret-value\n", 1},
        {"{\n  \"password\": \"hunter22\"\n}\n", 2},
    }};

    for (const auto& sample : samples) {
      const auto found = machine::filter::findSecret(sample.text);

      expect(found.hasValue() && found->first == sample.line, sample.text);
    }

    for (const std::string_view text : {
             "# Instructions\nUse the API to list files.\n",
             "API_KEY=$API_KEY\n",
             "Authorization: Bearer ${TOKEN}\n",
             "see https://example.invalid/path\n",
             "https://user:${PASSWORD}@example.invalid\n",
             "\"password\": true\n",
             "curl -u user https://example.invalid\n",
             "mysql -p db\n",
         }) {
      expect(!machine::filter::findSecret(text), text);
    }
  }

  // A multi-line secret value leaves with none of its lines; the rest of the file stays.
  void tomlDropsMultilineSecretValue() {
    for (const std::string_view delimiter : {"\"\"\"", "'''"}) {
      const auto source = std::format("# kept comment\napi_key = {0}\nS1\nS2\n{0}\nmodel = \"x\"\n", delimiter);
      TestMemory memory;
      machine::filter::Notes dropped{memory.get()};
      const auto output = machine::filter::toml(memory.get(), source, dropped);
      const auto text = output.view();

      expect(text.contains("model = \"x\"") && text.contains("# kept comment"), text);
      expect(!text.contains("S1") && !text.contains("S2") && !text.contains("api_key"), text);
      expect(std::ranges::equal(dropped, ds::Array<std::string_view, 1>{"api_key"}), text);
    }

    TestMemory memory;
    machine::filter::Notes dropped{memory.get()};
    const auto output = machine::filter::toml(memory.get(), "[[mcp_servers]]\nurl = \"private\"\n[features]\nsafe = true\n", dropped);
    const auto text = output.view();

    expect(!text.contains("private") && text.contains("[features]\nsafe = true"), text);
    expect(std::ranges::equal(dropped, ds::Array<std::string_view, 1>{"mcp_servers"}), text);
  }

  // Containers that span lines or nest keep the keys after them in step: an inline table
  // under a secret key leaves whole, and a multi-line array under a safe key stays whole.
  void tomlInlineAndMultilineContainers() {
    TestMemory memory;
    machine::filter::Notes dropped{memory.get()};
    const auto output = machine::filter::toml(memory.get(), "env = { KEY = \"v\" }\nheaders = [\n  \"Authorization: x\",\n]\nargs = [\n  \"a\",\n]\nmodel = \"x\"\n", dropped);
    const auto text = output.view();

    expect(!text.contains("KEY") && !text.contains("env"), text);
    expect(!text.contains("Authorization") && !text.contains("headers"), text);
    expect(text.starts_with("args = [\n  \"a\",\n]\nmodel = \"x\""), text);
    expect(std::ranges::equal(dropped, ds::Array<std::string_view, 2>{"env", "headers"}), text);
  }

  // The local home becomes the remote one only where it is a whole path component, so a
  // sibling home that shares its prefix keeps its name.
  void rewriteHomeOnlyAtPathBoundary() {
    TestMemory memory;
    const auto output = machine::filter::rewriteHome(memory.get(), "/Users/al/x \"/Users/al\" /Users/alice", "/Users/al", "/home/r");

    check(output == "/home/r/x \"/home/r\" /Users/alice", output.view());
  }

  // Comments and trailing commas leave; what looks like a comment inside a string, after an
  // escaped quote or in a URL, is the string's own text.
  void stripJsoncRespectsStrings() {
    TestMemory memory;
    const auto plain = machine::filter::stripJsonc(memory.get(), "{\"a\":\"x\\\"//y\", /* c */ \"b\":1 ,\n// end\n\"c\":\"https://x\"\n,}");
    const auto value = telar::runtime::JsonValue::parse(plain);
    const auto a = value.field("a");
    const auto b = value.field("b");
    const auto c = value.field("c");

    check(a && a->encoded() == "\"x\\\"//y\"", plain.view());
    check(b && b->encoded() == "1", plain.view());
    check(c && c->encoded() == "\"https://x\"", plain.view());

    std::string error;

    try {
      machine::filter::stripJsonc(memory.get(), "{\"a\":1 /* open");
    } catch (const std::exception& thrown) {
      error = thrown.what();
    }

    check(error == "UnterminatedComment");
  }

  const telar::testing::Case case_outside_roots{"config_sync.receive_refuses_paths_outside_agent_roots", receiveRefusesPathsOutsideAgentRoots};
  const telar::testing::Case case_credential_names{"config_sync.receive_refuses_credential_names", receiveRefusesCredentialNames};
  const telar::testing::Case case_quote{"config_sync.quote_survives_the_shell", quoteSurvivesTheShell};
  const telar::testing::Case case_secrets{"config_sync.finds_secrets", findsSecrets};
  const telar::testing::Case case_toml{"config_sync.toml_drops_multiline_secret_value", tomlDropsMultilineSecretValue};
  const telar::testing::Case case_toml_containers{"config_sync.toml_inline_and_multiline_containers", tomlInlineAndMultilineContainers};
  const telar::testing::Case case_rewrite_home{"config_sync.rewrite_home_only_at_path_boundary", rewriteHomeOnlyAtPathBoundary};
  const telar::testing::Case case_strip_jsonc{"config_sync.strip_jsonc_respects_strings", stripJsoncRespectsStrings};

}
