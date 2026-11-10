#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {
  using spec_support::SpecTest;

  // gh

  TEST_F(SpecTest, GhDescribesCommands) {
    EXPECT_EQ(description("gh", {"pr"}, "create"), "Create a pull request");
  }

  TEST_F(SpecTest, GhAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("gh", {"pr", "create", "--base", "main", "--fill"}), -1);
    EXPECT_EQ(firstInvalid("gh", {"run", "list", "--status=failure", "--limit", "5"}), -1);
    EXPECT_EQ(firstInvalid("gh", {"release", "create", "v1.2.0", "--generate-notes", "--target", "main"}), -1);
  }

  TEST_F(SpecTest, GhRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("gh", {"pr", "create", "--bogus"}), 2);
    EXPECT_EQ(firstInvalid("gh", {"pr", "frobnicate"}), 1);
  }

  // aws

  TEST_F(SpecTest, AwsDescribesServices) {
    EXPECT_EQ(description("aws", {}, "ec2"), "Amazon Elastic Compute Cloud");
  }

  TEST_F(SpecTest, AwsAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("aws", {"s3", "cp", "./build", "s3://my-bucket/build", "--recursive", "--exclude", "*.map", "--profile", "prod"}), -1);
    EXPECT_EQ(firstInvalid("aws", {"--region", "eu-west-1", "ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=running", "--output", "table"}), -1);
    EXPECT_EQ(firstInvalid("aws", {"eks", "update-kubeconfig", "--name", "prod", "--region", "us-east-1"}), -1);
  }

  TEST_F(SpecTest, AwsRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("aws", {"sts", "get-caller-identity", "--bogus"}), 2);
    EXPECT_EQ(firstInvalid("aws", {"s3", "frobnicate"}), 1);
  }

  // brew

  TEST_F(SpecTest, BrewDescribesCommands) {
    EXPECT_EQ(description("brew", {}, "install"), "Install a formula or cask");
    EXPECT_EQ(description("brew", {"services"}, "restart"), "Restart a service and run it at login");
  }

  TEST_F(SpecTest, BrewAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("brew", {"install", "--cask", "--appdir=/Applications", "firefox"}), -1);
    EXPECT_EQ(firstInvalid("brew", {"upgrade", "--greedy", "-n"}), -1);
    EXPECT_EQ(firstInvalid("brew", {"services", "restart", "postgresql@16"}), -1);
    EXPECT_EQ(firstInvalid("brew", {"bundle", "dump", "--file=Brewfile", "--force"}), -1);
  }

  TEST_F(SpecTest, BrewRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("brew", {"frobnicate"}), 0);
    EXPECT_EQ(firstInvalid("brew", {"update", "--bogus"}), 1);
  }

  // apt

  TEST_F(SpecTest, AptDescribesCommands) {
    EXPECT_EQ(description("apt", {}, "full-upgrade"), "Upgrade installed packages, removing some if needed");
  }

  TEST_F(SpecTest, AptAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("apt", {"install", "-y", "--no-install-recommends", "curl", "git=1:2.47.2-0.1"}), -1);
    EXPECT_EQ(firstInvalid("apt", {"-o=Acquire::Retries=3", "update", "-q"}), -1);
    EXPECT_EQ(firstInvalid("apt", {"list", "--upgradable"}), -1);
  }

  TEST_F(SpecTest, AptRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("apt", {"frobnicate"}), 0);
    EXPECT_EQ(firstInvalid("apt", {"update", "--bogus"}), 1);
  }

  // dnf

  TEST_F(SpecTest, DnfDescribesCommands) {
    EXPECT_EQ(description("dnf", {}, "install"), "Install software");
  }

  TEST_F(SpecTest, DnfAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("dnf", {"install", "-y", "--setopt=install_weak_deps=False", "vim-enhanced"}), -1);
    EXPECT_EQ(firstInvalid("dnf", {"--refresh", "upgrade", "--security", "--repo", "fedora"}), -1);
    EXPECT_EQ(firstInvalid("dnf", {"repoquery", "--whatrequires", "bash", "--qf", "%{name}"}), -1);
  }

  TEST_F(SpecTest, DnfRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("dnf", {"frobnicate"}), 0);
    EXPECT_EQ(firstInvalid("dnf", {"clean", "bogus"}), 1);
  }

  // pacman

  TEST_F(SpecTest, PacmanDescribesOperations) {
    EXPECT_EQ(description("pacman", {}, "-S"), "Sync: install and search repository packages");
  }

  TEST_F(SpecTest, PacmanAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("pacman", {"-Syu", "--needed", "git"}), -1);
    EXPECT_EQ(firstInvalid("pacman", {"-Qo", "/usr/bin/ls"}), -1);
    EXPECT_EQ(firstInvalid("pacman", {"-Rns", "--noconfirm", "foo"}), -1);
  }

  TEST_F(SpecTest, PacmanRejectsUnknownOperations) {
    EXPECT_EQ(firstInvalid("pacman", {"--frobnicate"}), 0);
    EXPECT_EQ(firstInvalid("pacman", {"-U", "--refresh"}), 1);
  }

  // openssl

  TEST_F(SpecTest, OpensslDescribesCommands) {
    EXPECT_EQ(description("openssl", {}, "s_client"), "Connect to a TLS server");
    EXPECT_EQ(description("openssl", {"x509"}, "-noout"), "No output (except for requested printing)");
  }

  TEST_F(SpecTest, OpensslAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("openssl", {"req", "-x509", "-newkey", "rsa:2048", "-noenc", "-keyout", "key.pem", "-out", "cert.pem", "-days", "365", "-subj", "/CN=localhost", "-sha256"}), -1);
    EXPECT_EQ(firstInvalid("openssl", {"s_client", "-connect", "example.com:443", "-servername", "example.com", "-showcerts"}), -1);
    EXPECT_EQ(firstInvalid("openssl", {"x509", "-in", "cert.pem", "-noout", "-text", "-outform", "pem"}), -1);
    EXPECT_EQ(firstInvalid("openssl", {"enc", "-aes-256-cbc", "-pbkdf2", "-in", "a", "-out", "a.enc"}), -1);
  }

  TEST_F(SpecTest, OpensslRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("openssl", {"frobnicate"}), 0);
    EXPECT_EQ(firstInvalid("openssl", {"x509", "-bogus"}), 1);
  }

  // ansible and ansible-playbook

  TEST_F(SpecTest, AnsibleDescribesOptions) {
    EXPECT_EQ(description("ansible", {"all"}, "--become"), "Run operations with become");
    EXPECT_EQ(description("ansible-playbook", {"site.yml"}, "--syntax-check"), "Check the playbook syntax without running it");
  }

  TEST_F(SpecTest, AnsibleAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("ansible", {"all", "-i", "inventory.ini", "-m", "ping"}), -1);
    EXPECT_EQ(firstInvalid("ansible", {"webservers", "-b", "-m", "apt", "-a", "name=nginx state=present", "--forks=10"}), -1);
    EXPECT_EQ(firstInvalid("ansible-playbook", {"-i", "hosts", "site.yml", "--tags", "deploy", "--check", "--diff", "-e", "env=prod"}), -1);
  }

  TEST_F(SpecTest, AnsibleRejectsUnknownOptions) {
    EXPECT_EQ(firstInvalid("ansible", {"all", "--bogus"}), 1);
    EXPECT_EQ(firstInvalid("ansible-playbook", {"site.yml", "--module-name", "ping"}), 1);
  }

  // az

  TEST_F(SpecTest, AzDescribesCommands) {
    EXPECT_EQ(description("az", {}, "login"), "Log in to Azure");
    EXPECT_EQ(description("az", {"vm"}, "create"), "Create an Azure Virtual Machine");
  }

  TEST_F(SpecTest, AzAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("az", {"vm", "create", "-g", "rg", "-n", "web1", "--image", "Ubuntu2204", "--generate-ssh-keys", "--admin-username", "azureuser", "-o", "table"}), -1);
    EXPECT_EQ(firstInvalid("az", {"group", "create", "--name", "rg", "--location", "westeurope", "--tags", "env=dev", "team=core", "--output=json"}), -1);
    EXPECT_EQ(firstInvalid("az", {"--debug", "keyvault", "secret", "show", "--vault-name", "kv", "-n", "db-password", "--query", "value", "-otsv"}), -1);
  }

  TEST_F(SpecTest, AzRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("az", {"vm", "list", "--bogus"}), 2);
    EXPECT_EQ(firstInvalid("az", {"vm", "frobnicate"}), 1);
    EXPECT_EQ(firstInvalid("az", {"vm", "create", "--authentication-type", "kerberos"}), 3);
  }

  // gcloud

  TEST_F(SpecTest, GcloudDescribesGroups) {
    EXPECT_EQ(description("gcloud", {}, "compute"), "Create and manipulate Compute Engine resources");
    EXPECT_EQ(description("gcloud", {}, "--quiet"), "Disable all interactive prompts");
  }

  TEST_F(SpecTest, GcloudAcceptsCommonLines) {
    EXPECT_EQ(firstInvalid("gcloud", {"compute", "instances", "create", "my-vm", "--zone=us-central1-a", "--machine-type", "e2-medium", "--image-family=debian-12", "--image-project=debian-cloud", "--tags=http-server"}), -1);
    EXPECT_EQ(firstInvalid("gcloud", {"--project", "my-proj", "container", "clusters", "get-credentials", "prod", "--region", "us-central1"}), -1);
  }

  TEST_F(SpecTest, GcloudRejectsUnknownWords) {
    EXPECT_EQ(firstInvalid("gcloud", {"projects", "lsit"}), 1);
    EXPECT_EQ(firstInvalid("gcloud", {"container", "clusters", "list", "--bogus"}), 3);
  }
}
