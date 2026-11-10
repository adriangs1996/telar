#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {
using spec_support::SpecTest;

// go

TEST_F(SpecTest, GoCommandsAndDescriptions) {
  EXPECT_EQ(description("go", {}, "build"), "Compile packages and dependencies");
  EXPECT_TRUE(contains(texts("go", {"mod"}, ""), "tidy"));
  EXPECT_TRUE(contains(texts("go", {"test"}, "-cover"), "-coverprofile"));
  EXPECT_TRUE(contains(texts("go", {"build"}, ""), "@directory"));
}

TEST_F(SpecTest, GoAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("go", {"build", "-o", "bin/app", "-ldflags=-s -w", "-trimpath", "./cmd/app"}), -1);
  EXPECT_EQ(firstInvalid("go", {"test", "-race", "./...", "-run", "TestParse", "-count=1", "-v"}), -1);
  EXPECT_EQ(firstInvalid("go", {"run", "main.go", "--port", "8080"}), -1);
  EXPECT_EQ(firstInvalid("go", {"get", "-u", "golang.org/x/tools@latest"}), -1);
  EXPECT_EQ(firstInvalid("go", {"mod", "edit", "-replace=example.com/a=../a"}), -1);
  EXPECT_EQ(firstInvalid("go", {"test", "./pkg", "-args", "-custom", "flag"}), -1);
}

TEST_F(SpecTest, GoRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("go", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("go", {"build", "-frob"}), 1);
  // go build reads flags after a package as packages and fails.
  EXPECT_EQ(firstInvalid("go", {"build", ".", "-v"}), 2);
}

// cargo

TEST_F(SpecTest, CargoCommandsAndDescriptions) {
  EXPECT_EQ(description("cargo", {}, "build"), "Compile the current package");
  EXPECT_EQ(description("cargo", {"build"}, "--release"), "Build in release mode, with optimizations");
  EXPECT_TRUE(contains(texts("cargo", {"test", "--"}, "--no"), "--nocapture"));
  EXPECT_TRUE(contains(texts("cargo", {"build", "--target"}, "wasm"), "wasm32-unknown-unknown"));
}

TEST_F(SpecTest, CargoAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("cargo", {"+nightly", "build", "--release", "-p", "core", "--features", "serde"}), -1);
  EXPECT_EQ(firstInvalid("cargo", {"test", "--workspace", "parser", "--", "--nocapture", "--test-threads=1"}), -1);
  EXPECT_EQ(firstInvalid("cargo", {"run", "--bin", "server", "--", "--port", "80"}), -1);
  EXPECT_EQ(firstInvalid("cargo", {"clippy", "--all-targets", "--", "-D", "warnings"}), -1);
  EXPECT_EQ(firstInvalid("cargo", {"add", "serde", "--features", "derive", "--dev"}), -1);
  // External cargo-<name> commands take any arguments.
  EXPECT_EQ(firstInvalid("cargo", {"nextest", "run", "--no-fail-fast"}), -1);
}

TEST_F(SpecTest, CargoOffersOnlyTheCommandsOptions) {
  // External commands make every line valid, so check what Tab offers instead.
  EXPECT_FALSE(contains(texts("cargo", {"build"}, "--"), "--no-run"));
  EXPECT_TRUE(contains(texts("cargo", {"test"}, "--"), "--no-run"));
}

// rustup

TEST_F(SpecTest, RustupCommandsAndDescriptions) {
  EXPECT_EQ(description("rustup", {}, "default"), "Set the default toolchain");
  EXPECT_TRUE(contains(texts("rustup", {"component", "add"}, "rust-"), "rust-analyzer"));
  EXPECT_TRUE(contains(texts("rustup", {"toolchain"}, ""), "install"));
}

TEST_F(SpecTest, RustupAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("rustup", {"toolchain", "install", "nightly", "--profile", "minimal", "-c", "rust-src"}), -1);
  EXPECT_EQ(firstInvalid("rustup", {"target", "add", "wasm32-unknown-unknown", "--toolchain", "stable"}), -1);
  EXPECT_EQ(firstInvalid("rustup", {"run", "nightly", "cargo", "build", "--release"}), -1);
  EXPECT_EQ(firstInvalid("rustup", {"+beta", "show", "active-toolchain"}), -1);
}

TEST_F(SpecTest, RustupRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("rustup", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("rustup", {"component", "list", "--frob"}), 2);
  EXPECT_EQ(firstInvalid("rustup", {"set", "profile", "huge"}), 2);
}

// zig

