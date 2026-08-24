# Vendored Lua

- Upstream: <https://www.lua.org/ftp/lua-5.5.1.tar.gz>
- Version: 5.5.1
- Archive SHA-256: `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
- License: MIT; see [`LICENSE.html`](LICENSE.html).

Telar compiles the Lua core plus base, coroutine, math, string, table, and UTF-8
libraries. It deliberately excludes the standalone interpreter and the I/O,
OS, debug, package/native-loader libraries from the linked configuration VM.
