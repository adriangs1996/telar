import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description="Build the unchanged Zig attachment catalog with a deterministic presentation delivery")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--probe", choices=("catalog", "markers", "lifecycle"), default="catalog")
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = {}

    def copy(source, destination):
        original = repository / source
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        sources[source] = hashlib.sha256(original.read_bytes()).hexdigest()

    for original in (repository / "src/client/attachments").glob("*.zig"):
        copy(str(original.relative_to(repository)), "client/attachments/" + original.name)
    for original in (repository / "src/model/attachments").glob("*.zig"):
        copy(str(original.relative_to(repository)), "model/attachments/" + original.name)
    copy("src/model/input/limits.zig", "model/input/limits.zig")
    for name in ("Limit.zig", "LimitReach.zig"):
        copy("src/core/" + name, "core/" + name)
    for name in ("id.zig", "Cursor.zig", "CursorAppearance.zig"):
        copy("src/core/schema/" + name, "core/" + name)
    for original in (repository / "lib/cellgrid").glob("*.zig"):
        copy(str(original.relative_to(repository)), "cellgrid/" + original.name)
    for original in (repository / "lib/unicode").glob("*.zig"):
        copy(str(original.relative_to(repository)), "unicode/" + original.name)
    model_exports = [
        ("attachment_types", "attachments/types.zig", None),
        ("AttachmentId", "attachments/AttachmentId.zig", "AttachmentId"),
        ("AttachmentTarget", "attachments/AttachmentTarget.zig", None),
        ("AttachmentMarkerPolicy", "attachments/AttachmentMarkerPolicy.zig", "AttachmentMarkerPolicy"),
        ("AttachmentMarkerDeletion", "attachments/AttachmentMarkerDeletion.zig", "AttachmentMarkerDeletion"),
        ("Capture", "attachments/Capture.zig", None),
        ("MarkerRemoval", "attachments/MarkerRemoval.zig", None),
        ("Marker", "attachments/Marker.zig", None),
        ("Screen", "attachments/Screen.zig", None),
        ("Span", "attachments/Span.zig", None),
        ("attachments_path_marker", "attachments/path_marker.zig", None),
    ]
    def exports(path, values):
        result = []
        for index, (name, source, member) in enumerate(values):
            result.append('const Source' + str(index) + ' = @import("' + source + '");')
            result.append('pub const ' + name + ' = Source' + str(index) + ('.' + member if member else '') + ';')
        path.write_text('\n'.join(result) + '\n')
    exports(output / "model/model.zig", model_exports)
    exports(output / "core/root.zig", [("PaneId", "id.zig", "PaneId"), ("Limit", "Limit.zig", None), ("LimitReach", "LimitReach.zig", None), ("Cursor", "Cursor.zig", None)])
    copy("services/gui-cpp/tools/reference_attachment_capture/" + options.probe + "_probe.zig", "probe.zig")
    binary = output / ("attachment-" + options.probe + "-reference")
    command = ["zig", "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "telar-core", "--dep", "model", "--dep", "cellgrid", "-Mroot=" + str(output / "probe.zig"), "-Mtelar-core=" + str(output / "core/root.zig"), "--dep", "telar-core", "--dep", "cellgrid", "-Mmodel=" + str(output / "model/model.zig"), "--dep", "unicode", "-Mcellgrid=" + str(output / "cellgrid/root.zig"), "-Municode=" + str(output / "unicode/root.zig"), "-femit-bin=" + str(binary)]
    receipt = {"scope": ("Unchanged original attachment catalog and related types; thin type-export roots and deterministic delivery only. No marker algorithms are exercised by this probe." if options.probe == "catalog" else "Unchanged original marker scanners, cursor policies and navigation plans over original cellgrid buffers. Thin type-export roots only."), "command": command, "source_sha256": sources}
    with (output / "build.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=repository)
    receipt["exit_code"] = result.returncode
    (output / "build.json").write_text(json.dumps(receipt, indent=2))
    result.check_returncode()
    receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    (output / "build.json").write_text(json.dumps(receipt, indent=2))
    print("Original-source catalog reference built")


if __name__ == "__main__":
    main()
