# ---------- build: compila un release de Elixir ----------
FROM elixir:1.17-slim AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# mix.lock es opcional; si no existe, deps.get lo resuelve
COPY mix.exs ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile && mix release

# ---------- restic: versión fija, verificada por sha256 (la misma 0.17.3 que el repo del box) ----------
FROM debian:bookworm-slim AS restic
ARG RESTIC_VERSION=0.17.3
ARG RESTIC_SHA256=5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl bzip2 && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/restic.bz2 \
      "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" && \
    echo "${RESTIC_SHA256}  /tmp/restic.bz2" | sha256sum -c - && \
    bunzip2 /tmp/restic.bz2 && install -m 0755 /tmp/restic /usr/local/bin/restic

# ---------- runtime: el release trae su propio ERTS ----------
# curl/xz/unzip/openssl: el arranque baja ffmpeg, yt-dlp y deno al volumen y genera el cert TLS.
# python3: el CronJob camara-sync corre scripts/sync_camera.py con esta misma imagen.
FROM debian:bookworm-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends       libstdc++6 libncurses6 openssl ca-certificates curl xz-utils unzip python3 &&     rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8     VIDEO_DIR=/data/videos     TMPDIR=/data/videos/.uploads     TOOLS_DIR=/data/videos/.tools     TLS_DIR=/data/videos/.certs     PORT=4000     TLS_PORT=4443

WORKDIR /app
COPY --from=build /app/_build/prod/rel/videorepo ./
COPY rel/boot.sh /app/boot.sh
COPY scripts/sync_camera.py /app/scripts/sync_camera.py
# camara-depurador: respalda en restic y borra los clips viejos de la cámara.
COPY scripts/depurar_camara.py /app/scripts/depurar_camara.py
COPY --from=restic /usr/local/bin/restic /usr/local/bin/restic
RUN chmod +x /app/boot.sh

EXPOSE 4000 4443
CMD ["/app/boot.sh"]
