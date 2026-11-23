"""Tests del depurador de clips de la cámara (restic falso: no toca ningún repositorio real)."""
import json
import os
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import depurar_camara as dep  # noqa: E402

TODAY = date(2026, 12, 25)
OLD = "CamNet_record_20261122_024548_254743.mp4"
OLD2 = "CamNet_record_20261124_101010_1.mp4"
NEW = "CamNet_record_20261220_120000_2.mp4"

# restic falso: anota cada llamada y responde como restic --json. Se maneja por variables de entorno.
FAKE = r'''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[0] == "backup":
    if os.environ.get("FAKE_BACKUP_RC", "0") != "0":
        sys.stderr.write("Fatal: unable to open repository\n")
        sys.exit(int(os.environ["FAKE_BACKUP_RC"]))
    files = [l.strip() for l in open(args[args.index("--files-from") + 1]) if l.strip()]
    with open(os.environ["FAKE_STATE"], "w") as state:
        json.dump(files, state)
    print(json.dumps({"message_type": "status", "percent_done": 1}))
    print(json.dumps({"message_type": "summary", "files_new": len(files), "snapshot_id": "abc123"}))
elif args[0] == "ls":
    assert args[-1] == "abc123", args
    files = json.load(open(os.environ["FAKE_STATE"]))
    omit = os.environ.get("FAKE_LS_OMIT", "")
    print(json.dumps({"message_type": "snapshot", "id": "abc123"}))
    print(json.dumps({"message_type": "node", "type": "dir", "path": "/data"}))
    for f in files:
        if omit and f.endswith(omit):
            continue
        print(json.dumps({"message_type": "node", "type": "file", "path": f, "name": os.path.basename(f)}))
'''


class CandidatesTest(unittest.TestCase):
    def test_solo_clips_de_camara_mas_viejos_que_la_retencion(self):
        names = [OLD, NEW, "CamNet_algo.mp4", "record_20261101_000000_1.mp4", "Pelicula 2026.mp4",
                 "CamNet_record_20261101_000000_1.mkv", ".tools"]
        self.assertEqual(dep.candidates(names, TODAY, 30), [OLD])

    def test_fecha_invalida_se_ignora(self):
        self.assertEqual(dep.candidates(["CamNet_record_20261399_000000_1.mp4"], TODAY, 30), [])

    def test_el_limite_es_exclusivo(self):
        # 25/12 - 30 días = 25/11: un clip de ese día todavía queda.
        self.assertEqual(dep.candidates(["CamNet_record_20261125_000000_1.mp4"], TODAY, 30), [])
        self.assertEqual(dep.candidates([OLD2], TODAY, 30), [OLD2])


class PurgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.videos = root / "videos"
        self.videos.mkdir()
        for name in (OLD, OLD2, NEW, "Pelicula.mp4"):
            (self.videos / name).write_bytes(b"x")
        fake = root / "fake_restic.py"
        fake.write_text(FAKE)
        self.cmd = [sys.executable, str(fake)]
        self.log = root / "calls.log"
        os.environ["FAKE_LOG"] = str(self.log)
        os.environ["FAKE_STATE"] = str(root / "state.json")
        os.environ.pop("FAKE_BACKUP_RC", None)
        os.environ.pop("FAKE_LS_OMIT", None)

    def tearDown(self):
        self.tmp.cleanup()

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def remaining(self):
        return sorted(p.name for p in self.videos.iterdir())

    def test_respalda_y_borra_solo_los_viejos(self):
        deleted = dep.purge(self.videos, TODAY, 30, self.cmd)
        self.assertEqual(sorted(deleted), sorted([OLD, OLD2]))
        self.assertEqual(self.remaining(), sorted([NEW, "Pelicula.mp4"]))
        backup = self.calls()[0]
        self.assertEqual(backup[0], "backup")
        for flag in ("--host", "videorepo", "--tag", "camara", "--json"):
            self.assertIn(flag, backup)

    def test_sin_candidatos_no_llama_a_restic(self):
        (self.videos / OLD).unlink()
        (self.videos / OLD2).unlink()
        self.assertEqual(dep.purge(self.videos, TODAY, 30, self.cmd), [])
        self.assertEqual(self.calls(), [])

    def test_si_falla_el_backup_no_borra_nada(self):
        os.environ["FAKE_BACKUP_RC"] = "1"
        with self.assertRaises(dep.BackupError):
            dep.purge(self.videos, TODAY, 30, self.cmd)
        self.assertEqual(self.remaining(), sorted([OLD, OLD2, NEW, "Pelicula.mp4"]))

    def test_lo_que_no_esta_en_el_snapshot_no_se_borra(self):
        os.environ["FAKE_LS_OMIT"] = OLD2
        deleted = dep.purge(self.videos, TODAY, 30, self.cmd)
        self.assertEqual(deleted, [OLD])
        self.assertIn(OLD2, self.remaining())


if __name__ == "__main__":
    unittest.main()
