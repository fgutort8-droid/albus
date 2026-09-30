#!/usr/bin/env python3
"""Install a checksum-pinned official release (see tools.json) into a local tools directory."""
import hashlib, io, json, os, platform, sys, tarfile, urllib.request
from pathlib import Path

name = sys.argv[1] if len(sys.argv) > 1 else "gitleaks"
config = json.loads((Path(__file__).parent / "tools.json").read_text())[name]
arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64"}[platform.machine()]
platform_id = platform.system().lower() + "_" + arch
asset = config["asset"].format(version=config["version"], platform=platform_id)
url = f"https://github.com/{config['repository']}/releases/download/v{config['version']}/{asset}"
with urllib.request.urlopen(url, timeout=60) as response:
    archive = response.read()
if hashlib.sha256(archive).hexdigest() != config["sha256"][platform_id]:
    raise SystemExit("Security tool checksum mismatch")
dest = Path(os.environ.get("ALBUS_TOOLS_DIR", "/tmp/albus-security-tools"))
dest.mkdir(parents=True, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
    member = tar.getmember(name)
    if not member.isfile():
        raise SystemExit("Invalid binary member")
    (dest / name).write_bytes(tar.extractfile(member).read())
(dest / name).chmod(0o755)
print("Installed verified " + name + " binary")
