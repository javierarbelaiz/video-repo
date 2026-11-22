"""Import completed motion clips from the recorder into VideoRepo."""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.request import urlopen
from shutil import copyfileobj

# Las direcciones llegan por el entorno (CronJob camara-sync, Secret videorepo-red): la del grabador
# es una IP privada de la casa y no va en el repo.
CAM = os.environ.get("CAMERA_URL", "").rstrip("/")
REPO = os.environ.get("REPO_URL", "http://videorepo.videorepo.svc.cluster.local").rstrip("/")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def read_json(url):
    with urlopen(url, timeout=10) as response:
        return json.load(response)


def sync():
    existing = {v["name"] for v in read_json(REPO + "/api/videos")}
    candidates = read_json(CAM + "/recordings")["items"]
    status = read_json(CAM + "/status")
    active = (status.get("record_file") or "").replace("\\", "/").split("/")[-1]
    for item in candidates:
        name = item["file"]
        if not re.fullmatch(r"record_[0-9_]+\.mp4", name) or name == active:
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
            subprocess.run(["curl", "-fsS", "--max-time", "600", "-F", "file=@" + str(video),
                            REPO + "/upload"], check=True)


if __name__ == "__main__":
    if not CAM:
        raise SystemExit("falta CAMERA_URL (Secret videorepo-red)")
    sync()
