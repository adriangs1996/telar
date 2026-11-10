#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {
using spec_support::SpecTest;

// mvn: any word can be a plugin goal, so nothing is rejected.
TEST_F(SpecTest, MvnDescribesPhasesAndOptions) {
  EXPECT_EQ(description("mvn", {}, "package"), "Phase: package the compiled code");
  EXPECT_EQ(description("mvn", {}, "-pl"), "Build only these reactor projects, comma separated");
  EXPECT_TRUE(contains(texts("mvn", {}, "dependency:"), "dependency:tree"));
}

TEST_F(SpecTest, MvnAcceptsBuildLines) {
  EXPECT_EQ(firstInvalid("mvn", {"-B", "-ntp", "clean", "verify", "-DskipTests", "-Pci"}), -1);
  EXPECT_EQ(firstInvalid("mvn", {"-pl", "api", "-am", "-T", "1C", "spring-boot:run", "-f", "pom.xml"}), -1);
}

TEST_F(SpecTest, MvnOffersColorModes) {
  EXPECT_TRUE(contains(texts("mvn", {"--color"}, ""), "never"));
}

// gradle: any word can be a task or a task option, so nothing is rejected.
TEST_F(SpecTest, GradleDescribesTasksAndOptions) {
  EXPECT_EQ(description("gradle", {}, "bootRun"), "Run this project as a Spring Boot application");
  EXPECT_EQ(description("gradle", {"test"}, "--tests"), "Include this test class or method, * allowed");
}

TEST_F(SpecTest, GradleAcceptsBuildLines) {
  EXPECT_EQ(firstInvalid("gradle", {"--console=plain", "clean", "build", "-x", "test", "--parallel"}), -1);
  EXPECT_EQ(firstInvalid("gradle", {"test", "--tests", "com.example.FooTest", "-Penv=ci", ":app:check"}), -1);
  EXPECT_EQ(firstInvalid("gradle", {"init", "--type", "java-application", "--dsl", "kotlin"}), -1);
}

TEST_F(SpecTest, GradleOffersWarningModes) {
  EXPECT_TRUE(contains(texts("gradle", {}, "--warning-mode="), "--warning-mode=all"));
}

// composer: scripts of composer.json run as commands, so nothing is rejected.
TEST_F(SpecTest, ComposerDescribesCommands) {
  EXPECT_EQ(description("composer", {}, "require"), "Add packages to composer.json and install them");
  EXPECT_EQ(description("composer", {"install"}, "--no-dev"), "Leave out require-dev packages");
}

TEST_F(SpecTest, ComposerAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("composer", {"install", "--no-dev", "-o", "--prefer-dist", "--no-interaction"}), -1);
  EXPECT_EQ(firstInvalid("composer", {"require", "--dev", "phpunit/phpunit:^11", "-W"}), -1);
  EXPECT_EQ(firstInvalid("composer", {"-d", "app", "dump-autoload", "--optimize", "--classmap-authoritative"}), -1);
}

TEST_F(SpecTest, ComposerOffersAuditFormats) {
  EXPECT_TRUE(contains(texts("composer", {"audit", "--format"}, ""), "json"));
}

TEST_F(SpecTest, BundleDescribesCommands) {
  EXPECT_EQ(description("bundle", {}, "exec"), "Run a command in the context of the bundle");
  EXPECT_EQ(description("bundle", {"install"}, "--jobs"), "Jobs to run in parallel");
}

TEST_F(SpecTest, BundleAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("bundle", {"exec", "rspec", "spec/models"}), -1);
  EXPECT_EQ(firstInvalid("bundle", {"exec", "rails", "server", "-p", "4000"}), -1);
  EXPECT_EQ(firstInvalid("bundle", {"install", "-j4", "--gemfile=Gemfile.next", "--retry", "3"}), -1);
  EXPECT_EQ(firstInvalid("bundle", {"config", "set", "--local", "path", "vendor/bundle"}), -1);
}

