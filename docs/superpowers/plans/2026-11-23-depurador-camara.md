# Depurador de clips de la cámara — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** que los clips de la cámara de más de 30 días se respalden en restic (repo del box) y recién después se borren del PVC.

**Architecture:** script Python `scripts/depurar_camara.py` corrido por un CronJob diario con la imagen de VideoRepo,
que trae restic 0.17.3 fijado por sha256. `sync_camera.py` deja de importar grabaciones de más de 30 días.

**Tech Stack:** Python 3 stdlib (unittest), restic 0.17.3, k8s CronJob, Argo CD.

**Spec:** `docs/superpowers/specs/2026-11-23-depurador-camara-design.md`

## Global Constraints

- Patrón de clip: `CamNet_record_(\d{8})_\d{6}_\d+\.mp4`; la fecha sale del nombre. Nada más se toca.
- Retención por defecto 30 días (`RETENTION_DAYS`).
- `restic backup --host videorepo --tag camara`; si falla, no se borra nada.
- Repo: `rest:http://gilway:<clave>@<ip tailnet del box>:8000/` (append-only), restic 0.17.3
  (`sha256 5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3` de `restic_0.17.3_linux_amd64.bz2`).
- Sin IPs privadas ni credenciales en el repo; Secret `camara-restic` (`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`).

## Review Focus

1. Un nombre `CamNet_record_` con fecha inválida (p. ej. `20261399`) no tiene que tirar el script: se ignora.
2. Los videos de la TV con nombres parecidos (`CamNet_algo.mp4`, `record_...mp4` sin prefijo) no se tocan.
3. Un snapshot que no contiene alguno de los candidatos (restic saltó un archivo ilegible) → ese no se borra.
4. `sync_camera` con una grabación vieja todavía en el grabador → no la vuelve a importar.
5. Sin candidatos no se llama a restic (no crea snapshots vacíos todos los días).

---

### Task 1: depurador + filtro en sync_camera

**Files:** Create `scripts/depurar_camara.py`, `test/python/test_depurar_camara.py`, `test/python/test_sync_camera.py`;
Modify `scripts/sync_camera.py`.

**Interfaces:**
- `clip_date(name: str) -> datetime.date | None` (en `depurar_camara.py`; `sync_camera` usa su propio
  `record_date(name)` sobre `record_*` sin prefijo).
- `candidates(names: Iterable[str], today: date, days: int) -> list[str]`
- `purge(video_dir: Path, today: date, days: int, restic: str) -> list[str]` → devuelve los borrados.

- [ ] Tests (unittest, restic falso = script sh en un tmpdir): `candidates` solo toma clips de cámara con fecha
  anterior a `today - days` e ignora fechas inválidas y otros nombres; `purge` sin candidatos no llama a restic;
  `backup` con rc≠0 → excepción y nada borrado; archivo ausente en `restic ls` → no se borra; caso feliz borra los
  candidatos y deja los demás. `sync_camera`: `is_too_old("record_20250101_000000_1.mp4", today, 30)` True.
- [ ] Correr `python3 -m unittest discover -s test/python` → fallan.
- [ ] Implementar. `purge` usa `restic backup --json` y toma `snapshot_id` del mensaje `summary`, después
  `restic ls --json <id>` y compara por `path`.
- [ ] Tests en verde. Commit `feat: depurador de clips de la camara con resguardo en restic`.

### Task 2: imagen, CronJob, Secret y CI

**Files:** Modify `Dockerfile`, `k8s/kustomization.yaml`, `.github/workflows/deploy.yml`, `README.md`,
`test/videorepo/deploy_test.exs`; Create `k8s/camara-depurador.yaml`, `deploy/restic.ps1`.

- [ ] deploy_test: CronJob `camara-depurador` `0 5 * * *`, `concurrencyPolicy: Forbid`, Secret `camara-restic`,
  PVC sin `readOnly`; Dockerfile con el sha256 de arriba; el workflow corre los tests de Python.
- [ ] Implementar (stage `restic` en el Dockerfile con verificación `sha256sum -c`), `deploy/restic.ps1` lee la clave
  del repo y la del rest-server del box por SSH y crea el Secret sin mostrarlas.
- [ ] `mix test` en verde. Commit `feat: CronJob camara-depurador y restic en la imagen`.

### Task 3: deploy y prueba en vivo

- [ ] Usuario corre `deploy/restic.ps1`. Push → imagen → Argo Synced.
- [ ] Job manual con `RETENTION_DAYS=1` → snapshot `camara` en el repo del box (`restic snapshots --tag camara`)
  y los clips del 22/11 fuera del PVC.
