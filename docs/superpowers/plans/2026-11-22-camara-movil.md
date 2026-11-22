# Cámara en el celular (web + PWA) — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** que `/camara` muestre el video abierto por la tailnet HTTPS (`:8444`) y se pueda instalar como app en el celular.

**Architecture:** `tailscale serve` en MyKaly suma la ruta `/go2rtc` del `:8444` hacia go2rtc local, así el reproductor
queda en el mismo origen HTTPS. La página elige reproductor según `location.protocol`, y un manifest la hace instalable.

**Tech Stack:** Elixir/Plug (VideoRepo), HTML/JS estático, go2rtc 1.9.15, Tailscale serve.

**Spec:** `docs/superpowers/specs/2026-11-22-camara-movil-design.md`

## Global Constraints

- Por HTTPS: reproductor `/go2rtc/stream.html?src=entrada&mode=mse` (mismo origen).
- Por HTTP (LAN `:30080`): `http://<host>:1984/stream.html?src=entrada&mode=webrtc`, como hoy.
- Manifest: nombre "Cámara", `start_url` `/camara`, `display` `standalone`, ícono SVG; sin service worker.
- Sin IPs privadas nuevas en el repo; `tailscale serve` documentado en el README.

## Review Focus

1. Página abierta por HTTPS con otro puerto o por `videorepo.local`: tiene que elegir el reproductor por protocolo, no por host.
2. El pad en pantallas angostas (360 px) no tiene que desbordar ni requerir scroll horizontal.
3. `manifest.webmanifest` tiene que servirse con `application/manifest+json`, sino Chrome no lo toma.

---

### Task 1: Página y manifest

**Files:**
- Modify: `priv/static/camera.html`, `lib/videorepo/router.ex` (servir `manifest.webmanifest` e `icon.svg`)
- Create: `priv/static/manifest.webmanifest`, `priv/static/icon.svg`
- Test: `test/videorepo/deploy_test.exs`, `test/videorepo/router_test.exs`

- [ ] **Step 1: tests que fallan**
  - deploy_test `la página elige el reproductor por protocolo`: `camera.html` contiene `location.protocol==='https:'`,
    `/go2rtc/stream.html?src=entrada&mode=mse` y `:1984/stream.html?src=entrada&mode=webrtc`, y `<link rel="manifest" href="/manifest.webmanifest">`.
  - deploy_test `el manifest instala la cámara como app`: JSON con `name` "Cámara", `start_url` "/camara",
    `display` "standalone" e ícono `/icon.svg` con `sizes` "any".
  - router_test `GET /manifest.webmanifest` → 200 con `content-type` que empieza con `application/manifest+json`;
    `GET /icon.svg` → 200 `image/svg+xml`.
- [ ] **Step 2:** correr la suite → fallan esos tests.
- [ ] **Step 3:** implementar. Rutas `get "/manifest.webmanifest"` y `get "/icon.svg"` en el router con su content-type;
  CSS de celular: pad con botones de `min(22vw, 4.2rem)`, video arriba, sin desborde a 360 px.
- [ ] **Step 4:** suite en verde.
- [ ] **Step 5:** commit `feat: /camara instalable como app y reproductor por HTTPS en el mismo origen`.

### Task 2: Ruta de go2rtc en tailscale serve y verificación

**Files:** Modify: `README.md`.

- [ ] **Step 1:** en MyKaly (operador `thehook`, sin sudo):
  `tailscale serve --bg --https=8444 --set-path=/go2rtc http://127.0.0.1:1984`.
  Expected: `tailscale serve status` muestra `/go2rtc proxy http://127.0.0.1:1984` bajo `:8444`, y `/` sigue igual.
- [ ] **Step 2:** `curl https://mykaly.tail194ad9.ts.net:8444/go2rtc/stream.html` → 200, y `/go2rtc/api/config` → 404.
- [ ] **Step 3:** README: sección de la cámara en el celular con el comando del Step 1.
- [ ] **Step 4:** push → deploy; en el navegador, `https://mykaly.tail194ad9.ts.net:8444/camara` reproduce (modo MSE),
  sin errores de contenido mixto; `http://<nodo>:30080/camara` sigue en WebRTC; el manifest se descarga bien.
- [ ] **Step 5:** commit `docs: ruta /go2rtc en tailscale serve para la cámara en el celular`.
