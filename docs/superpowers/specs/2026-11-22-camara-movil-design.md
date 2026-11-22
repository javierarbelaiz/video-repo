# Cámara en el celular como app instalada (web + PWA) — diseño corto

Fecha: 2026-11-22. Tamaño: cambio chico.

## Para qué

Ver la cámara de la entrada desde el celular, en casa y afuera por la tailnet, con el video en vivo, el pad del
motor y los clips, abriendo un ícono en la pantalla de inicio como si fuera una app. Hoy el navegador del celular
no muestra el video.

**Causa encontrada:** VideoRepo se publica por la tailnet en `https://mykaly.tail194ad9.ts.net:8444`
(`tailscale serve` con certificado válido). `/camara` mete el reproductor de go2rtc como
`http://<host>:1984/...`: dentro de una página HTTPS, Chrome lo bloquea por contenido mixto y el recuadro queda
vacío.

## Enfoques considerados

1. App nativa con ExoPlayer por RTSP desde go2rtc: robusta por la tailnet, pero es una app aparte que mantener.
2. App nativa con WebRTC: menor atraso, pero pesada y frágil con dos redes (LAN y tailnet).
3. **Elegido por el usuario:** arreglar la web y hacerla instalable desde Chrome (PWA). Sin app que mantener;
   depende del navegador, y por eso el arreglo apunta a lo que fallaba (contenido mixto).

## Qué se hace

- **go2rtc detrás del mismo origen HTTPS.** En `tailscale serve` de MyKaly, el puerto `:8444` suma la ruta
  `/go2rtc` → `http://127.0.0.1:1984` (go2rtc corre con hostNetwork en mykaly). El reproductor queda en
  `https://mykaly.tail194ad9.ts.net:8444/go2rtc/stream.html`, mismo origen: sin contenido mixto y con
  WebSocket seguro (`wss`).
- **La página elige el reproductor según cómo se la abrió:**
  - por HTTPS (tailnet, la que se instala en el celular): `/go2rtc/stream.html?src=entrada&mode=mse`. MSE va por
    el mismo WebSocket HTTPS, así que funciona igual en casa o afuera, sin depender de que WebRTC encuentre una
    ruta entre redes. Cuesta ~0,5–1 s más que WebRTC (decisión de Claude: preferí que ande siempre).
  - por HTTP en la LAN (`:30080`, la TV y la PC): sigue con WebRTC directo a `:1984`, como hoy.
- **Instalable como app:** `manifest.webmanifest` (nombre "Cámara", `start_url` `/camara`, `display: standalone`,
  colores del tema, ícono SVG) y su `<link rel="manifest">` en `/camara`. Sin service worker ni caché offline:
  una cámara en vivo no sirve sin conexión y un caché viejo solo confunde (decisión de Claude).
- **Celular:** botones del pad más grandes y que ocupen el ancho en pantallas chicas; video arriba, pad abajo,
  clips al final.

## No objetivos

- App nativa, notificaciones push, acceso desde fuera de la tailnet (Funnel/público).
- Cambiar el grabador del box o la cámara.

## Restricciones

- La configuración de `tailscale serve` vive en el nodo, fuera de Argo: se documenta en el README con el comando
  exacto para recrearla.
- Sin IPs privadas nuevas en el repo (los tests existentes lo controlan): la ruta usa `127.0.0.1`, que es local.

## Cómo se verifica

- `https://mykaly.tail194ad9.ts.net:8444/camara` muestra el video (MSE) desde la PC por la tailnet, y la
  consola no tiene errores de contenido mixto.
- `http://<nodo>:30080/camara` sigue con WebRTC.
- Chrome ofrece "Instalar app" con el manifest válido.
- En el celular (lo prueba el usuario): abrir la dirección de la tailnet, instalar, ver video en casa y con datos.
