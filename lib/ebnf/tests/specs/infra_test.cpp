#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {
using spec_support::SpecTest;

// docker

TEST_F(SpecTest, DockerCommandsAndDescriptions) {
  EXPECT_EQ(description("docker", {}, "run"), "Create and run a new container from an image");
  EXPECT_EQ(description("docker", {"run"}, "--rm"), "Remove the container and its anonymous volumes when it exits");
  EXPECT_TRUE(contains(texts("docker", {"run", "--restart"}, ""), "unless-stopped"));
  EXPECT_TRUE(contains(texts("docker", {"build"}, ""), "@directory"));
  EXPECT_TRUE(contains(texts("docker", {"network"}, ""), "prune"));
}

TEST_F(SpecTest, DockerComposeServices) {
  EXPECT_TRUE(contains(texts("docker", {"compose", "logs"}, ""), "@compose_service"));
  EXPECT_TRUE(contains(texts("docker", {"compose", "-f", "compose.yaml", "up", "-d"}, ""), "@compose_service"));
  EXPECT_TRUE(contains(texts("docker", {"compose", "exec"}, ""), "@compose_service"));
}

TEST_F(SpecTest, DockerAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("docker", {"run", "-it", "--rm", "-p", "8080:80", "-v", "/tmp:/data", "--name=web", "nginx:1.27", "nginx", "-g", "daemon off;"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"exec", "-it", "web", "sh", "-c", "ls -la"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"build", "-t", "app:dev", "-f", "Dockerfile", "--build-arg", "A=1", "--progress=plain", "."}), -1);
  EXPECT_EQ(firstInvalid("docker", {"ps", "-aq", "--filter", "status=exited"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"--context", "remote", "logs", "-f", "--tail", "100", "web"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"compose", "-p", "demo", "up", "-d", "--build", "web", "db"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"compose", "run", "--rm", "web", "bundle", "exec", "rspec", "--fail-fast"}), -1);
  EXPECT_EQ(firstInvalid("docker", {"system", "prune", "-af", "--volumes"}), -1);
}

TEST_F(SpecTest, DockerRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("docker", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("docker", {"ps", "--frob"}), 1);
  EXPECT_EQ(firstInvalid("docker", {"compose", "down", "--frob"}), 2);
  // Global options come before the command.
  EXPECT_EQ(firstInvalid("docker", {"ps", "--context", "x"}), 1);
}

// docker-compose

TEST_F(SpecTest, DockerComposeStandaloneCommands) {
  EXPECT_EQ(description("docker-compose", {}, "up"), "Create and start containers");
  EXPECT_TRUE(contains(texts("docker-compose", {"restart"}, ""), "@compose_service"));
  EXPECT_TRUE(contains(texts("docker-compose", {"--ansi"}, ""), "never"));
}

TEST_F(SpecTest, DockerComposeStandaloneAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("docker-compose", {"-f", "docker-compose.yml", "--profile", "dev", "up", "-d", "--remove-orphans"}), -1);
  EXPECT_EQ(firstInvalid("docker-compose", {"logs", "-f", "--tail=50", "web"}), -1);
  EXPECT_EQ(firstInvalid("docker-compose", {"exec", "-T", "db", "psql", "-U", "postgres"}), -1);
}

TEST_F(SpecTest, DockerComposeStandaloneRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("docker-compose", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("docker-compose", {"up", "--frob"}), 1);
}

// kubectl

TEST_F(SpecTest, KubectlCommandsAndDescriptions) {
  EXPECT_EQ(description("kubectl", {}, "get"), "Display one or many resources");
  EXPECT_EQ(description("kubectl", {"get"}, "deploy"), "Deployments");
  EXPECT_TRUE(contains(texts("kubectl", {"get"}, "po"), "pods"));
  EXPECT_TRUE(contains(texts("kubectl", {"get", "pods", "-o"}, ""), "yaml"));
  EXPECT_TRUE(contains(texts("kubectl", {"rollout"}, ""), "restart"));
  EXPECT_TRUE(contains(texts("kubectl", {"config"}, ""), "use-context"));
  EXPECT_TRUE(contains(texts("kubectl", {"apply", "-f"}, ""), "@file"));
}

TEST_F(SpecTest, KubectlAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("kubectl", {"get", "pods", "-n", "kube-system", "-o", "wide", "--watch"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"-n", "prod", "get", "deploy/web", "-o", "jsonpath={.spec.replicas}"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"apply", "-f", "k8s/", "--dry-run=client", "--context", "staging"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"logs", "-f", "deploy/web", "-c", "app", "--since=10m"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"exec", "-it", "web-0", "--", "sh", "-c", "env"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"port-forward", "svc/web", "8080:80"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"rollout", "status", "deployment/web", "--timeout=2m"}), -1);
  EXPECT_EQ(firstInvalid("kubectl", {"create", "deployment", "web", "--image=nginx", "--replicas=2"}), -1);
}

