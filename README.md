# DDC Spatial Epidemiology Training

Half-day Vertica spatial analytics workshop for Department of Disease Control (DDC) Thailand.
Delivered via Jupyter notebooks on Docker.

**Scenario:** 30 dengue cases across Bangkok, Chiang Mai, Chiang Rai.
You answer 4 urgent questions using Vertica spatial SQL.

## Prerequisites

- Docker Engine 24+ with Compose v2
- 8 GB RAM minimum (16 GB recommended)
- Ports: 5433 (Vertica), 8888 (Jupyter) or 8000 (JupyterHub)

---

## Option A: Single User (Development / Self-Study)

```bash
git clone https://github.com/wichais/ddc-spatial-training.git
cd ddc-spatial-training
docker compose up -d
```

First run takes ~2 minutes (loads SQL scripts into Vertica).
Watch progress:

```bash
docker compose logs -f training
```

When you see `Starting Jupyter Lab on port 8888`, open:

- **Jupyter Lab:** http://localhost:8888
- **Vertica SQL:** `docker exec -it ddc-vertica /opt/vertica/bin/vsql -U dbadmin -d VMart`

### Stop

```bash
docker compose down       # stop (data preserved)
docker compose down -v    # stop + delete all data
```

---

## Option B: Multi-User Workshop (JupyterHub, up to 40 trainees)

### 1. Build the trainee image

Course notebooks are baked into this image so each trainee gets their own writable copy.

```bash
docker build -t courses-trainee:latest -f docker/Dockerfile.trainee .
```

### 2. Start

```bash
docker compose -f docker-compose-training-40.yaml up -d
```

### 3. Wait for data initialization

```bash
docker logs -f ddc-data-init
```

Wait until it exits. This runs once (subsequent starts skip it).

### 4. Access

- **JupyterHub:** http://localhost:8000
- **Login:** `trainee01` / `trainee123` (through `trainee40`)
- **Admin:** `instructor` / `trainee123`

Each trainee gets an isolated Jupyter Lab container with their own copy of all notebooks.

### 5. Stop

```bash
docker compose -f docker-compose-training-40.yaml down
docker compose -f docker-compose-training-40.yaml down -v   # delete all data
```

---

## Vertica Connection

From inside any container (notebooks, JupyterHub):

```
Host:     ddc-vertica
Port:     5433
Database: VMart
User:     dbadmin
Password: (empty)
Schema:   ddc_training
```

From host machine: same but `Host: localhost`.

---

## Course Content

| Notebook | Topic | Key Functions |
|----------|-------|---------------|
| `00_slides.ipynb` | RISE slideshow (instructor) | - |
| `00_workshop_runner.ipynb` | Hands-on exercises (trainees) | - |
| `01_geography_distance.ipynb` | Distance queries, nearest hospital | `ST_Distance`, `ST_DWithin` |
| `02_risk_buffers.ipynb` | Fogging deployment zones | `ST_Buffer`, `ST_Union` |
| `03_hexbin_heatmap.ipynb` | Weekly situation report | `ST_GeoHash`, `DATE_TRUNC` |

SQL scripts in `course_1/sql/` run automatically during initialization.

---

## Project Structure

```
ddc-spatial-training/
  docker-compose.yaml                # single-user (dev)
  docker-compose-training-40.yaml    # multi-user (JupyterHub)
  ddc_helpers.py                     # run_query, show_on_map, show_buffers, show_heatmap
  docker/
    Dockerfile.training              # single-user + data-init image
    Dockerfile.trainee               # spawned trainee image (JupyterHub)
    entrypoint.sh                    # auto-init: SQL setup + viz
    run_sql.py                       # Python SQL executor (replaces vsql)
    jupyterhub_config.py             # 40 trainee accounts, DockerSpawner
  course_1/
    sql/                             # 4 SQL scripts (setup + 3 modules)
    notebooks/                       # 5 notebooks (slides + workshop + 3 modules)
```

---

## Server Sizing (Multi-User)

| Trainees | CPU | RAM | Disk |
|----------|-----|-----|------|
| 5 | 8 cores | 16 GB | 50 GB |
| 20 | 24 cores | 64 GB | 100 GB |
| 40 | 48 cores | 96 GB | 150 GB |
