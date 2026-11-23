"""sync_camera no vuelve a importar grabaciones que el depurador ya sacó de VideoRepo."""
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import sync_camera  # noqa: E402

TODAY = date(2026, 12, 25)


class TooOldTest(unittest.TestCase):
    def test_grabacion_mas_vieja_que_la_retencion(self):
        self.assertTrue(sync_camera.is_too_old("record_20261101_000000_1.mp4", TODAY, 30))

    def test_grabacion_reciente(self):
        self.assertFalse(sync_camera.is_too_old("record_20261220_000000_1.mp4", TODAY, 30))

    def test_nombre_sin_fecha_valida_no_se_considera_viejo(self):
        self.assertFalse(sync_camera.is_too_old("record_20261399_000000_1.mp4", TODAY, 30))


if __name__ == "__main__":
    unittest.main()