TEST_F(SpecTest, KubectlRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("kubectl", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("kubectl", {"rollout", "frob"}), 1);
  EXPECT_EQ(firstInvalid("kubectl", {"api-resources", "--frob"}), 1);
  EXPECT_EQ(firstInvalid("kubectl", {"api-versions", "extra"}), 1);
  // --dry-run reads its value only joined.
  EXPECT_EQ(firstInvalid("kubectl", {"apply", "-f", "a.yaml", "--dry-run", "client"}), 4);
}

// oc

TEST_F(SpecTest, OcCommandsAndDescriptions) {
  EXPECT_EQ(description("oc", {}, "new-project"), "Request a new project");
  EXPECT_EQ(description("oc", {"get"}, "dc"), "OpenShift deployment configs");
  EXPECT_TRUE(contains(texts("oc", {"get"}, "rou"), "routes"));
  EXPECT_TRUE(contains(texts("oc", {"adm"}, ""), "top"));
}

TEST_F(SpecTest, OcAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("oc", {"login", "https://api.example.com:6443", "--token=sha256~abc"}), -1);
  EXPECT_EQ(firstInvalid("oc", {"get", "routes", "-n", "demo", "-o", "yaml"}), -1);
  EXPECT_EQ(firstInvalid("oc", {"start-build", "bc/web", "--follow", "--wait"}), -1);
  EXPECT_EQ(firstInvalid("oc", {"rsh", "-c", "app", "web-1", "--", "bash"}), -1);
}

TEST_F(SpecTest, OcRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("oc", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("oc", {"logout", "--frob"}), 1);
}

// helm

TEST_F(SpecTest, HelmCommandsAndDescriptions) {
  EXPECT_EQ(description("helm", {}, "install"), "Install a chart");
  EXPECT_EQ(description("helm", {"install"}, "--create-namespace"), "Create the release namespace if not present");
  EXPECT_TRUE(contains(texts("helm", {"repo"}, ""), "update"));
  EXPECT_TRUE(contains(texts("helm", {"list", "-o"}, ""), "json"));
  EXPECT_TRUE(contains(texts("helm", {"upgrade", "-f"}, ""), "@file"));
  EXPECT_TRUE(contains(texts("helm", {"install"}, "--wait"), "--wait="));
}

TEST_F(SpecTest, HelmAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("helm", {"upgrade", "--install", "web", "./chart", "-n", "prod", "--create-namespace", "-f", "values.yaml", "--set", "image.tag=1.2.3", "--wait"}), -1);
  EXPECT_EQ(firstInvalid("helm", {"repo", "add", "bitnami", "https://charts.bitnami.com/bitnami"}), -1);
  EXPECT_EQ(firstInvalid("helm", {"template", "web", "./chart", "--values=values.yaml", "--dry-run=server"}), -1);
  EXPECT_EQ(firstInvalid("helm", {"list", "-A", "-o", "json"}), -1);
}

TEST_F(SpecTest, HelmRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("helm", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("helm", {"list", "--frob"}), 1);
  EXPECT_EQ(firstInvalid("helm", {"repo", "frob"}), 1);
}

// terraform

TEST_F(SpecTest, TerraformCommandsAndDescriptions) {
  EXPECT_EQ(description("terraform", {}, "plan"), "Show changes required by the current configuration");
  EXPECT_EQ(description("terraform", {"apply"}, "-auto-approve"), "Skip interactive approval");
  EXPECT_TRUE(contains(texts("terraform", {"state"}, ""), "mv"));
  EXPECT_TRUE(contains(texts("terraform", {"workspace"}, ""), "select"));
  EXPECT_TRUE(contains(texts("terraform", {"plan", "-var-file"}, ""), "@file"));
}

TEST_F(SpecTest, TerraformAcceptsRealLines) {
  EXPECT_EQ(firstInvalid("terraform", {"-chdir=infra", "plan", "-out=tfplan", "-var", "region=eu-west-1", "-lock=false"}), -1);
  EXPECT_EQ(firstInvalid("terraform", {"apply", "-auto-approve", "tfplan"}), -1);
  EXPECT_EQ(firstInvalid("terraform", {"init", "-upgrade", "-backend-config=prod.hcl", "-reconfigure"}), -1);
  EXPECT_EQ(firstInvalid("terraform", {"state", "mv", "aws_instance.a", "aws_instance.b"}), -1);
  EXPECT_EQ(firstInvalid("terraform", {"import", "-var-file=prod.tfvars", "aws_s3_bucket.logs", "my-logs"}), -1);
  EXPECT_EQ(firstInvalid("terraform", {"fmt", "-recursive", "-check"}), -1);
}

TEST_F(SpecTest, TerraformRejectsUnknownWords) {
  EXPECT_EQ(firstInvalid("terraform", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("terraform", {"plan", "-frob"}), 1);
  // -chdir needs the joined form.
  EXPECT_EQ(firstInvalid("terraform", {"-chdir", "infra"}), 0);
  // Options stop at the first operand.
  EXPECT_EQ(firstInvalid("terraform", {"apply", "tfplan", "-auto-approve"}), 2);
}

}
