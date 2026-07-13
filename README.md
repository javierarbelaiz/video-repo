# video-repo — repositorio de videos (Elixir/OTP) en k3s

App **Elixir** (Plug + Bandit) para **subir videos de alta calidad** por una web sencilla
y **servirlos por HTTP con soporte de Range** (reproducción resumible / seek → aguanta
reconexiones de la TV). Corre en un **pod** del k3s de `MyKaly` (192.168.1.199) y guarda
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
| GET | `/health` | readiness/liveness de k8s |

## Deploy

La imagen se construye en **GitHub Actions → ghcr.io** (el nodo no tiene docker). k3s la baja.

```sh
# 1) push -> Actions construye ghcr.io/javierarbelaiz/videorepo:latest
git push

# 2) hacer PÚBLICO el paquete (una vez): GitHub → tu perfil → Packages →
#    videorepo → Package settings → Change visibility → Public
#    (así k3s lo baja sin secret; la imagen no contiene datos, solo la app)

# 3) desplegar en k3s (kubectl funciona sin sudo en MyKaly)
kubectl apply -f k8s/videorepo.yaml
kubectl -n videorepo rollout status deploy/videorepo
```

Acceso: **http://192.168.1.199:30080**

### Actualizar

```sh
git push                                   # Actions reconstruye la imagen
kubectl -n videorepo rollout restart deploy/videorepo
```

## Reproducir en la TV (Noblex)

Copia la URL de un video desde la UI y lánzala (sin recompilar la app de la TV):

```sh
adb -s 192.168.1.96:5555 shell am start -n com.example.noblexcam/.MainActivity \
  -e url "http://192.168.1.199:30080/videos/mipeli.mp4"
```

## Config (env)

| Var | Default | |
|---|---|---|
| `PORT` | `4000` | puerto HTTP |
| `VIDEO_DIR` | `/data/videos` | carpeta de storage (montaje del PVC) |
| `TMPDIR` | `/data/videos/.uploads` | temp de subidas (mismo FS → mover = rename) |
