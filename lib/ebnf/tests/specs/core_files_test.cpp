#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {

using spec_support::SpecTest;

TEST_F(SpecTest, LsOptionsAndDescriptions) {
  EXPECT_EQ(description("ls", {}, "--group-directories-first"), "Group directories before files");
  EXPECT_TRUE(contains(texts("ls", {"--sort"}, ""), "version"));
  EXPECT_EQ(firstInvalid("ls", {"-la", "--color=auto", "src"}), -1);
  EXPECT_EQ(firstInvalid("ls", {"-lhtr", "--time-style", "long-iso", "-I", "*.o", "/tmp"}), -1);
  EXPECT_EQ(firstInvalid("ls", {"-l", "--frobnicate"}), 1);
}

TEST_F(SpecTest, EzaOptionsAndDescriptions) {
  EXPECT_EQ(description("eza", {}, "--git"), "List each file's Git status");
  EXPECT_TRUE(contains(texts("eza", {"--sort"}, ""), "modified"));
  EXPECT_EQ(firstInvalid("eza", {"-la", "--git", "--icons", "src"}), -1);
  EXPECT_EQ(firstInvalid("eza", {"-T", "-L", "2", "--sort=modified", "--color=always"}), -1);
  EXPECT_EQ(firstInvalid("eza", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, GrepOptionsAndDescriptions) {
  EXPECT_EQ(description("grep", {}, "--line-number"), "Print line numbers");
  EXPECT_TRUE(contains(texts("grep", {"--binary-files"}, ""), "without-match"));
  EXPECT_EQ(firstInvalid("grep", {"-rn", "--include=*.cpp", "TODO", "src"}), -1);
  EXPECT_EQ(firstInvalid("grep", {"-i", "-C", "3", "-e", "-flag", "file.txt"}), -1);
  EXPECT_EQ(firstInvalid("grep", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, RgOptionsAndDescriptions) {
  EXPECT_EQ(description("rg", {}, "--hidden"), "Search hidden files and directories");
  EXPECT_TRUE(contains(texts("rg", {"-t"}, "c"), "cpp"));
  EXPECT_EQ(firstInvalid("rg", {"-i", "--hidden", "pattern", "src"}), -1);
  EXPECT_EQ(firstInvalid("rg", {"-t", "rust", "-g", "!target", "--sort=path", "-e", "-foo"}), -1);
  EXPECT_EQ(firstInvalid("rg", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, FindOptionsAndDescriptions) {
  EXPECT_EQ(description("find", {"."}, "-maxdepth"), "Descend at most this many levels");
  EXPECT_TRUE(contains(texts("find", {".", "-type"}, ""), "f"));
  EXPECT_TRUE(contains(texts("find", {".", "-exec", "rm", "{}"}, ""), ";"));
  EXPECT_EQ(firstInvalid("find", {".", "-name", "*.cpp", "-type", "f", "-exec", "rm", "{}", ";"}), -1);
  EXPECT_EQ(firstInvalid("find", {"-L", "src", "(", "-iname", "a", "-o", "-mtime", "-2", ")", "-print0"}), -1);
  EXPECT_EQ(firstInvalid("find", {".", "-frobnicate"}), 1);
}

TEST_F(SpecTest, FdOptionsAndDescriptions) {
  EXPECT_EQ(description("fd", {}, "--hidden"), "Search hidden files and directories");
  EXPECT_TRUE(contains(texts("fd", {"-t"}, ""), "directory"));
  EXPECT_EQ(firstInvalid("fd", {"-H", "-e", "rs", "main", "src"}), -1);
  EXPECT_EQ(firstInvalid("fd", {"-t", "f", "-x", "rm", "{}", ";", "-H"}), -1);
  EXPECT_EQ(firstInvalid("fd", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, SedOptionsAndDescriptions) {
  EXPECT_EQ(description("sed", {}, "-n"), "Do not print the pattern space automatically");
  EXPECT_EQ(firstInvalid("sed", {"-i.bak", "-e", "s/a/b/", "file.txt"}), -1);
  EXPECT_EQ(firstInvalid("sed", {"-n", "-E", "s/x/y/p", "in.txt"}), -1);
  EXPECT_EQ(firstInvalid("sed", {"-i", ".bak", "s/a/b/", "file.txt"}), -1);
  EXPECT_EQ(firstInvalid("sed", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, AwkOptionsAndDescriptions) {
  EXPECT_EQ(description("awk", {}, "-F"), "Input field separator");
  EXPECT_EQ(firstInvalid("awk", {"-F", ":", "-v", "OFS=,", "{print $1}", "/etc/passwd"}), -1);
  EXPECT_EQ(firstInvalid("awk", {"--lint=fatal", "-f", "prog.awk", "data.txt"}), -1);
  EXPECT_EQ(firstInvalid("awk", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, XargsOptionsAndDescriptions) {
  EXPECT_EQ(description("xargs", {}, "-0"), "Input items are separated by NUL");
  EXPECT_EQ(firstInvalid("xargs", {"-0", "-n", "1", "-P", "4", "rm", "-f"}), -1);
  EXPECT_EQ(firstInvalid("xargs", {"-I", "{}", "mv", "{}", "{}.bak"}), -1);
  EXPECT_EQ(firstInvalid("xargs", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, JqOptionsAndDescriptions) {
  EXPECT_EQ(description("jq", {}, "--raw-output"), "Print strings without quotes");
  EXPECT_EQ(firstInvalid("jq", {"-r", ".items[]", "data.json"}), -1);
  EXPECT_EQ(firstInvalid("jq", {"-n", "--arg", "name", "value", "$name"}), -1);
  EXPECT_EQ(firstInvalid("jq", {".", "--frobnicate"}), 1);
}

TEST_F(SpecTest, TarOptionsAndDescriptions) {
  EXPECT_EQ(description("tar", {}, "--strip-components"), "Strip this many leading components from names");
  EXPECT_TRUE(contains(texts("tar", {}, "xz"), "xzf"));
  EXPECT_EQ(firstInvalid("tar", {"xzf", "archive.tar.gz", "-C", "out"}), -1);
  EXPECT_EQ(firstInvalid("tar", {"-czvf", "out.tgz", "--exclude=*.o", "src"}), -1);
  EXPECT_EQ(firstInvalid("tar", {"-x", "--frobnicate"}), 1);
}

}
