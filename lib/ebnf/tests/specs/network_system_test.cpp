#ifdef __clangd__
static_assert(true);
#endif
#include "../spec_support.hpp"

namespace {

using spec_support::SpecTest;

TEST_F(SpecTest, CurlOptionsAndDescriptions) {
  EXPECT_EQ(description("curl", {}, "--location"), "Follow redirects");
  EXPECT_EQ(description("curl", {}, "--no-progress-meter"), "Do not show the progress meter");
  EXPECT_TRUE(contains(texts("curl", {"-X"}, "P"), "PATCH"));
  EXPECT_TRUE(contains(texts("curl", {"--tls-max"}, ""), "1.3"));
  EXPECT_EQ(firstInvalid("curl", {"-sSL", "-H", "Accept: x", "https://example.com"}), -1);
  EXPECT_EQ(firstInvalid("curl", {"-X", "POST", "--json", "{\"a\":1}", "-o", "out.json", "--retry", "3", "https://api.example.com/v1"}), -1);
  EXPECT_EQ(firstInvalid("curl", {"-fsSLo", "install.sh", "--compressed", "--no-silent", "https://example.com/install.sh"}), -1);
  EXPECT_EQ(firstInvalid("curl", {"-h", "category"}), -1);
  EXPECT_EQ(firstInvalid("curl", {"--frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("curl", {"https://example.com", "--location=yes"}), 1);
}

TEST_F(SpecTest, WgetOptionsAndDescriptions) {
  EXPECT_EQ(description("wget", {}, "--mirror"), "Mirror: -N -r -l inf --no-remove-listing");
  EXPECT_TRUE(contains(texts("wget", {}, "--progress=bar"), "--progress=bar:force"));
  EXPECT_EQ(firstInvalid("wget", {"-qO-", "https://example.com/install.sh"}), -1);
  EXPECT_EQ(firstInvalid("wget", {"-r", "-np", "-nH", "--cut-dirs=2", "-P", "downloads", "--limit-rate", "1m", "https://example.com/pub/"}), -1);
  EXPECT_EQ(firstInvalid("wget", {"-c", "--tries=0", "--progress=dot:mega", "https://example.com/big.iso"}), -1);
  EXPECT_EQ(firstInvalid("wget", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, ScpOptionsAndDescriptions) {
  EXPECT_EQ(description("scp", {}, "-r"), "Copy directories recursively");
  EXPECT_TRUE(contains(texts("scp", {"-X"}, ""), "nrequests="));
  EXPECT_EQ(firstInvalid("scp", {"-r", "-P", "2222", "dist", "deploy@web:/srv/app"}), -1);
  EXPECT_EQ(firstInvalid("scp", {"-3", "-o", "StrictHostKeyChecking=no", "a:/tmp/x", "b:/tmp/"}), -1);
  EXPECT_EQ(firstInvalid("scp", {"-Z", "file", "host:"}), 0);
}

TEST_F(SpecTest, RsyncOptionsAndDescriptions) {
  EXPECT_EQ(description("rsync", {}, "--delete"), "Delete extraneous files from the destination");
  EXPECT_EQ(description("rsync", {}, "--no-perms"), "Turn off --perms");
  EXPECT_TRUE(contains(texts("rsync", {"--checksum-choice"}, "x"), "xxh128"));
  EXPECT_EQ(firstInvalid("rsync", {"-avz", "--delete", "--exclude=.git", "src/", "host:/srv/src/"}), -1);
  EXPECT_EQ(firstInvalid("rsync", {"-aHAX", "--no-o", "--info=progress2", "-e", "ssh -p 2222", "--partial-dir", ".partial", "a", "b"}), -1);
  EXPECT_EQ(firstInvalid("rsync", {"-a", "--frobnicate", "a", "b"}), 1);
}

TEST_F(SpecTest, PingOptionsAndDescriptions) {
  EXPECT_EQ(description("ping", {}, "-c"), "Stop after this many replies");
  EXPECT_TRUE(contains(texts("ping", {"-M"}, ""), "probe"));
  EXPECT_EQ(firstInvalid("ping", {"-c", "4", "example.com"}), -1);
  EXPECT_EQ(firstInvalid("ping", {"-4", "-i", "0.2", "-W", "1", "-M", "do", "-s", "1472", "10.0.0.1"}), -1);
  EXPECT_EQ(firstInvalid("ping", {"-c3", "-b", "en0", "192.168.1.1"}), -1);
  EXPECT_EQ(firstInvalid("ping", {"--frobnicate", "example.com"}), 0);
}

TEST_F(SpecTest, DigOptionsAndDescriptions) {
  EXPECT_EQ(description("dig", {}, "+short"), "Print only a terse answer");
  EXPECT_TRUE(contains(texts("dig", {"example.com"}, "AA"), "AAAA"));
  EXPECT_EQ(firstInvalid("dig", {"+short", "example.com", "AAAA"}), -1);
  EXPECT_EQ(firstInvalid("dig", {"@1.1.1.1", "-t", "MX", "example.com", "+noall", "+answer", "+timeout=2"}), -1);
  EXPECT_EQ(firstInvalid("dig", {"-x", "8.8.8.8", "+trace"}), -1);
  EXPECT_EQ(firstInvalid("dig", {"example.com", "-z"}), 1);
}

TEST_F(SpecTest, NcOptionsAndDescriptions) {
  EXPECT_EQ(description("nc", {}, "-z"), "Scan for listening daemons without sending data");
  EXPECT_TRUE(contains(texts("nc", {"-X"}, ""), "connect"));
  EXPECT_EQ(firstInvalid("nc", {"-zv", "example.com", "20-30"}), -1);
  EXPECT_EQ(firstInvalid("nc", {"-l", "-k", "-p", "8080"}), -1);
  EXPECT_EQ(firstInvalid("nc", {"-x10.2.3.4:8080", "-Xconnect", "host.example.com", "42"}), -1);
  EXPECT_EQ(firstInvalid("nc", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, LsofOptionsAndDescriptions) {
  EXPECT_EQ(description("lsof", {}, "-t"), "Terse output: process ids only");
  EXPECT_TRUE(contains(texts("lsof", {"-i"}, "TC"), "TCP"));
  EXPECT_EQ(firstInvalid("lsof", {"-nP", "-iTCP:8080", "-sTCP:LISTEN"}), -1);
  EXPECT_EQ(firstInvalid("lsof", {"-i", ":3000", "-t"}), -1);
  EXPECT_EQ(firstInvalid("lsof", {"-p", "1234", "+D", "/var/log", "+L1"}), -1);
  EXPECT_EQ(firstInvalid("lsof", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, PsOptionsAndDescriptions) {
  EXPECT_EQ(description("ps", {}, "-f"), "Full format listing");
  EXPECT_TRUE(contains(texts("ps", {"--help"}, ""), "threads"));
  EXPECT_EQ(firstInvalid("ps", {"aux"}), -1);
  EXPECT_EQ(firstInvalid("ps", {"-eo", "pid,ppid,comm", "--sort=-pcpu"}), -1);
  EXPECT_EQ(firstInvalid("ps", {"-ef", "--forest"}), -1);
  EXPECT_EQ(firstInvalid("ps", {"-p", "1", "-o", "comm="}), -1);
  EXPECT_EQ(firstInvalid("ps", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, ManOptionsAndDescriptions) {
  EXPECT_EQ(description("man", {}, "-k"), "Emulate apropos");
  EXPECT_TRUE(contains(texts("man", {}, "5"), "5"));
  EXPECT_EQ(firstInvalid("man", {"5", "crontab"}), -1);
  EXPECT_EQ(firstInvalid("man", {"-a", "-P", "less -R", "printf"}), -1);
  EXPECT_EQ(firstInvalid("man", {"--sections=1:8", "--regex", "^ssh"}), -1);
  EXPECT_EQ(firstInvalid("man", {"--frobnicate"}), 0);
}

TEST_F(SpecTest, ChownOptionsAndDescriptions) {
  EXPECT_EQ(description("chown", {}, "-R"), "Operate on directories recursively");
  EXPECT_EQ(firstInvalid("chown", {"-R", "www-data:www-data", "/srv/app"}), -1);
  EXPECT_EQ(firstInvalid("chown", {"-hv", "--reference=a.txt", "b.txt", "c.txt"}), -1);
  EXPECT_EQ(firstInvalid("chown", {"--frobnicate", "root", "f"}), 0);
}

TEST_F(SpecTest, SystemctlCommandsAndOptions) {
  EXPECT_EQ(description("systemctl", {}, "daemon-reload"), "Reload the systemd manager configuration");
  EXPECT_TRUE(contains(texts("systemctl", {}, "is-"), "is-active"));
  EXPECT_TRUE(contains(texts("systemctl", {"--type"}, "ti"), "timer"));
  EXPECT_EQ(firstInvalid("systemctl", {"--user", "restart", "pipewire.service"}), -1);
  EXPECT_EQ(firstInvalid("systemctl", {"enable", "--now", "sshd"}), -1);
  EXPECT_EQ(firstInvalid("systemctl", {"list-units", "--type=service", "--state=failed", "--no-pager"}), -1);
  EXPECT_EQ(firstInvalid("systemctl", {"--frobnicate", "status"}), 0);
  EXPECT_EQ(firstInvalid("systemctl", {"frobnicate"}), 0);
  EXPECT_EQ(firstInvalid("systemctl", {"daemon-reload", "nginx"}), 1);
}

TEST_F(SpecTest, JournalctlOptionsAndDescriptions) {
  EXPECT_EQ(description("journalctl", {}, "--follow"), "Follow the journal");
  EXPECT_TRUE(contains(texts("journalctl", {"-o"}, "json"), "json-pretty"));
  EXPECT_EQ(firstInvalid("journalctl", {"-u", "sshd", "-f", "-n", "50"}), -1);
  EXPECT_EQ(firstInvalid("journalctl", {"-b", "-1", "-p", "err", "--since", "1 hour ago", "--no-pager"}), -1);
  EXPECT_EQ(firstInvalid("journalctl", {"-k", "-o", "short-iso", "_PID=1"}), -1);
  EXPECT_EQ(firstInvalid("journalctl", {"--frobnicate"}), 0);
}

} // namespace
