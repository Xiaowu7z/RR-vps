"""Small local-only notification emitter used by RR shell commands."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import sqlite3
from pathlib import Path
from typing import Iterator

from .notifications import NotificationManager


class Store:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("event")
    parser.add_argument("severity", choices=("info", "warning", "critical"))
    parser.add_argument("title")
    parser.add_argument("message")
    parser.add_argument("dedupe_key")
    parser.add_argument("--database", type=Path, default=Path("/var/lib/rr-nexus/nexus.db"))
    parser.add_argument("--interval", type=int, default=3600)
    args = parser.parse_args()
    if not args.database.is_file():
        return 0
    try:
        ok, detail = NotificationManager(Store(args.database)).emit(
            args.event, args.severity, args.title, args.message, args.dedupe_key,
            minimum_interval=max(0, args.interval),
        )
        if detail in {"disabled", "deduplicated"}:
            return 0
        return 0 if ok else 1
    except (OSError, sqlite3.Error, ValueError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
