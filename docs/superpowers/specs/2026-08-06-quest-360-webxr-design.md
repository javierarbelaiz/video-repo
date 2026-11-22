# Reproductor 360 para Meta Quest sobre video-repo (WebXR)

Fecha: 2026-08-06
Estado: aprobado, listo para plan de implementación

## Problema

Se quiere ver video 360 equirectangular en un Meta Quest (<ip-del-quest>), usando
como fuente el repo de videos Elixir que ya corre en el k3s de MyKaly
(<ip-del-nodo>, NodePort 30080).

El visor **no tiene modo desarrollador** habilitado: el puerto adb 5555 está
cerrado y activarlo exige una organización de desarrollador verificada en Meta
más una conexión USB inicial. Cualquier diseño que dependa de sideload queda
bloqueado por un trámite ajeno al código.

## Alcance

**Dentro:**

- Reproducción de 360 **equirectangular mono** con head-tracking real e inmersión estéreo.
- Selección de video desde la biblioteca existente del video-repo.
- Servido por HTTPS desde la misma app Elixir.

**Fuera (decisiones explícitas, no omisiones):**

- **360 estéreo** (top-bottom / side-by-side). El material que se va a conseguir
  es mono. Agregarlo después no obliga a rehacer el renderer.
- **Cambios al conversor de YouTube.** El contenido 360 se sube a mano ya
  equirectangular por `/upload`. El conversor queda intacto (ver "Riesgos").
- **Menú 3D dentro de VR** con puntero láser. La selección ocurre en 2D antes de
  entrar en la sesión XR.
- **Video plano en pantalla virtual** ("cine virtual"). Se descartó: el objetivo
  es 360 real.
- Playlists, autoplay del siguiente, transcodificación.

## Restricción que define la arquitectura

**WebXR sólo existe en contexto seguro.** `navigator.xr` es `undefined` sobre
`http://`, y la única excepción es `localhost` — que no aplica cuando el visor
pide contenido a otra máquina de la red.

Consecuencia directa: `http://<ip-del-nodo>:30080` no puede servir la app. Hace
falta TLS. Esto no es una preferencia; sin ello la API no está disponible.

Referencias:
- <https://developers.google.com/ar/develop/webxr/requirements>
- <https://developer.mozilla.org/docs/Web/API/Navigator/xr>

## Enfoque elegido

Una ruta más dentro del video-repo existente, servida por WebXR + Three.js en el
navegador del Quest. Sin APK, sin modo desarrollador, sin toolchain Android.

Alternativas descartadas:

- **Unity + Meta XR SDK.** VR nativa de verdad, pero exige modo desarrollador,
  org verificada, cable USB, Unity instalado y builds largos. Desproporcionado
  para reproducir un mp4 sobre una esfera.
- **Media3 `SphericalGLSurfaceView` sideloadeado.** Tentador porque ya existe el
  músculo de noblex-cam (Kotlin + Media3 + CI en GitHub Actions). Se descartó por
  una razón técnica, no de esfuerzo: **una app Android común corre en el Quest
  como panel plano flotante, no en modo inmersivo.** Se vería el 360 en una
  ventana, paneando con el control en vez de girando la cabeza.
  `SphericalGLSurfaceView` fue diseñado para teléfonos con giroscopio.

## Arquitectura

```
Quest Browser (<ip-del-quest>)
   └─> https://<ip-del-nodo>:30443/vr        página WebXR
         ├─> GET /api/videos                 mismo origen, sin CORS
         │     └─ filtra los `_360` en el cliente
         └─> <video src="/videos/x_360.mp4"> Range 206 existente = seek
               └─> textura sobre esfera invertida + renderer.xr
```

### Organización del código

`router.ex` son hoy 11 KB con la página HTML completa embebida en el heredoc
`page()`. Sumar una segunda página con WebXR lo llevaría a ~20 KB y a mantener
dos lenguajes trenzados dentro de un string.

Se introduce `Plug.Static` y las páginas salen a archivos reales:

```
priv/static/index.html      <- el page() actual, movido tal cual
priv/static/vr/index.html   <- página WebXR
priv/static/vr/app.js       <- reproductor
priv/static/vr/three.min.js <- vendorizado
```

`router.ex` queda en ~5 KB haciendo sólo ruteo.

Three.js va **commiteado al repositorio**, no traído de un CDN: el pod tiene
salida a internet, pero una app de LAN que no arranca si falla un CDN externo es
frágil sin necesidad.

### Identificación del contenido 360

Un equirectangular y un video plano son ambos mp4; una vez transcodificado, nada
en el archivo lo distingue de forma confiable. Hay que marcarlo.

**Convención de nombre: sufijo `_360`** (ej. `playa_360.mp4`).

Razones:

- Cero cambios en la API. `/api/videos` ya devuelve `name`; el filtro es del cliente.
- Cero estado nuevo, cero migración, cero base de datos.
- `safe_name()` (`router.ex:138`) conserva `_` y dígitos: el sufijo sobrevive a la subida.
- Renombrar un archivo es toda la administración necesaria.

`/vr` lista **solamente** los `_360`; los 16 videos planos existentes no aparecen.

Costo aceptado: si se olvida el sufijo, el video no aparece sin explicación. Se
compensa mostrando la convención cuando el filtro da cero resultados.

### TLS

Dos listeners de Bandit sobre el mismo router:

```elixir
children = [
  Videorepo.Jobs,
  Supervisor.child_spec({Bandit, scheme: :http,  port: port,     ...}, id: :http),
  Supervisor.child_spec({Bandit, scheme: :https, port: tls_port, ...}, id: :https)
]
```

El `id:` explícito es obligatorio: dos tuplas `{Bandit, ...}` comparten child id
y el supervisor falla con `already_started`.

