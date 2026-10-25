#include "check.hpp"
#include "proxy/authenticate.hpp"
#include "proxy/secret_file.hpp"
#include <filesystem>
#include <fstream>

using namespace telar::runtime;

void testProxyNetwork();

static std::string authorization(std::string_view userinfo) {
  std::string encoded((userinfo.size() + 2) / 3 * 4, '\0');
  check(base64::encode({reinterpret_cast<const std::uint8_t *>(userinfo.data()), userinfo.size()}, encoded) == encoded.size());
  return "Proxy-Authorization: Basic " + encoded + "\r\n";
}

static void testAuthorization(SystemAllocator &memory) {
  const std::string hexadecimal(64, 'a');
  const auto secret = ProxySecret::fromHexadecimal(hexadecimal);
  check(secret.has_value());
  check(secret->matches(*ProxySecret::fromHexadecimal(std::string(64, 'A'))));
  for (std::size_t position = 0; position < hexadecimal.size(); ++position) {
    auto different = hexadecimal;
    different[position] = 'b';
    check(!secret->matches(*ProxySecret::fromHexadecimal(different)));
  }
  check(!ProxySecret::fromHexadecimal(std::string(63, 'a')) && !ProxySecret::fromHexadecimal(std::string(64, 'g')));

  std::array<char, 128> url;
  check(secret->formatUrl(url, 45100) == "http://telar:" + hexadecimal + "@127.0.0.1:45100");
  const std::string request = "CONNECT api.example.com:443 HTTP/1.1\r\n";
  const auto credential = authorization("telar:" + hexadecimal);
  const auto header = request + credential + "Host: api.example.com:443\r\n\r\n";
  check(ProxyAuthorization::present(header));
  check(ProxyAuthorization::parse(header)->matches(*secret));
  check(!ProxyAuthorization::present(request + "\r\n"));
  for (const auto &invalid : {request + credential + credential + "\r\n", request + authorization("Telar:" + hexadecimal), request + "Proxy-Authorization: Bearer ignored\r\n", request + authorization(std::string(193, 'a')), request + "Proxy-Authorization: Basic !!!!!!!!\r\n", request + "Proxy-Authorization: Basic\tYWJj\r\n"}) {
    check(ProxyAuthorization::present(invalid) && !ProxyAuthorization::parse(invalid));
  }

  auto mixed_case = header;
  mixed_case.replace(mixed_case.find("Proxy-Authorization"), 19, "pRoXy-aUtHoRiZaTiOn");
  mixed_case.replace(mixed_case.find("Basic"), 5, "bAsIc");
  check(ProxyAuthorization::parse(mixed_case)->matches(*secret));

  ProxyHostPolicy policy{memory};
  check(policy.append("api.example.com"));
  policy.finish();
  auto decision = authenticateProxy(*secret, false, policy, header);
  check(std::holds_alternative<ProxyAdmission>(decision) && std::get<ProxyAdmission>(decision).authenticated);
  check(std::get<ProxyAdmission>(decision).target.hostname == "api.example.com");
  check(std::get<ProxyAdmission>(decision).target.port == 443);

  decision = authenticateProxy(*secret, true, policy, "CONNECT opaque.example.com:1234 HTTP/1.1\r\n\r\n");
  check(std::holds_alternative<ProxyAdmission>(decision) && !std::get<ProxyAdmission>(decision).authenticated);
  decision = authenticateProxy(*secret, true, policy, request + "\r\n");
  check(std::get<ProxyRejection>(decision).reason == ProxyRejection::Reason::invalid_authorization);
  decision = authenticateProxy(*secret, true, policy, "INVALID\r\n\r\n");
  check(std::get<ProxyRejection>(decision).reason == ProxyRejection::Reason::invalid_target);
  decision = authenticateProxy(*secret, false, policy, "INVALID\r\n\r\n");
  check(std::get<ProxyRejection>(decision).reason == ProxyRejection::Reason::invalid_authorization);
  decision = authenticateProxy(*secret, false, policy, "INVALID\r\n" + credential + "\r\n");
  check(std::get<ProxyRejection>(decision).reason == ProxyRejection::Reason::invalid_target);
  decision = authenticateProxy(*secret, true, policy, request + authorization("telar:" + std::string(64, 'b')) + "\r\n");
  check(std::get<ProxyRejection>(decision).reason == ProxyRejection::Reason::unknown_credential);

  for (const auto valid : {"CONNECT localhost:1 HTTP/1.1\r\n", "CONNECT example.com.:65535 HTTP/1.1\r\n", "CONNECT 127.0.0.1:00443 HTTP/1.1\r\n"}) {
    check(ProxyTarget::parse(valid).has_value());
  }
  for (const auto invalid : {"connect localhost:443 HTTP/1.1\r\n", "CONNECT localhost:443 HTTP/1.0\r\n", "CONNECT localhost:443 HTTP/1.1 extra\r\n", "CONNECT  localhost:443 HTTP/1.1\r\n", "CONNECT localhost:443  HTTP/1.1\r\n", "CONNECT localhost:443 HTTP/1.1", "CONNECT localhost:0 HTTP/1.1\r\n", "CONNECT localhost:65536 HTTP/1.1\r\n", "CONNECT localhost:+443 HTTP/1.1\r\n", "CONNECT localhost:-1 HTTP/1.1\r\n", "CONNECT localhost:44_3 HTTP/1.1\r\n", "CONNECT [::1]:443 HTTP/1.1\r\n", "CONNECT *.example.com:443 HTTP/1.1\r\n", "CONNECT a..b:443 HTTP/1.1\r\n"}) {
    check(!ProxyTarget::parse(invalid));
  }
}

static void testSecretFile(SystemAllocator &memory) {
  std::array<char, 64> path;
  std::strcpy(path.data(), "/tmp/telar-proxy-secret-XXXXXX");
  check(::mkdtemp(path.data()) != nullptr);
  FileDescriptor directory{::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  check(directory && !ProxySecretFile::load(memory, directory.get()));
  const auto secret = ProxySecretFile::ensure(memory, directory.get());
  check(ProxySecretFile::ensure(memory, directory.get()).matches(secret));
  struct stat metadata{};
  check(::fstatat(directory.get(), "proxy-secret", &metadata, AT_SYMLINK_NOFOLLOW) == 0);
  check(metadata.st_size == 65 && (metadata.st_mode & 0777) == 0600);

  const auto filename = std::filesystem::path{path.data()} / "proxy-secret";
  for (const auto &contents : {std::string{}, std::string(64, 'x'), std::string(63, 'a'), std::string(73, 'a')}) {
    {
      std::ofstream file{filename};
      file << contents;
    }
    bool rejected = false;
    try {
      ProxySecretFile::ensure(memory, directory.get());
    } catch (const SystemError &) {
      rejected = true;
    }
    check(rejected);
    std::ifstream file{filename};
    check(std::string{std::istreambuf_iterator<char>{file}, {}} == contents);
  }
  std::filesystem::remove_all(path.data());
}

void testProxyAuthentication() {
  SystemAllocator memory;
  testAuthorization(memory);
  testSecretFile(memory);
  testProxyNetwork();
}
