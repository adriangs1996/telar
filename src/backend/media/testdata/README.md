# PNG fixtures

These are generated test images, not screenshots or third-party artwork.
All are 1x1, 8-bit, non-interlaced PNGs with a single unfiltered scanline.

| File | PNG color type | Pixel after RGBA conversion |
| --- | --- | --- |
| `rgba.png` | 6 | `1, 2, 3, 255` |
| `rgb.png` | 2 | `1, 2, 3, 255` |
| `gray.png` | 0 | `127, 127, 127, 255` |
| `alpha.png` | 6 | `1, 2, 3, 128` |
| `chunked.png` | 6 | `1, 2, 3, 255` |

`chunked.png` adds a `tEXt` chunk before IDAT. Its contents are
`Comment\0` followed by `PNG chunk boundary fixture. ` repeated 240 times.
Its base64 exceeds two 4096-character KGP chunks without needing a large image.

Generated with Python's `struct` and `zlib`: the PNG signature, an IHDR chunk,
the optional tEXt chunk, an IDAT containing `zlib.compress(b"\0" + pixel)`,
and an empty IEND. Each chunk includes its big-endian length and CRC32 over
its type and data.
