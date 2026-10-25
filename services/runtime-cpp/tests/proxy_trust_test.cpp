#include "check.hpp"
#include "cli/proxy_options.hpp"
#include "proxy/authority_directory.hpp"
#include "proxy/trust/service.hpp"
#include "tls_fixture.hpp"
#include <functional>
#include <vector>

using namespace telar::runtime;

namespace {

class TrustCommands {
public:
  void run(std::span<const std::string_view> arguments) {
    std::vector<std::string> command;
    for (const auto argument : arguments) {
      command.emplace_back(argument);
    }

    commands.push_back(std::move(command));
    if (commands.size() == fail_at) {
      throw SystemError{"Fixture trust command failure", EIO};
    }
    if (after_command) {
      after_command();
    }
  }

  std::vector<std::vector<std::string>> commands;
  std::size_t fail_at = 0;
  std::function<void()> after_command;
};

template <typename Operation>
void rejects(Operation &&operation) {
  bool rejected = false;
  try {
    operation();
  } catch (const std::exception &) {
    rejected = true;
  }

  check(rejected);
}

std::string directoryPath(const AuthorityDirectory &directory) {
  std::array<char, PATH_MAX> path;
  check(::fcntl(directory.descriptor.get(), F_GETPATH, path.data()) == 0);
  return path.data();
}

std::size_t fileCount(const std::string &path) {
  return static_cast<std::size_t>(std::distance(std::filesystem::directory_iterator{path}, std::filesystem::directory_iterator{}));
}

void writeAuthority(int directory, std::chrono::seconds lifetime) {
  const auto pair = CertificatePair::authority("telar local CA", lifetime);
  const PemDocument key{pair.key.get()};
  const PemDocument certificate{pair.certificate.get()};
  check(writePrivateFile(directory, "ca-system-key.pem", key.bytes(), PrivateFileMode::replace) == 0);
  check(writePrivateFile(directory, "ca-system-cert.pem", certificate.bytes(), PrivateFileMode::replace) == 0);
}

void testTrustLifecycle(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  AuthorityDirectory directory;
  const auto path = directoryPath(directory);
  const proxy_trust::Paths paths{memory, path};
  constexpr std::string_view keychain = "/fixture/home/Library/Keychains/login.keychain-db";
  TrustCommands commands;
  proxy_trust::Service service{memory, library, paths, commands, keychain};
  check(service.inspect().status == proxy_trust::Status::absent);
  check(!service.rotateIfNeeded() && commands.commands.empty() && fileCount(path) == 0);

  const auto record = service.install(std::nullopt);
  check(record.backend == proxy_trust::Backend::macos && record.store.view() == keychain);
  check(commands.commands.size() == 1);
  const auto &installation = commands.commands[0];
  check(installation.size() == 7 && installation[0] == "/usr/bin/security" && installation[1] == "add-trusted-cert");
  check(installation[2] == "-r" && installation[3] == "trustRoot" && installation[4] == "-k" && installation[5] == keychain);
  check(installation[6].starts_with(path + "/ca-system-cert.pem.rotate-"));
  check(fileCount(path) == 3 && service.inspect().status == proxy_trust::Status::installed);
  check(!service.rotateIfNeeded() && commands.commands.size() == 1);

  const auto parsed = proxy_trust::Record::read(memory, directory.descriptor.get());
  check(parsed && parsed->fingerprint == record.fingerprint && parsed->store.view() == keychain);
  for (const auto &entry : std::filesystem::directory_iterator{path}) {
    struct stat state{};
    check(::lstat(entry.path().c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
  }

  writeAuthority(directory.descriptor.get(), std::chrono::hours{12});
  auto near_expiration = CertificateAuthority<TlsTestMemory>::loadExisting(memory, library, directory.descriptor.get(), AuthorityKind::system_trust);
  auto old_record = record;
  old_record.fingerprint = near_expiration->fingerprint();
  old_record.write(memory, directory.descriptor.get());
  check(service.inspect().status == proxy_trust::Status::stale);
  const auto replacement = service.rotateIfNeeded();
  check(replacement && replacement->fingerprint != old_record.fingerprint);
  check(commands.commands.size() == 3 && service.inspect().status == proxy_trust::Status::installed && fileCount(path) == 3);
  const auto &removal = commands.commands[2];
  check(removal.size() == 5 && removal[1] == "delete-certificate" && removal[2] == "-Z");
  check(removal[3] == std::string_view{old_record.fingerprint.data(), old_record.fingerprint.size()} && removal[4] == keychain);

  service.uninstall(*replacement);
  check(service.inspect().status == proxy_trust::Status::absent && fileCount(path) == 2);
  check(commands.commands.size() == 4 && !service.rotateIfNeeded());

  const auto reinstalled = service.install(std::nullopt);
  check(reinstalled.fingerprint == replacement->fingerprint);
  check(commands.commands.back().back() == path + "/ca-system-cert.pem");
  check(::fchmod(directory.descriptor.get(), 0755) == 0);
  const auto exposed = service.inspect();
  check(exposed.status == proxy_trust::Status::stale && exposed.record);
  const auto before = commands.commands.size();
  const auto repaired = service.install(exposed.record);
  check(repaired.fingerprint == reinstalled.fingerprint && commands.commands.size() == before + 1);
  check(service.inspect().status == proxy_trust::Status::installed);
}

void testTrustFailures(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  AuthorityDirectory directory;
  const auto path = directoryPath(directory);
  const proxy_trust::Paths paths{memory, path};
  constexpr std::string_view keychain = "/fixture/Library/Keychains/login.keychain-db";
  TrustCommands commands;
  proxy_trust::Service service{memory, library, paths, commands, keychain};
  commands.fail_at = 1;
  rejects([&] { service.install(std::nullopt); });
  check(fileCount(path) == 0 && service.inspect().status == proxy_trust::Status::absent);

  commands.fail_at = 0;
  const auto record = service.install(std::nullopt);
  auto wrong_target = record;
  wrong_target.store.assign("/another/keychain");
  wrong_target.write(memory, directory.descriptor.get());
  const auto previous_commands = commands.commands.size();
  rejects([&] { service.rotateIfNeeded(); });
  rejects([&] { service.uninstall(wrong_target); });
  check(commands.commands.size() == previous_commands && fileCount(path) == 3);

  record.write(memory, directory.descriptor.get());
  check(::fchmodat(directory.descriptor.get(), "trust-install.json", 0644, 0) == 0);
  check(service.inspect().status == proxy_trust::Status::stale && !service.inspect().record);
  check(!service.rotateIfNeeded());
  check(::fchmodat(directory.descriptor.get(), "trust-install.json", 0600, 0) == 0);

  writeAuthority(directory.descriptor.get(), std::chrono::hours{12});
  auto previous = record;
  previous.fingerprint = CertificateAuthority<TlsTestMemory>::loadExisting(memory, library, directory.descriptor.get(), AuthorityKind::system_trust)->fingerprint();
  previous.write(memory, directory.descriptor.get());
  commands.fail_at = commands.commands.size() + 2;
  rejects([&] { service.rotateIfNeeded(); });
  check(CertificateAuthority<TlsTestMemory>::loadExisting(memory, library, directory.descriptor.get(), AuthorityKind::system_trust)->fingerprint() == previous.fingerprint);
  check(proxy_trust::Record::read(memory, directory.descriptor.get())->fingerprint == previous.fingerprint);
  check(fileCount(path) == 3);

  commands.fail_at = 0;
  commands.after_command = [&] {
    if (commands.commands.back()[1] == "add-trusted-cert") {
      check(::unlinkat(directory.descriptor.get(), "trust-install.json", 0) == 0);
      check(::mkdirat(directory.descriptor.get(), "trust-install.json", 0700) == 0);
    }
  };
  rejects([&] { service.install(previous); });
  check(CertificateAuthority<TlsTestMemory>::loadExisting(memory, library, directory.descriptor.get(), AuthorityKind::system_trust)->fingerprint() == previous.fingerprint);
  check(fileCount(path) == 3 && commands.commands.back()[1] == "delete-certificate");
}

void testTrustRecords(TlsTestMemory &memory) {
  constexpr std::string_view valid = R"({"version":1,"backend":"macos","fingerprint":"aBcDEF0123456789012345678901234567890123","store_path":"/fixture"})";
  const auto record = proxy_trust::Record::parse(memory, valid);
  check(std::string_view{record.fingerprint.data(), record.fingerprint.size()}.starts_with("ABCDEF"));
  for (const auto source : {"{}", "[]", R"({"version":1,"version":1})", R"({"version":1,"unknown":0})"}) {
    rejects([&] { proxy_trust::Record::parse(memory, source); });
  }

  for (const auto replacement : {"", "1.5", "-1", "256", "null", "true"}) {
    std::string source{valid};
    source.replace(source.find("1,"), 1, replacement);
    rejects([&] { proxy_trust::Record::parse(memory, source); });
  }

  struct Environment {
    std::string_view data;
    std::string_view lookup(const char *name) const noexcept { return std::string_view{name} == "HOME" ? "/home/fixture" : data; }
  };

  check(proxyAuthorityDirectory(memory, Environment{"relative"}) == "/home/fixture/.local/share/telar/proxy");
  check(proxyAuthorityDirectory(memory, Environment{"/data"}) == "/data/telar/proxy");
}

}

void testProxyTrust(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  testTrustRecords(memory);
  testTrustLifecycle(memory, library);
  testTrustFailures(memory, library);
}

void createProxyTrustFixture(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, std::string_view directory) {
  const proxy_trust::Paths paths{memory, directory};
  const auto keychain = paths.keychain(memory, ProcessEnvironment{});
  TrustCommands commands;
  proxy_trust::Service service{memory, library, paths, commands, keychain};
  const auto record = service.install(std::nullopt);
  std::printf("%.*s\n", static_cast<int>(record.fingerprint.size()), record.fingerprint.data());
}
