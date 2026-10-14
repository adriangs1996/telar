import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def command(*args, capture=False, **kwargs):
    result = subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout.strip() if capture else None


def main():
    tests = Path(__file__).resolve().parent
    module = tests.parent.parent
    architecture = command("docker", "info", "--format", "{{.Architecture}}", capture=True)
    architecture = {"aarch64": "arm64", "x86_64": "amd64"}.get(architecture, architecture)
    if architecture not in {"arm64", "amd64"}:
        raise RuntimeError(f"unsupported Docker architecture: {architecture}")

    suffix = uuid.uuid4().hex[:12]
    network = f"telar-proxy-test-{suffix}"
    server = f"telar-proxy-target-{suffix}"
    client = f"telar-proxy-client-{suffix}"
    image = "telar-proxy-network-test:local"
    aliases = ["100.64.1.10", "198.51.100.10", "2001:db8:1::10", "fd00:198:51::10"]
    subnet6 = f"fd42:{suffix[:4]}:{suffix[4:8]}::/64"

    with tempfile.TemporaryDirectory(prefix="telar-proxy-docker-") as scratch:
        context = Path(scratch)
        environment = dict(os.environ, GOOS="linux", GOARCH=architecture, CGO_ENABLED="0")
        command("go", "build", "-o", str(context / "telar-proxy"), "./cmd/telar-proxy", cwd=module, env=environment)
        command("go", "test", "-c", "-o", str(context / "network-tests"), "./cmd/telar-proxy", cwd=module, env=environment)
        command("go", "run", "./tests/linux/tls_fixture.go", str(context / "tls-fixtures"), cwd=module)
        for file in ("Dockerfile", "server.py", "client.py", "ipv6_extensions.py"):
            shutil.copyfile(tests / file, context / file)
        command("docker", "build", "--quiet", "-t", image, str(context))

    command("docker", "run", "--rm", image, "/tests/network-tests", "-test.v")

    try:
        command("docker", "network", "create", "--internal", "--ipv6", "--subnet", subnet6, network, capture=True)
        command("docker", "run", "--rm", "-d", "--name", server, "--network", network,
                "--cap-add", "NET_ADMIN", image, "python3", "/tests/server.py", *aliases, capture=True)
        destination = command("docker", "inspect", "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", server, capture=True)
        destination6 = command("docker", "inspect", "--format", "{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}", server, capture=True)
        command("docker", "run", "--rm", "--init", "--name", client, "--network", network,
                "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW", "--device", "/dev/net/tun",
                image, "python3", "/tests/client.py", destination, destination6, *aliases)
    finally:
        subprocess.run(["docker", "rm", "-f", client, server], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["docker", "network", "rm", network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
