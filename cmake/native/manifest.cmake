# Official source archives. nghttp2, zstd and zlib match the SHA-256 their
# releases publish; SQLite matches the SHA3-256 on sqlite.org/download.html;
# libpcap's archive carries a good signature from The Tcpdump Group's package
# signing key. Brotli publishes no digest for its tag archive.
set(TELAR_NGHTTP2_VERSION 1.71.0)
set(TELAR_NGHTTP2_URL "https://github.com/nghttp2/nghttp2/releases/download/v${TELAR_NGHTTP2_VERSION}/nghttp2-${TELAR_NGHTTP2_VERSION}.tar.xz")
set(TELAR_NGHTTP2_SHA256 c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116)

set(TELAR_BROTLI_VERSION 1.2.1)
set(TELAR_BROTLI_URL "https://github.com/google/brotli/archive/refs/tags/v${TELAR_BROTLI_VERSION}.tar.gz")
set(TELAR_BROTLI_SHA256 98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f)

set(TELAR_ZSTD_VERSION 1.5.7)
set(TELAR_ZSTD_URL "https://github.com/facebook/zstd/releases/download/v${TELAR_ZSTD_VERSION}/zstd-${TELAR_ZSTD_VERSION}.tar.gz")
set(TELAR_ZSTD_SHA256 eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3)

# Linux only: macOS links the copies in its SDK, which Apple patches with the OS.
set(TELAR_ZLIB_VERSION 1.3.2)
set(TELAR_ZLIB_URL "https://github.com/madler/zlib/releases/download/v${TELAR_ZLIB_VERSION}/zlib-${TELAR_ZLIB_VERSION}.tar.gz")
set(TELAR_ZLIB_SHA256 bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16)

set(TELAR_SQLITE_VERSION 3.54.1)
set(TELAR_SQLITE_URL "https://sqlite.org/2026/sqlite-amalgamation-3540100.zip")
set(TELAR_SQLITE_SHA256 0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9)

set(TELAR_LIBPCAP_VERSION 1.11.0)
set(TELAR_LIBPCAP_URL "https://www.tcpdump.org/release/libpcap-${TELAR_LIBPCAP_VERSION}.tar.xz")
set(TELAR_LIBPCAP_SHA256 9237f5bae9dcf3a91823d9963ec43b7c0e2e3374ef2ad57d92c8cd39530f4723)
