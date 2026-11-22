#!/bin/sh
# Arranque del contenedor: herramientas en el volumen, certificado TLS y después el release.
# Es lo mismo que hacía el script del Deployment viejo, pero sin compilar: el código ya viene en la imagen.
set -eu
mkdir -p "$TMPDIR" "$VIDEO_DIR" "$TOOLS_DIR" "$TLS_DIR"

echo "[boot] herramientas (ffmpeg + yt-dlp + deno) en el PVC"
# ffmpeg SI se congela: una versión estable evita sorpresas de transcodificación.
if [ ! -x "$TOOLS_DIR/ffmpeg" ]; then
  curl -fsSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz -o /tmp/ff.tar.xz \
    && mkdir -p /tmp/ffx && tar -xf /tmp/ff.tar.xz -C /tmp/ffx --strip-components=1 \
    && cp /tmp/ffx/ffmpeg /tmp/ffx/ffprobe "$TOOLS_DIR/" && rm -rf /tmp/ff.tar.xz /tmp/ffx \
    || echo "[boot] WARN: falló la descarga de ffmpeg"
fi
# yt-dlp NO se congela: YouTube rota sus defensas cada pocas semanas. Se baja en cada arranque sobre un
# archivo aparte y solo se pisa el bueno si la descarga salió entera.
if curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -o "$TOOLS_DIR/yt-dlp.new"; then
  mv "$TOOLS_DIR/yt-dlp.new" "$TOOLS_DIR/yt-dlp" && chmod +x "$TOOLS_DIR/yt-dlp"
  echo "[boot] yt-dlp $("$TOOLS_DIR/yt-dlp" --version 2>/dev/null || echo '?')"
else
  rm -f "$TOOLS_DIR/yt-dlp.new"
  echo "[boot] WARN: no pude actualizar yt-dlp, sigo con el que había"
fi
# deno resuelve los desafíos JS de YouTube.
if [ ! -x "$TOOLS_DIR/deno" ]; then
  curl -fsSL https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && unzip -oq /tmp/deno.zip -d "$TOOLS_DIR" && rm -f /tmp/deno.zip \
    || echo "[boot] WARN: falló la descarga de deno (yt-dlp puede fallar con desafíos JS)"
fi
chmod +x "$TOOLS_DIR"/* 2>/dev/null || true
export PATH="$TOOLS_DIR:$PATH"

# Certificado autofirmado para HTTPS (WebXR exige contexto seguro). La IP del nodo (TLS_HOST) llega del
# Secret videorepo-red. Si ya existe en el volumen se reusa: el navegador ya lo tiene aceptado.
if [ ! -f "$TLS_DIR/cert.pem" ] || [ ! -f "$TLS_DIR/key.pem" ]; then
  if [ -n "${TLS_HOST:-}" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" -subj "/CN=$TLS_HOST" \
      -addext "subjectAltName=IP:$TLS_HOST,DNS:videorepo.local" \
      && echo "[boot] cert generado" || echo "[boot] WARN: falló el cert, arranco solo HTTP"
  else
    echo "[boot] WARN: sin TLS_HOST no genero cert, arranco solo HTTP"
  fi
fi

exec /app/bin/videorepo start
