#!/usr/bin/env bash
#
# Corre `mix test` dentro del pod de k3s.
#
# Por que existe: la laptop de desarrollo no tiene Elixir instalado y el nodo
# tampoco lo tiene en el host. El unico Elixir disponible es el de la imagen
# elixir:1.17-slim que corre el pod, que ademas ya tiene las deps compiladas.
#
# El fuente viaja por un pipe de tar (sin archivos intermedios) a /tmp/t dentro
# del pod, donde _build persiste entre corridas: la primera compila entera
# (~30s) y las siguientes son incrementales (~3s).
#
# IMPORTANTE: --no-start es obligatorio. mix.exs declara
# `mod: {Videorepo.Application, []}`, asi que `mix test` a secas arranca la
# aplicacion, que intenta bindear el puerto 4000 — ya ocupado por el servidor
# de produccion en ese mismo pod — y toda la corrida muere con :eaddrinuse.
# Las pruebas llaman al router directamente y no necesitan sockets.
#
# Uso:
#   scripts/test-in-pod.sh                            # toda la suite
#   scripts/test-in-pod.sh test/videorepo/tls_test.exs
#   scripts/test-in-pod.sh --only foo
#
set -euo pipefail

NODE="${VIDEOREPO_NODE:-thehook@192.168.1.199}"
NS="${VIDEOREPO_NS:-videorepo}"
WORK=/tmp/t

cd "$(dirname "$0")/.."

if [ ! -d test ]; then
  echo "error: no hay carpeta test/ en $(pwd)" >&2
  exit 1
fi

# Solo lo que mix necesita. priv/ va incluido: Plug.Static lo resuelve por
# :code.priv_dir y sin el fallan las pruebas de las paginas estaticas.
PATHS=(mix.exs config lib test)
[ -f mix.lock ] && PATHS+=(mix.lock)
[ -d priv ] && PATHS+=(priv)

POD_EXPR="\$(kubectl -n $NS get pod -l app=videorepo -o jsonpath='{.items[0].metadata.name}')"

# --- 1) mandar el fuente ---------------------------------------------------
# El stdin del ssh queda libre para el stream de tar, por eso el script remoto
# va como argumento y no como heredoc (un heredoc pisaria el pipe).
UNPACK="set -e
mkdir -p $WORK
rm -rf $WORK/lib $WORK/test $WORK/config $WORK/priv
tar -xzf - -C $WORK
[ -d $WORK/deps ] || cp -r /app/deps $WORK/deps"

tar -czf - "${PATHS[@]}" \
  | ssh -o ConnectTimeout=10 "$NODE" \
      "POD=$POD_EXPR; kubectl -n $NS exec -i \"\$POD\" -- sh -c '$UNPACK'"

# --- 2) correr las pruebas -------------------------------------------------
RUN="cd $WORK && export HOME=/app MIX_ENV=test && mix test --no-start $*"

ssh -o ConnectTimeout=10 "$NODE" \
  "POD=$POD_EXPR; kubectl -n $NS exec \"\$POD\" -- sh -c '$RUN'"
