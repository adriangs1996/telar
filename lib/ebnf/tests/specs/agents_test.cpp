#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {
using spec_support::SpecTest;

TEST_F(SpecTest, ClaudeDescribesOptionsAndValues) {
  EXPECT_EQ(description("claude", {}, "--permission-mode"), "Permission mode for the session");
  EXPECT_EQ(description("claude", {"mcp"}, "add"), "Add an MCP server");
  const auto modes = texts("claude", {"--permission-mode"}, "");
  EXPECT_TRUE(contains(modes, "plan"));
  EXPECT_TRUE(contains(modes, "acceptEdits"));
}

TEST_F(SpecTest, ClaudeAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("claude", {"--model", "sonnet", "-p", "explain this"}), -1);
  EXPECT_EQ(firstInvalid("claude", {"--permission-mode=acceptEdits", "-c", "--add-dir", "../lib", "--effort", "high"}), -1);
  EXPECT_EQ(firstInvalid("claude", {"mcp", "add", "--transport", "http", "sentry", "https://mcp.sentry.dev/mcp"}), -1);
  EXPECT_EQ(firstInvalid("claude", {"mcp", "add", "my-server", "-e", "API_KEY=xxx", "--", "npx", "my-mcp-server"}), -1);
  EXPECT_EQ(firstInvalid("claude", {"plugin", "install", "formatter@tools", "-s", "project"}), -1);
}

TEST_F(SpecTest, ClaudeRejectsUnknownSubcommandsAndOptions) {
  EXPECT_EQ(firstInvalid("claude", {"mcp", "bogus"}), 1);
  EXPECT_EQ(firstInvalid("claude", {"plugin", "list", "--bogus"}), 2);
  EXPECT_EQ(firstInvalid("claude", {"--output-format", "yaml"}), 1);
}

TEST_F(SpecTest, CodexDescribesOptionsAndValues) {
  EXPECT_EQ(description("codex", {}, "--sandbox"), "Sandbox policy for model commands");
  const auto modes = texts("codex", {"--sandbox"}, "");
  EXPECT_TRUE(contains(modes, "workspace-write"));
  EXPECT_TRUE(contains(modes, "danger-full-access"));
}

TEST_F(SpecTest, CodexAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("codex", {"-m", "o3", "-a", "on-request", "refactor the parser"}), -1);
  EXPECT_EQ(firstInvalid("codex", {"exec", "--json", "-s", "read-only", "fix the tests", "-o", "last.txt"}), -1);
  EXPECT_EQ(firstInvalid("codex", {"exec", "resume", "--last", "continue"}), -1);
  EXPECT_EQ(firstInvalid("codex", {"mcp", "add", "docs", "--env", "TOKEN=x", "--", "npx", "docs-server"}), -1);
  EXPECT_EQ(firstInvalid("codex", {"-c", "model=\"o3\"", "review", "--base", "main"}), -1);
}

TEST_F(SpecTest, CodexRejectsUnknownSubcommandsAndValues) {
  EXPECT_EQ(firstInvalid("codex", {"mcp", "bogus"}), 1);
  EXPECT_EQ(firstInvalid("codex", {"features", "list", "--bogus"}), 2);
  EXPECT_EQ(firstInvalid("codex", {"--sandbox", "everything"}), 1);
}

TEST_F(SpecTest, OpencodeDescribesCommands) {
  EXPECT_EQ(description("opencode", {}, "run"), "Run opencode with a message");
  EXPECT_TRUE(contains(texts("opencode", {"session", "list", "--format"}, ""), "json"));
}

TEST_F(SpecTest, OpencodeAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("opencode", {"run", "-m", "anthropic/claude-sonnet-4", "fix the bug"}), -1);
  EXPECT_EQ(firstInvalid("opencode", {"--model", "openai/gpt-5", "--continue", "src"}), -1);
  EXPECT_EQ(firstInvalid("opencode", {"session", "list", "--format=json", "-n", "5"}), -1);
}

TEST_F(SpecTest, OpencodeRejectsUnknownOptions) {
  EXPECT_EQ(firstInvalid("opencode", {"--bogus"}), 0);
  EXPECT_EQ(firstInvalid("opencode", {"session", "list", "--format", "xml"}), 3);
  EXPECT_EQ(firstInvalid("opencode", {"session", "bogus"}), 1);
}

TEST_F(SpecTest, GeminiDescribesOptionsAndValues) {
  EXPECT_EQ(description("gemini", {}, "--approval-mode"), "Approval mode");
  EXPECT_EQ(description("gemini", {"--approval-mode"}, "auto_edit"), "Auto-approve edit tools");
  EXPECT_TRUE(contains(texts("gemini", {"mcp", "add", "--transport"}, ""), "http"));
}

// The query takes any number of free-text words, so a gemini line is never rejected.
TEST_F(SpecTest, GeminiAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("gemini", {"-m", "gemini-2.5-pro", "-p", "explain this"}), -1);
  EXPECT_EQ(firstInvalid("gemini", {"--approval-mode=plan", "fix", "the", "bug"}), -1);
  EXPECT_EQ(firstInvalid("gemini", {"mcp", "add", "-s", "user", "github", "npx", "github-server"}), -1);
  EXPECT_EQ(firstInvalid("gemini", {"extensions", "install", "https://github.com/org/ext", "--auto-update"}), -1);
}

TEST_F(SpecTest, AiderDescribesOptionsAndValues) {
  EXPECT_EQ(description("aider", {}, "--edit-format"), "Edit format the LLM should use");
  const auto formats = texts("aider", {"--edit-format"}, "");
  EXPECT_TRUE(contains(formats, "diff"));
  EXPECT_TRUE(contains(formats, "udiff-simple"));
}

TEST_F(SpecTest, AiderAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("aider", {"--model", "sonnet", "--no-auto-commits", "app.py"}), -1);
  EXPECT_EQ(firstInvalid("aider", {"-m", "add docstrings", "--yes-always", "src/main.py", "--read", "README.md"}), -1);
  EXPECT_EQ(firstInvalid("aider", {"--edit-format=whole", "--", "notes.txt"}), -1);
}

TEST_F(SpecTest, AiderRejectsUnknownOptionsAndValues) {
  EXPECT_EQ(firstInvalid("aider", {"--bogus"}), 0);
  EXPECT_EQ(firstInvalid("aider", {"--edit-format", "bogus"}), 1);
  EXPECT_EQ(firstInvalid("aider", {"app.py", "--map-refresh", "sometimes"}), 2);
}
} // namespace
