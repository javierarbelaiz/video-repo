# video-repo — repositorio de videos (Elixir/OTP) en k3s

App **Elixir** (Plug + Bandit) para **subir videos de alta calidad** por una web sencilla
y **servirlos por HTTP con soporte de Range** (reproducción resumible / seek → aguanta
reconexiones de la TV). Corre en un **pod** del k3s de `MyKaly` y guarda
los archivos en el disco de 1 TB (`/data`) vía un PVC.

Encaja con [[noblex-cam]]: la app de la TV reproduce cualquier `http://…/videos/x.mp4` de aquí.

## Arquitectura

```
navegador ──subir──▶  Pod (Bandit/Plug)  ──guarda──▶  PVC local-path (/data/k3s-storage)
   Noblex  ──HTTP Range (206)──▶  Pod  ──send_file offset/len──▶  video
```

- **Sin transcodificar**: los archivos se guardan tal cual (alta calidad).
- **Range/seek**: `GET /videos/:name` responde `206 Partial Content`; si la TV se corta,
  reconecta y sigue desde el byte que necesita.
- **Resiliencia**: supervisor OTP; Bandit maneja miles de conexiones concurrentes.

## Endpoints

| Método | Ruta | Qué hace |
|---|---|---|
| GET | `/` | UI: drag-drop para subir + lista de videos |
| POST | `/upload` | subida multipart (campo `file`), hasta 50 GB |
| GET | `/videos/:name` | sirve el video con Range |
| GET | `/api/videos` | JSON con la lista |
| DELETE | `/videos/:name` | borra un video |
| GET | `/camara` | imagen en vivo de la cámara de la entrada + clips grabados |
| GET | `/health` | readiness/liveness de k8s |

## Deploy (Argo CD)

El camino normal es **push a `main`**:

1. `.github/workflows/deploy.yml` corre `mix test`, construye la imagen y la publica en ghcr (privada)
   como `ghcr.io/javierarbelaiz/videorepo:sha-<7>`.
2. La misma Action actualiza `newTag` en `k8s/kustomization.yaml` con un commit `[skip ci]`.
3. Argo CD (Application `videorepo` en `Devs/homelab-argocd`) sincroniza `k8s/`: la app
   y el CronJob `camara-sync`, que trae los clips del grabador de la cámara. El mDNS
   (`videorepo.local`) vive en su propio repo y Application, `mdns-videorepo`.

- **Volver atrás:** poner en `k8s/kustomization.yaml` un `sha-<7>` ya publicado y hacer push.
- **IPs de la casa:** no van en el repo. La IP del nodo (`NODE_IP`) y el grabador de la cámara
  (`CAMERA_URL`) viven en el Secret `videorepo-red`: `deploy/red.ps1` lo carga y guarda la copia
  cifrada con SOPS en `deploy/secretos/`; `deploy/red.ps1 aplicar` lo restaura. Ver `.env.example`.
- **Imagen privada:** el cluster la baja con el Secret `ghcr-pull` del namespace.
- **Cámara en vivo:** `go2rtc` (k8s/go2rtc.yaml, hostNetwork en mykaly, puertos 1984 y 8555) toma el canal
  H.264 de la cámara y lo sirve por WebRTC (~0,3 s) a `/camara`. Usuario, clave y host de la cámara viven en el
  Secret `camara-rtsp` (copia SOPS en `deploy/secretos/`); la API solo expone el reproductor (`allow_paths`).
- **Motor de la cámara (PTZ):** el pad de `/camara` manda `POST /camara/ptz/move` (dirección, velocidad,
  duración) y `/camara/ptz/stop`; VideoRepo valida y reenvía al grabador del box (`CAMERA_URL`), que maneja la
  cámara por ONVIF con sus credenciales. Cada movimiento frena solo (tope 2 s). La cámara no informa posición
  ni presets: los movimientos son relativos.
- **Cámara en el celular (app instalable):** abrir `https://<nodo>.<tailnet>.ts.net:8444/camara` con Tailscale
  y en Chrome "Instalar app" (manifest + ícono). Por HTTPS el reproductor va por `/go2rtc` del mismo origen, en
  modo MSE (anda en casa y afuera); por HTTP en la LAN sigue WebRTC directo a `:1984`. Esa ruta es config del
  nodo, fuera de Argo; para recrearla en MyKaly (operador `thehook`, sin sudo):
  `tailscale serve --bg --https=8444 --set-path=/go2rtc http://127.0.0.1:1984`
- **Clips por movimiento:** el grabador del box los escribe en MPEG-4 Part 2; `camara-sync` los convierte a
  H.264 (`+faststart`) antes de subirlos, para que se vean en el navegador y la TV.
- **Datos:** el Namespace y el PVC `videos` llevan `Prune=false,Delete=false`: Argo nunca los borra.
- Al arrancar, el contenedor (`rel/boot.sh`) deja ffmpeg/yt-dlp/deno en el volumen (yt-dlp se
  actualiza en cada arranque) y genera el certificado HTTPS si falta.

Acceso: `http://<ip-del-nodo>:30080` (TV) y `https://<ip-del-nodo>:30443/vr` (WebXR).

## Reproducir en la TV (Noblex)

Copia la URL de un video desde la UI y lánzala (sin recompilar la app de la TV):

```sh
adb -s <ip-de-la-tv>:5555 shell am start -n com.example.noblexcam/.MainActivity \
  -e url "http://<ip-del-nodo>:30080/videos/mipeli.mp4"
```

## Config (env)

| Var | Default | |
|---|---|---|
| `PORT` | `4000` | puerto HTTP |
| `VIDEO_DIR` | `/data/videos` | carpeta de storage (montaje del PVC) |
| `TMPDIR` | `/data/videos/.uploads` | temp de subidas (mismo FS → mover = rename) |
| `TOOLS_DIR` | `/data/videos/.tools` | ffmpeg, yt-dlp y deno (en el volumen) |
| `TLS_HOST` | — | IP del nodo para el cert HTTPS (Secret `videorepo-red`, `NODE_IP`) |
| `CAMERA_URL` | — | grabador de la cámara (Secret `videorepo-red`); sin ella `/camara/imagen` da 503 |
