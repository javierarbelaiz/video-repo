"""Depura los clips de la cámara de VideoRepo: los de más de RETENTION_DAYS días se guardan en restic y,
recién cuando el snapshot los tiene, se borran del volumen. Los videos para la TV no se tocan nunca.

Corre en el CronJob camara-depurador. El repo de restic (rest-server del box por la tailnet) y su clave
llegan del Secret camara-restic como RESTIC_REPOSITORY y RESTIC_PASSWORD.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable, Sequence

CLIP = re.compile(r"CamNet_record_(\d{8})_\d{6}_\d+\.mp4")
RESTIC_HOST = "videorepo"
RESTIC_TAG = "camara"


class BackupError(RuntimeError):
    """restic no dejó un snapshot utilizable: no se borra nada."""


def clip_date(name: str) -> date | None:
    match = CLIP.fullmatch(name)
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y%m%d").date()
    except ValueError:
        return None


def candidates(names: Iterable[str], today: date, days: int) -> list[str]:
    """Clips de la cámara con fecha (del nombre) anterior a today - days."""
    limit = today - timedelta(days=days)
    return sorted(n for n in names if (d := clip_date(n)) is not None and d < limit)


# restic backup sale con 3 cuando no pudo leer algún archivo pero igual guardó el snapshot.
RESTIC_PARTIAL = 3


@dataclass(frozen=True)
class PurgeResult:
    deleted: list[str]
    incomplete: bool  # algún clip viejo quedó sin depurar: el Job tiene que quedar fallido


def _run(restic: Sequence[str], args: list[str], ok: tuple[int, ...] = (0,)) -> tuple[int, list[dict]]:
    result = subprocess.run([*restic, *args], capture_output=True, text=True)
    if result.returncode not in ok:
        raise BackupError(f"restic {args[0]} salió con {result.returncode}: {result.stderr.strip()[-500:]}")
    messages = []
    for line in result.stdout.splitlines():
        try:
            messages.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return result.returncode, messages


def _backup(restic: Sequence[str], paths: list[str]) -> tuple[str, bool]:
    """Devuelve (snapshot, parcial)."""
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as listing:
        listing.write("\n".join(paths) + "\n")
    try:
        code, messages = _run(restic, ["backup", "--json", "--host", RESTIC_HOST, "--tag", RESTIC_TAG,
                                       "--files-from", listing.name], ok=(0, RESTIC_PARTIAL))
    finally:
        os.unlink(listing.name)
    summary = next((m for m in messages if m.get("message_type") == "summary"), {})
    snapshot = summary.get("snapshot_id")
    if not snapshot:
        raise BackupError("restic backup no informó el snapshot")
    return snapshot, code == RESTIC_PARTIAL


def _files_in(restic: Sequence[str], snapshot: str) -> set[str]:
    _, messages = _run(restic, ["ls", "--json", snapshot])
    return {m["path"] for m in messages if m.get("type") == "file" and "path" in m}


def purge(video_dir: Path, today: date, days: int, restic: Sequence[str]) -> PurgeResult:
    """Respalda y borra los clips viejos. Solo se borra lo que el snapshot contiene."""
    names = candidates((p.name for p in video_dir.iterdir() if p.is_file()), today, days)
    if not names:
        return PurgeResult([], False)
    paths = {name: str(video_dir / name) for name in names}
    snapshot, incomplete = _backup(restic, list(paths.values()))
    saved = _files_in(restic, snapshot)
    deleted = []
    for name, path in paths.items():
        # restic guarda la ruta absoluta tal cual se le pasó; lo que no está en el snapshot, se queda.
        if path not in saved:
            print(f"no está en el snapshot {snapshot}, queda: {name}")
            incomplete = True
            continue
        try:
            os.remove(path)
        except OSError as error:
            print(f"no se pudo borrar {name}: {error}")
            incomplete = True
            continue
        deleted.append(name)
    return PurgeResult(deleted, incomplete)


def main() -> int:
    video_dir = Path(os.environ.get("VIDEO_DIR", "/data/videos"))
    days = int(os.environ.get("RETENTION_DAYS", "30"))
    restic = [os.environ.get("RESTIC", "restic")]
    for var in ("RESTIC_REPOSITORY", "RESTIC_PASSWORD"):
        if not os.environ.get(var):
            print(f"falta {var} (Secret camara-restic)", file=sys.stderr)
            return 2
    try:
        result = purge(video_dir, date.today(), days, restic)
    except BackupError as error:
        print(f"no se borró nada: {error}", file=sys.stderr)
        return 1
    print(f"depurados {len(result.deleted)} clips de más de {days} días")
    if result.incomplete:
        print("quedaron clips viejos sin depurar (ver arriba)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