TEST_F(SpecTest, ZigCommandsAndDescriptions) {
  EXPECT_EQ(description("zig", {}, "build"), "Build the project from build.zig");
  EXPECT_TRUE(contains(texts("zig", {"build"}, "-Doptimize="), "-Doptimize=ReleaseSafe"));
  EXPECT_TRUE(contains(texts("zig", {"build-exe", "-O"}, ""), "ReleaseFast"));
}

TEST_F(SpecTest, ZigAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("zig", {"build", "-Doptimize=ReleaseFast", "--summary", "all", "test", "-j8"}), -1);
  EXPECT_EQ(firstInvalid("zig", {"build", "run", "--", "--port", "80"}), -1);
  EXPECT_EQ(firstInvalid("zig", {"build-exe", "main.zig", "-O", "ReleaseSmall", "-target", "x86_64-linux-musl", "-lc"}), -1);
  EXPECT_EQ(firstInvalid("zig", {"fmt", "--check", "src"}), -1);
  EXPECT_EQ(firstInvalid("zig", {"fetch", "--save", "git+https://example.com/pkg.git"}), -1);
}

TEST_F(SpecTest, ZigRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("zig", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("zig", {"fmt", "--frob"}), 1);
  EXPECT_EQ(firstInvalid("zig", {"init", "--frob"}), 1);
}

// cmake

TEST_F(SpecTest, CmakeModesAndDescriptions) {
  EXPECT_EQ(description("cmake", {}, "--build"), "Build a CMake-generated binary tree");
  EXPECT_TRUE(contains(texts("cmake", {"-G"}, "Ninja"), "Ninja Multi-Config"));
  EXPECT_TRUE(contains(texts("cmake", {}, "-DCMAKE_BUILD_TYPE="), "-DCMAKE_BUILD_TYPE=RelWithDebInfo"));
  EXPECT_TRUE(contains(texts("cmake", {"-E"}, "copy_"), "copy_if_different"));
}

TEST_F(SpecTest, CmakeAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("cmake", {"-S", ".", "-B", "build", "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-Wno-dev"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"-Bbuild", "--preset=debug", "--fresh"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"--build", "build", "-j8", "--target", "app", "tests", "--config", "Release"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"--build", "--preset", "debug", "--", "-k", "0"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"--install", "build", "--prefix", "/usr/local", "--strip"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"--workflow", "--preset", "ci", "--fresh"}), -1);
  EXPECT_EQ(firstInvalid("cmake", {"-DVAR=1", "-P", "script.cmake"}), -1);
}

TEST_F(SpecTest, CmakeRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("cmake", {"--frob"}), 0);
  EXPECT_EQ(firstInvalid("cmake", {"--install", "build", "--frob"}), 2);
  EXPECT_EQ(firstInvalid("cmake", {"-E", "frobnicate"}), 1);
}

// ninja

TEST_F(SpecTest, NinjaOptionsAndDescriptions) {
  EXPECT_EQ(description("ninja", {"-t"}, "compdb"), "Dump a JSON compilation database");
  EXPECT_TRUE(contains(texts("ninja", {"-d"}, ""), "explain"));
}

TEST_F(SpecTest, NinjaAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("ninja", {"-C", "build", "-j8", "-k", "0", "app"}), -1);
  EXPECT_EQ(firstInvalid("ninja", {"-C", "build", "-t", "compdb", "-x"}), -1);
  EXPECT_EQ(firstInvalid("ninja", {"-v", "-d", "explain", "src/main.o"}), -1);
}

TEST_F(SpecTest, NinjaRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("ninja", {"--frob"}), 0);
  EXPECT_EQ(firstInvalid("ninja", {"-t", "frobnicate"}), 1);
  EXPECT_EQ(firstInvalid("ninja", {"-d", "frob"}), 1);
}

// just

TEST_F(SpecTest, JustRecipesAndDescriptions) {
  EXPECT_TRUE(contains(texts("just", {}, ""), "@just_recipe"));
  EXPECT_TRUE(contains(texts("just", {"--show"}, ""), "@just_recipe"));
  EXPECT_EQ(description("just", {}, "--list"), "List the recipes, or those of a module");
}

TEST_F(SpecTest, JustAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("just", {"--list"}), -1);
  EXPECT_EQ(firstInvalid("just", {"-f", "ci.just", "--dry-run", "test", "--verbose", "unit"}), -1);
  EXPECT_EQ(firstInvalid("just", {"--set", "profile", "release", "build"}), -1);
  EXPECT_EQ(firstInvalid("just", {"--command", "ls", "-la"}), -1);
}

TEST_F(SpecTest, JustRejectsUnknownOptions) {
  EXPECT_EQ(firstInvalid("just", {"--frob"}), 0);
  EXPECT_EQ(firstInvalid("just", {"--color", "purple"}), 1);
}
}
