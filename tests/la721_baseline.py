"""Pinned production 7.2.1 modules for incident and upgrade regression tests.

These bytes come from the official v7.2.1 bundle, not the current candidate.
The small archive retains only modules exercised by these historical tests.
"""
import hashlib
import io
from pathlib import Path
import sys
import tarfile

ARCHIVE = Path(__file__).parent / "fixtures/la721-runtime.tar.gz"
ARCHIVE_SHA256 = "18fa269a48ce0dc767c871c995b3c8589743d7293e4158f62e8b0501dcbe785e"
PINS = {
    "modules/09-systemd.sh": "1117fcc078ec7d4041dda2902ad93dbdc8e369b822ee82eb846192c178390740",
    "modules/10-system.sh": "2e8b60c97bc2cc872291d0fceaef7a34dd30bbce713ba3465f1fd87a711549f0",
    "modules/30-singbox.sh": "a31b2431a41772e930772df69422e2a3d5024f317d42c3b750b502b63ff2444f",
    "modules/55-resilience.sh": "47bcdf775b70e06f9e47cf30620b34adf34aefccc5db3e14d5d0abe6c545074d",
    "modules/60-update.sh": "7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d",
}


def files():
    raw = ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("historical 7.2.1 archive hash mismatch")
    result = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        members = archive.getmembers()
        if [item.name for item in members] != list(PINS):
            raise ValueError("historical 7.2.1 archive namespace mismatch")
        for item in members:
            if not item.isfile():
                raise ValueError("historical 7.2.1 member is not a regular file")
            value = archive.extractfile(item).read()
            if hashlib.sha256(value).hexdigest() != PINS[item.name]:
                raise ValueError("historical 7.2.1 module hash mismatch")
            result[item.name] = value
    return result


if __name__ == "__main__":
    destination = Path(sys.argv[1])
    for name, value in files().items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(value)
