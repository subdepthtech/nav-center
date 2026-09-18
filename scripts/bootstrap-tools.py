#!/usr/bin/env python3
"""Install exact official release binaries into a task-local directory."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request
import zipfile


def install(name, entry, destination):
    url = entry["url"]
    if not url.startswith("https://github.com/"):
        raise ValueError("Only pinned official GitHub release URLs are supported")
    request = urllib.request.Request(url, headers={"User-Agent": "nav-center-tool-setup"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"Checksum mismatch for {name}; nothing installed")
    # Read only the requested regular executable; never extract archive paths.
    if url.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            matches = [x for x in archive.infolist() if x.filename == name and not x.is_dir()]
            if len(matches) != 1:
                raise ValueError(f"Expected one {name} executable")
            binary = archive.read(matches[0])
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            matches = [x for x in archive.getmembers() if Path(x.name).name == name and x.isfile()]
            if len(matches) != 1:
                raise ValueError(f"Expected one regular {name} executable")
            binary = archive.extractfile(matches[0]).read()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{name}.download.", dir=destination
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(binary)
        temporary.chmod(0o755)
        temporary.replace(destination / name)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", action="append", required=True)
    parser.add_argument("--directory", type=Path, default=Path(".tools/bin"))
    args = parser.parse_args()
    lock = json.loads(Path(__file__).with_name("tool-versions.json").read_text())
    machine = {"aarch64": "arm64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    host = f"{platform.system().lower()}-{machine}"
    entries = [(name, lock["tools"][name], lock["tools"][name]["platforms"][host]) for name in args.tool]
    args.directory.mkdir(parents=True, exist_ok=True)
    for name, metadata, entry in entries:
        install(name, entry, args.directory)
        print(f"Installed {name} {metadata['version']} ({host}, SHA-256 verified)")


if __name__ == "__main__":
    main()