TEST_F(SpecTest, BundleRejectsUnknownCommandsAndOptions) {
  EXPECT_EQ(firstInvalid("bundle", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("bundle", {"install", "--deployment"}), 1);
}

TEST_F(SpecTest, GemDescribesCommands) {
  EXPECT_EQ(description("gem", {}, "install"), "Install gems");
  EXPECT_EQ(description("gem", {"install"}, "-N"), "Do not generate documentation");
}

TEST_F(SpecTest, GemAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("gem", {"install", "rails", "-v", "8.0.3", "--no-document"}), -1);
  EXPECT_EQ(firstInvalid("gem", {"install", "pg", "--", "--with-pg-config=/opt/pg/bin/pg_config"}), -1);
  EXPECT_EQ(firstInvalid("gem", {"list", "--local", "^rails$"}), -1);
}

TEST_F(SpecTest, GemRejectsUnknownCommandsAndOptions) {
  EXPECT_EQ(firstInvalid("gem", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("gem", {"outdated", "--bogus"}), 1);
}

// rails: any rake task runs as a command, so nothing at the top is rejected.
TEST_F(SpecTest, RailsDescribesCommands) {
  EXPECT_EQ(description("rails", {}, "db:migrate"), "Migrate the database");
  EXPECT_EQ(description("rails", {"generate"}, "scaffold"), "Generate a full CRUD resource");
  EXPECT_EQ(description("rails", {"server"}, "--port"), "Port, 3000 by default");
}

TEST_F(SpecTest, RailsAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("rails", {"new", "blog", "-d", "postgresql", "--css=tailwind", "--skip-kamal"}), -1);
  EXPECT_EQ(firstInvalid("rails", {"g", "model", "User", "name:string", "--skip-collision-check"}), -1);
  EXPECT_EQ(firstInvalid("rails", {"s", "-b", "0.0.0.0", "-p", "3001", "-e", "production"}), -1);
  EXPECT_EQ(firstInvalid("rails", {"test", "test/models/user_test.rb:27", "--fail-fast"}), -1);
}

TEST_F(SpecTest, RailsOffersDatabases) {
  EXPECT_TRUE(contains(texts("rails", {"new", "blog", "--database"}, ""), "trilogy"));
}

TEST_F(SpecTest, RspecDescribesOptions) {
  EXPECT_EQ(description("rspec", {}, "--only-failures"), "Only run the examples that failed last time");
  EXPECT_TRUE(contains(texts("rspec", {"--format"}, ""), "documentation"));
}

TEST_F(SpecTest, RspecAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("rspec", {"spec/models/user_spec.rb:37", "--format", "documentation", "--order", "random:42"}), -1);
  EXPECT_EQ(firstInvalid("rspec", {"-t", "~slow", "--fail-fast=3", "spec/requests"}), -1);
}

TEST_F(SpecTest, RspecRejectsUnknownOptions) {
  EXPECT_EQ(firstInvalid("rspec", {"spec", "--bogus"}), 1);
}

// rake: any word can be a task, so nothing is rejected.
TEST_F(SpecTest, RakeDescribesOptions) {
  EXPECT_EQ(description("rake", {}, "-T"), "List the tasks matching a pattern");
  EXPECT_TRUE(contains(texts("rake", {"--trace"}, ""), "stdout"));
}

TEST_F(SpecTest, RakeAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("rake", {"-T", "db"}), -1);
  EXPECT_EQ(firstInvalid("rake", {"--trace", "db:migrate", "VERSION=20240101000000", "build[release]"}), -1);
}

TEST_F(SpecTest, RbenvDescribesCommands) {
  EXPECT_EQ(description("rbenv", {}, "local"), "Set or show the local Ruby version");
  EXPECT_EQ(description("rbenv", {"local"}, "system"), "The system Ruby");
}

TEST_F(SpecTest, RbenvAcceptsCommandLines) {
  EXPECT_EQ(firstInvalid("rbenv", {"install", "-s", "3.3.6"}), -1);
  EXPECT_EQ(firstInvalid("rbenv", {"exec", "bundle", "install"}), -1);
  EXPECT_EQ(firstInvalid("rbenv", {"init", "-", "--no-rehash", "zsh"}), -1);
}

TEST_F(SpecTest, RbenvRejectsUnknownCommandsAndOptions) {
  EXPECT_EQ(firstInvalid("rbenv", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("rbenv", {"versions", "--all"}), 1);
}

}
