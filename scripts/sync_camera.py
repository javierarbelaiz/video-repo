"""Import completed motion clips from the recorder into VideoRepo."""
import json
import os
import re
import subprocess
import tempfile
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.request import urlopen
from shutil import copyfileobj

# Las direcciones llegan por el entorno (CronJob camara-sync, Secret videorepo-red): la del grabador
# es una IP privada de la casa y no va en el repo.
CAM = os.environ.get("CAMERA_URL", "").rstrip("/")
REPO = os.environ.get("REPO_URL", "http://videorepo.videorepo.svc.cluster.local").rstrip("/")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")


RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))


def is_too_old(name, today, days):
    """El depurador saca de VideoRepo los clips de más de `days` días; si el original sigue en el grabador
    no hay que volver a importarlo. La fecha sale del nombre (record_YYYYMMDD_...)."""
    match = re.fullmatch(r"record_(\d{8})_\d{6}_\d+\.mp4", name)
    if not match:
        return False
    try:
        recorded = datetime.strptime(match.group(1), "%Y%m%d").date()
    except ValueError:
        return False
    return recorded < today - timedelta(days=days)


def read_json(url):
    with urlopen(url, timeout=10) as response:
        return json.load(response)


def wait_ready(url, timeout=180, every=10):
    """Espera a que VideoRepo responda: tras un deploy tarda ~1,5 min en volver (baja yt-dlp al arrancar)."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            with urlopen(url, timeout=5) as response:
                if response.status == 200:
                    return True
        except OSError:
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(every)


def sync():
    existing = {v["name"] for v in read_json(REPO + "/api/videos")}
    candidates = read_json(CAM + "/recordings")["items"]
    status = read_json(CAM + "/status")
    active = (status.get("record_file") or "").replace("\\", "/").split("/")[-1]
    for item in candidates:
        name = item["file"]
        if not re.fullmatch(r"record_[0-9_]+\.mp4", name) or name == active:
            continue
        if is_too_old(name, date.today(), RETENTION_DAYS):
            continue
        dest = "CamNet_" + name
        if dest in existing:
            continue
        with tempfile.TemporaryDirectory() as temp:
            video = Path(temp) / dest
            with urlopen(CAM + "/recordings/" + name, timeout=30) as src, video.open("wb") as out:
                copyfileobj(src, out)
            result = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(video)], capture_output=True)
            if result.returncode or not result.stdout.strip():
                continue
            # El grabador escribe MPEG-4 Part 2 (OpenCV no trae H.264), que ni el navegador ni la TV
            # reproducen: se convierte a H.264 con el moov al principio para que arranque sin bajarlo entero.
            h264 = Path(temp) / ("h264_" + dest)
            converted = subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(video), "-an",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(h264)], capture_output=True)
            if converted.returncode:
                print("no se pudo convertir", name, converted.stderr.decode(errors="replace")[-300:])
                continue
            final = Path(temp) / dest
            h264.replace(final)
            subprocess.run(["curl", "-fsS", "--max-time", "600", "-F", "file=@" + str(final),
                            REPO + "/upload"], check=True)


if __name__ == "__main__":
    if not CAM:
        raise SystemExit("falta CAMERA_URL (Secret videorepo-red)")
    if not wait_ready(REPO + "/health"):
        # Sin la app no hay a dónde subir: no es un error, la próxima corrida es en 5 minutos.
        print("VideoRepo no responde; se saltea esta corrida")
        raise SystemExit(0)
    sync()
