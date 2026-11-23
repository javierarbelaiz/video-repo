# Depurador de clips de la cámara con resguardo en restic — diseño corto

Fecha: 2026-11-23. Tamaño: cambio chico.

## Para qué

Los clips de la cámara (`CamNet_record_*.mp4`, que `camara-sync` sube cada 5 minutos) se acumulan en el PVC
`videos` sin límite: 668 clips en ~1,5 días. Se quiere que VideoRepo tenga solo el último mes y que lo más viejo
quede guardado en restic antes de borrarse.

## Alcance

- **Solo** los clips de la cámara: archivos que cumplen `CamNet_record_\d{8}_\d{6}_\d+\.mp4`. Los videos para la
  TV (subidos o importados de YouTube) no se tocan nunca (pedido del usuario).
- Retención en VideoRepo: 30 días, contados por la fecha del nombre (`record_YYYYMMDD_...`), no por el mtime
  (el mtime es la hora de subida, que cambia si se re-sube).

## Enfoques considerados

1. **Elegido por el usuario:** CronJob en k3s dentro de video-repo (Argo), que respalda con restic al rest-server
   del box por la tailnet y recién después borra.
2. Tarea en el box dentro de backup-central: reusa el restic local, pero queda fuera del repo y de Argo.
3. Dentro de la app Elixir: mezcla app y backups; un reinicio de la app corta el respaldo.

## Qué se hace

- **`scripts/depurar_camara.py`** (Python, como `sync_camera.py`):
  1. Lista `/data/videos`, toma los clips de la cámara con fecha del nombre anterior a hoy − 30 días.
  2. Sin candidatos: termina en 0.
  3. `restic backup --host videorepo --tag camara --files-from <lista>`; si falla, termina con error y **no borra**.
  4. Verifica con `restic ls <snapshot>` que cada candidato está en el snapshot recién creado; borra solo los
     verificados, del PVC directamente (`os.remove`).
- **restic en la imagen:** binario oficial de una versión fija, bajado en el build con su sha256 comprobado
  (decisión de Claude: no depender de descargas en cada arranque como yt-dlp).
- **CronJob `camara-depurador`:** una vez por día a las 05:00 (lejos del Nightly del box de 02:30), imagen de
  VideoRepo, PVC montado con escritura, `concurrencyPolicy: Forbid`, `backoffLimit: 1`.
- **Secret `camara-restic`** (`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`): lo crea el usuario con `deploy/restic.ps1`
  (lee los datos del box por SSH sin mostrarlos) y queda copia SOPS como los otros. Ninguna credencial en el repo.
- **`camara-sync` no vuelve a importar lo depurado:** hoy re-subiría cualquier `record_*` que siga en el grabador
  del box y no esté en VideoRepo. Se le agrega que saltee los que tienen más de 30 días.
- **En restic no se poda nada** por ahora (decisión del usuario con la propuesta de Claude): se puede podar después
  con la etiqueta `camara`.

## No objetivos

- Limpiar los originales del grabador en `J:\proyects\cam` (quedan para otro cambio).
- Restaurar desde la web.

## Restricciones

- Sin IPs privadas ni credenciales en el repo (los tests existentes lo controlan).
- Si el rest-server está caído, no se borra nada y el Job queda fallido (visible en Argo).

## Cómo se verifica

- Tests de `depurar_camara.py` con un restic falso: solo entran clips de cámara viejos; si `backup` falla no se
  borra nada; un archivo que no aparece en el snapshot no se borra.
- Test de `sync_camera.py`: saltea grabaciones de más de 30 días.
- En vivo: primer Job con candidatos reales → snapshot `camara` en el repo del box y los clips viejos fuera del PVC.
