#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {

using spec_support::SpecTest;

TEST_F(SpecTest, NpmRunsScripts) {
  EXPECT_TRUE(contains(texts("npm", {"run"}, ""), "@package_script"));
  EXPECT_EQ(description("npm", {}, "ci"), "Clean install from the lockfile");
  EXPECT_EQ(firstInvalid("npm", {"install", "--save-dev", "typescript"}), -1);
  EXPECT_EQ(firstInvalid("npm", {"ci", "--omit=dev", "--no-audit"}), -1);
  EXPECT_EQ(firstInvalid("npm", {"run", "build", "--", "--watch"}), -1);
}

TEST_F(SpecTest, NpmRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("npm", {"instal"}), 0);
  EXPECT_EQ(firstInvalid("npm", {"ci", "--bogus"}), 1);
}

TEST_F(SpecTest, NpxPassesTheRestToThePackage) {
  EXPECT_EQ(description("npx", {}, "--yes"), "Install missing packages without asking");
  EXPECT_EQ(firstInvalid("npx", {"-y", "create-vite@latest", "app", "--template", "react"}), -1);
  EXPECT_EQ(firstInvalid("npx", {"--package=typescript", "tsc", "--version"}), -1);
}

TEST_F(SpecTest, PnpmCommandsAndScripts) {
  EXPECT_TRUE(contains(texts("pnpm", {}, ""), "@package_script"));
  EXPECT_TRUE(contains(texts("pnpm", {"run"}, ""), "@package_script"));
  EXPECT_EQ(description("pnpm", {}, "dlx"), "Run a package in a temporary environment");
  EXPECT_EQ(firstInvalid("pnpm", {"add", "-D", "typescript"}), -1);
  EXPECT_EQ(firstInvalid("pnpm", {"--filter", "web", "run", "build"}), -1);
  EXPECT_EQ(firstInvalid("pnpm", {"install", "--frozen-lockfile", "--node-linker=hoisted"}), -1);
  // Any first word may be a script, so only options before it can be wrong.
  EXPECT_EQ(firstInvalid("pnpm", {"--bogus", "install"}), 0);
}

TEST_F(SpecTest, YarnClassicCommands) {
  EXPECT_TRUE(contains(texts("yarn", {}, ""), "@package_script"));
  EXPECT_EQ(description("yarn", {}, "upgrade-interactive"), "Pick outdated packages to upgrade");
  EXPECT_EQ(firstInvalid("yarn", {"add", "--dev", "typescript"}), -1);
  EXPECT_EQ(firstInvalid("yarn", {"install", "--frozen-lockfile", "--ignore-engines"}), -1);
  EXPECT_EQ(firstInvalid("yarn", {"--bogus", "install"}), 0);
}

TEST_F(SpecTest, BunRunsFilesAndScripts) {
  const auto run = texts("bun", {"run"}, "");
  EXPECT_TRUE(contains(run, "@package_script"));
  EXPECT_TRUE(contains(run, "@file"));
  EXPECT_EQ(description("bun", {}, "x"), "Run a package binary, installing it if needed");
  EXPECT_EQ(firstInvalid("bun", {"run", "--watch", "dev"}), -1);
  EXPECT_EQ(firstInvalid("bun", {"add", "-d", "@types/bun"}), -1);
  EXPECT_EQ(firstInvalid("bun", {"test", "--coverage", "--bail=3"}), -1);
  EXPECT_EQ(firstInvalid("bun", {"--bogus", "build"}), 0);
}

TEST_F(SpecTest, NodeOptionsBeforeTheScript) {
  EXPECT_EQ(description("node", {}, "--watch"), "Restart when files change");
  EXPECT_EQ(firstInvalid("node", {"--inspect-brk", "server.js", "--port", "3000"}), -1);
  EXPECT_EQ(firstInvalid("node", {"--test", "--test-reporter=spec"}), -1);
  EXPECT_EQ(firstInvalid("node", {"-e", "console.log(1)"}), -1);
  EXPECT_EQ(firstInvalid("node", {"--bogus", "app.js"}), 0);
}