Configuración, siguiendo el patrón de `PORT` y `VIDEO_DIR` en `config/runtime.exs`:

| Variable | Default | Uso |
|---|---|---|
| `TLS_PORT` | `4443` | Puerto del listener HTTPS |
| `TLS_DIR` | `/data/videos/.certs` | Carpeta de `cert.pem` y `key.pem`, en el PVC |
| `TLS_HOST` | `<ip-del-nodo>` | CN y SAN del certificado autogenerado |

Certificado autofirmado generado **al boot si no existe**, replicando el patrón
ya usado para ffmpeg y yt-dlp:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" \
  -subj "/CN=<ip-del-nodo>" \
  -addext "subjectAltName=IP:<ip-del-nodo>,DNS:videorepo.local"
```

Se guarda en el PVC (`/data/videos/.certs`): fuera de git, sobrevive reinicios.
Hay que agregar `openssl` al `apt-get install` del boot.

El SAN con IP importa: sin él Chromium responde `ERR_CERT_COMMON_NAME_INVALID` y
la pantalla de bypass se vuelve más hostil.

**Degradación protectora:** si faltan los archivos del certificado, la app omite
el child de HTTPS y **arranca igual**. Un problema de certificado nunca puede
dejar sin video al Noblex.

Si el navegador del Quest rechaza el autofirmado incluso tras aceptar la
advertencia, el plan B es un certificado real de Let's Encrypt por desafío DNS-01
sobre un subdominio de `esenzia.shop` apuntando por `A` a <ip-del-nodo>. El video
sigue sin salir de la LAN.

### Despliegue

Tres cambios en `k8s/videorepo-src.yaml`:

1. **`priv` al `cp` de la línea 50.** Hoy copia sólo `mix.exs config lib`; sin
   esto los assets nunca llegan al pod.
2. `containerPort: 4443` y un NodePort `30443` en el Service.
3. `openssl` en el `apt-get install` del boot, más la generación del cert.

**El puerto HTTP 4000 → NodePort 30080 no se toca.** La TV Noblex reproduce desde
ahí (`http://<ip-del-nodo>:30080/videos/x.mp4`) y romperlo sería daño colateral
evitable. El HTTPS entra como listener adicional, nunca como reemplazo.

Actualización: `git pull` en `/home/thehook/video-repo` en el nodo →
`kubectl -n videorepo rollout restart deploy/videorepo`.

## El reproductor

Selección en 2D, reproducción en VR.

1. `/vr` lista los `_360` como botones HTML comunes.
2. Al elegir uno se carga el `<video>` y aparece "Entrar en VR".
3. Ese click cumple doble función: gesto de usuario requerido por el navegador
   para `video.play()`, y arranque de la sesión XR.
4. En VR: esfera de radio 500 con `scale.x = -1` (invierte las normales para
   quedar adentro), `THREE.VideoTexture` con `colorSpace = SRGBColorSpace` sobre
   `MeshBasicMaterial`, `renderer.xr.setReferenceSpaceType('local')`.
5. Gatillo = play/pausa. Botón de menú = salir. Al salir se vuelve a la lista 2D.

Construir un toolkit de UI en 3D (puntero, hover, blancos de click) sería más
código que el reproductor entero. Elegir en 2D es el 80/20.

## Manejo de errores

| Falla | Respuesta |
|---|---|
| `navigator.xr` undefined | "No hay WebXR: ¿entraste por https?" — el más probable de todos |
| `isSessionSupported('immersive-vr')` false | No es un visor; se permite vista plana igual |
| Evento `error` del `<video>` | Código y nombre; con 4K un fallo de decode es plausible |
| `/api/videos` falla | Mensaje + botón de reintento |
| Cero coincidencias `_360` | Recordatorio de la convención de nombre |

## Pruebas

El proyecto no tiene pruebas hoy; esto instala el andamiaje con ExUnit + `Plug.Test`.

**Servidor:**

- `/vr` devuelve 200 y `text/html`.
- `Plug.Static` sirve `/vr/app.js` con su content-type correcto.
- **Regresión del camino de la TV:** `/videos/:name` sigue devolviendo Range 206
  y `/api/videos` mantiene su forma `{name, size, mtime}`.
- **La aplicación arranca con los certificados ausentes.** Es el test que protege
  al Noblex.

**Cliente:**

- La detección de `navigator.xr` y el filtro `_360` son funciones puras: se
  prueban en el navegador de la laptop.
- El renderizado de la esfera y el head-tracking se verifican a mano en el visor.
  No hay forma honesta de automatizar eso acá.

## Riesgos

1. **El autofirmado puede no bastar.** Chromium suele conceder contexto seguro
   tras aceptar la advertencia, pero no está garantizado en todas las versiones
   del Quest Browser. Mitigación: plan B con Let's Encrypt ya identificado.
2. **Resolución del material 360.** En equirectangular la esfera completa se
   estira sobre el cuadro y el campo visual del Quest es ~90-100°: se ve cerca de
   un cuarto del ancho. Un equirect de 1080p deja ~480 px efectivos, peor que un
   DVD. El piso práctico es 4K.
   Consecuencia para el futuro: **el conversor de YouTube está capado a 1080p** en
   `converter.ex:79` (`bv*[height<=1080]`) y `converter.ex:102`
   (`scale=w=min(1920,iw)`, más `-level 4.1`). Queda fuera de alcance porque el
   contenido se sube a mano, pero si algún día se quiere importar 360 desde
   YouTube, hay que levantar ese cap.
3. **Decodificación 4K en el navegador.** El Quest Browser maneja 4K, pero el
   bitrate y el códec del archivo importan. Si un video no reproduce, el mensaje
   de error del `<video>` es el primer diagnóstico.
