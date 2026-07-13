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
RUN mix compile && mix release

# ---------- runtime: imagen minima, el release trae su propio ERTS ----------
FROM debian:bookworm-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 libncurses6 openssl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    VIDEO_DIR=/data/videos \
    PORT=4000 \
    TMPDIR=/data/videos/.uploads

WORKDIR /app
COPY --from=build /app/_build/prod/rel/videorepo ./

EXPOSE 4000
CMD ["bin/videorepo", "start"]