TEST_F(SpecTest, DenoPermissionsAndCommands) {
  EXPECT_EQ(description("deno", {}, "task"), "Run a task from the config file");
  EXPECT_EQ(firstInvalid("deno", {"run", "-A", "--watch", "main.ts"}), -1);
  EXPECT_EQ(firstInvalid("deno", {"test", "--allow-read=.", "--coverage"}), -1);
  EXPECT_EQ(firstInvalid("deno", {"--bogus", "fmt"}), 0);
}

TEST_F(SpecTest, PythonModulesAndPrograms) {
  EXPECT_EQ(description("python", {"-m"}, "venv"), "Create a virtual environment");
  EXPECT_EQ(firstInvalid("python", {"-m", "venv", ".venv"}), -1);
  EXPECT_EQ(firstInvalid("python", {"-X", "dev", "-W", "error", "script.py", "--flag"}), -1);
  EXPECT_EQ(firstInvalid("python", {"-OO", "-c", "print(1)"}), -1);
  EXPECT_EQ(firstInvalid("python", {"--bogus"}), 0);
}

TEST_F(SpecTest, Python3IsPython) {
  EXPECT_EQ(description("python3", {"-X"}, "dev"), "Enable the Python Development Mode");
  EXPECT_EQ(firstInvalid("python3", {"-m", "http.server", "8000"}), -1);
  EXPECT_EQ(firstInvalid("python3", {"-u", "main.py"}), -1);
  EXPECT_EQ(firstInvalid("python3", {"--bogus"}), 0);
}

TEST_F(SpecTest, PipCommands) {
  EXPECT_EQ(description("pip", {}, "freeze"), "Output installed packages in requirements format");
  EXPECT_EQ(firstInvalid("pip", {"install", "-r", "requirements.txt", "--upgrade"}), -1);
  EXPECT_EQ(firstInvalid("pip", {"list", "--outdated", "--format=json"}), -1);
  EXPECT_EQ(firstInvalid("pip", {"list", "--bogus"}), 1);
}

TEST_F(SpecTest, Pip3IsPip) {
  EXPECT_EQ(description("pip3", {}, "uninstall"), "Uninstall packages");
  EXPECT_EQ(firstInvalid("pip3", {"install", "--user", "requests"}), -1);
  EXPECT_EQ(firstInvalid("pip3", {"show", "-f", "requests"}), -1);
  EXPECT_EQ(firstInvalid("pip3", {"freeze", "--bogus"}), 1);
}

TEST_F(SpecTest, UvProjectAndPipCommands) {
  EXPECT_EQ(description("uv", {}, "sync"), "Update the project environment");
  EXPECT_EQ(firstInvalid("uv", {"run", "--with", "rich", "python", "-m", "rich"}), -1);
  EXPECT_EQ(firstInvalid("uv", {"add", "--dev", "pytest"}), -1);
  EXPECT_EQ(firstInvalid("uv", {"pip", "install", "-e", ".", "--resolution=lowest"}), -1);
  EXPECT_EQ(firstInvalid("uv", {"tool", "run", "ruff", "check", "--fix"}), -1);
  EXPECT_EQ(firstInvalid("uv", {"sync", "--all-extras", "--group", "docs", "--locked", "--python", "3.12", "-U", "--index-strategy",
                                 "unsafe-best-match", "--no-build-isolation", "--refresh", "--link-mode=copy", "-q", "--compile-bytecode",
                                 "--no-install-project", "--exclude-newer", "2026-01-01"}),
            -1);
  EXPECT_EQ(firstInvalid("uv", {"sync", "--bogus"}), 1);
}

TEST_F(SpecTest, PoetryCommands) {
  EXPECT_EQ(description("poetry", {}, "sync"), "Sync the environment with poetry.lock");
  EXPECT_EQ(firstInvalid("poetry", {"add", "-G", "dev", "pytest"}), -1);
  EXPECT_EQ(firstInvalid("poetry", {"install", "--no-root", "--with=docs"}), -1);
  EXPECT_EQ(firstInvalid("poetry", {"lock", "--bogus"}), 1);
}

} // namespace
