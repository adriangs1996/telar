import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from check_text_fit import reference_command, reference_files


def fixtures():
    labels = [
        "", " \t\r\n ", "Agent in pane 1 is waiting for input",
        "one two three four five six seven eight nine ten",
        "first\r\nsecond\nthird\nfourth", "first\nsecond\nthird",
        "ábcd efg", "👩🏽‍💻 " * 32, "AVATAR To Wa office ffi",
        "שלום עולם\nلام\n中文\nfourth", "i" * 512, "W" * 512,
        "a" + "\u0301" * 35 + " end", "a\x00b\x1bc\x7fd",
        "leading \t\t repeated     spaces and\n\n\rparagraphs",
    ]
    generator = random.Random(0x6E6F74696679)
    words = ["agent", "pane", "input", "failed", "done", "office", "AV", "á", "中文", "👩🏽‍💻", "שלום"]
    separators = [" ", " ", "  ", "\t", "\r", "\n", "\r\n", "\n\n"]
    for _ in range(128):
        labels.append("".join(generator.choice(words) + generator.choice(separators) for _ in range(generator.randrange(1, 50))))

    heights = (11, 13, 17, 22, 26, 33)
    widths = (-1, 0, 0.5, 1, 10, 31.5, 70, 153.75, 237, 284, 568, 5000)
    return [(height, width, label.encode()) for height in heights for width in widths for label in labels]


def prepare(root, work, fonts):
    sources = reference_files(root, work, fonts)
    for name in ("NotificationText.zig", "NotificationTextInput.zig"):
        source = f"src/gui/widgets/overlays/{name}"
        destination = work / "overlays" / name
        destination.parent.mkdir(exist_ok=True)
        destination.write_bytes((root / source).read_bytes())
        sources.append(source)

    (work / "Label.zig").write_text("text: []const u8, face: enum { sans } = .sans, size: enum { body } = .body,\n")
    probe = work / "probe.zig"
    source = probe.read_text().replace('const TextFit = @import("TextFit.zig");', 'const TextFit = @import("TextFit.zig");\nconst NotificationText = @import("overlays/NotificationText.zig");')
    source = source.replace("request[0] > 1", "request[0] > 2")
    source = source.replace("        } else {\n            canvas.pixel_height", '''        } else if (request[0] == 2) {
            canvas.pixel_height = @intCast(request[1]);
            var wrapped: NotificationText = .{};
            try wrapped.wrap(&canvas, .{ .text = label, .width = @bitCast(request[2]) });
            const count: u32 = @intCast(wrapped.count);
            try output(std.mem.asBytes(&count));
            for (0..wrapped.count) |index| try text(wrapped.line(index));
        } else {
            canvas.pixel_height''')
    probe.write_text(source)
    return sources


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=root / "services/gui-cpp/out")
    parser.add_argument("--reference-build-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    options = parser.parse_args()
    build = options.build_dir.resolve()
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    fonts = [root / "src/assets" / name for name in ("IBMPlexSans-Regular.ttf", "IBMPlexSans-SemiBold.ttf", "SymbolsNerdFontMono-Regular.ttf")]
    sources = prepare(root, work, fonts)
    command = reference_command(root, (options.reference_build_dir or build).resolve(), work)
    subprocess.run(command, check=True, timeout=180)
    requests = fixtures()
    payload = b"".join(struct.pack("<IIfI", 2, height, width, len(text)) + text for height, width, text in requests)
    (work / "input.bin").write_bytes(payload)
    digest = hashlib.sha256()
    for index, font in enumerate(fonts):
        expected = subprocess.run([work / "zig"], input=struct.pack("<I", index) + payload, capture_output=True, check=True, timeout=120).stdout
        actual = subprocess.run([build / "gui-text-fit-probe", font], input=payload, capture_output=True, check=True, timeout=120).stdout
        (work / f"original-{index}.bin").write_bytes(expected)
        (work / f"cpp-{index}.bin").write_bytes(actual)
        if actual != expected:
            offset = next((offset for offset, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), min(len(actual), len(expected)))
            raise RuntimeError(f"Notification text mismatch in {font.name}, byte {offset}; retained both outputs")

        digest.update(actual)
        print(f"Matched {len(requests):,} notification bodies: {font.name}", flush=True)

    sources += ["services/gui-cpp/presentation/notification_text.hpp", "services/gui-cpp/tools/text_fit_probe.cpp", "services/gui-cpp/tools/check_notification_text.py", "services/gui-cpp/text/text_fit.hpp", "services/gui-cpp/text/grapheme_cursor.hpp"]
    result = {
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "Original NotificationText.wrap and TextFit with real font shaping; line count and UTF-8 bytes; no card geometry or raster claims",
        "records_per_font": len(requests),
        "fonts": {path.name: sha(path) for path in fonts},
        "input_sha256": hashlib.sha256(payload).hexdigest(),
        "output_sha256": digest.hexdigest(),
        "sources": {name: sha(root / name) for name in sources},
        "reference_command": [str(value) for value in command],
        "candidate_binary_sha256": sha(build / "gui-text-fit-probe"),
    }
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("records_per_font", "output_sha256")}))


if __name__ == "__main__":
    main()
