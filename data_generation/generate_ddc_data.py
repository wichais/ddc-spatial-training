#!/usr/bin/env python3
"""
DDC Patient Data Generator for Vertica Spatial Analytics Training
=================================================================

Generates realistic, spatially-clustered disease surveillance data
for Thailand's Department of Disease Control (DDC). Designed to produce
5-10 million rows of CSV data that, once loaded into Vertica, will
create visually compelling heatmaps and spatial queries.

Key design choices
------------------
- Coordinates are CLUSTERED around ~20 real Thai-city hotspots using
  Gaussian scatter (sigma ~0.02 deg, roughly 2 km). This produces
  realistic outbreak patterns rather than a uniform random carpet.
- Disease codes are weighted so dengue dominates (matching Thai
  epidemiology), followed by COVID-19, TB, malaria, and leptospirosis.
- Age follows a truncated normal distribution (mean=35, std=15).
- Output is a single CSV, ready for Vertica COPY ... DIRECT.

Usage
-----
    python generate_ddc_data.py                  # default 5 000 000 rows
    python generate_ddc_data.py --rows 10000000  # 10 million rows

Dependencies
------------
    pip install -r requirements.txt
    # pandas, numpy, faker
"""

import argparse
import sys
import time
import uuid
from pathlib import Path

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

DEFAULT_ROW_COUNT = 5_000_000
CHUNK_SIZE = 1_000_000          # progress + memory-friendly chunk size
OUTPUT_FILENAME = "ddc_patients.csv"
RANDOM_SEED = 42

# ---------------------------------------------------------------------------
# Disease distribution (weighted)
# ---------------------------------------------------------------------------

DISEASES = ["Dengue", "COVID-19", "TB", "Malaria", "Leptospirosis"]
DISEASE_WEIGHTS = np.array([0.40, 0.25, 0.15, 0.10, 0.10])

# ---------------------------------------------------------------------------
# Outcome distribution (weighted)
# ---------------------------------------------------------------------------

OUTCOMES = ["Recovered", "Hospitalized", "Deceased"]
OUTCOME_WEIGHTS = np.array([0.70, 0.25, 0.05])

# ---------------------------------------------------------------------------
# Gender distribution
# ---------------------------------------------------------------------------

GENDERS = ["M", "F", "Other"]
GENDER_WEIGHTS = np.array([0.49, 0.49, 0.02])

# ---------------------------------------------------------------------------
# Hotspot centroids -- real Thai cities with realistic coordinates.
# Each entry: (city_label, latitude, longitude, weight)
# Weight controls how many cases fall in this hotspot.
# Bangkok gets 5 hotspots (large city, high density).
# ---------------------------------------------------------------------------

HOTSPOTS = [
    # Bangkok (5 hotspots -- dense urban, highest case load)
    ("Bangkok - Khlong Toei",        13.7230, 100.5530, 0.12),
    ("Bangkok - Din Daeng",          13.7640, 100.5580, 0.10),
    ("Bangkok - Bang Kapi",          13.7660, 100.6470, 0.08),
    ("Bangkok - Thon Buri",          13.7190, 100.4870, 0.06),
    ("Bangkok - Lat Krabang",        13.7280, 100.7520, 0.05),

    # Chiang Mai (3 hotspots)
    ("Chiang Mai - Old City",        18.7870, 98.9820, 0.07),
    ("Chiang Mai - Nimman",          18.7960, 98.9680, 0.05),
    ("Chiang Mai - San Sai",         18.8370, 99.0320, 0.04),

    # Chiang Rai (2 hotspots)
    ("Chiang Rai - Mueang",          19.9100, 99.8310, 0.04),
    ("Chiang Rai - Mae Sai",         20.4280, 99.8760, 0.03),

    # Nakhon Ratchasima (2 hotspots)
    ("Nakhon Ratchasima - Mueang",   14.9706, 102.1019, 0.05),
    ("Nakhon Ratchasima - Pak Chong", 14.7083, 101.4150, 0.03),

    # Khon Kaen (2 hotspots)
    ("Khon Kaen - Mueang",           16.4322, 102.8236, 0.04),
    ("Khon Kaen - Ban Phai",         16.0734, 102.7321, 0.03),

    # Songkhla (2 hotspots)
    ("Songkhla - Hat Yai",            7.0049, 100.4745, 0.05),
    ("Songkhla - Mueang",             7.1896, 100.5946, 0.03),

    # Udon Thani (2 hotspots)
    ("Udon Thani - Mueang",          17.4156, 102.7872, 0.04),
    ("Udon Thani - Nong Han",        17.3742, 102.7264, 0.02),

    # Nakhon Si Thammarat (2 hotspots)
    ("Nakhon Si Thammarat - Mueang",  8.4324, 99.9631, 0.04),
    ("Nakhon Si Thammarat - Thung Song", 8.1671, 99.6790, 0.02),
]

# Province code lookup: rough lat/lon bounding boxes to assign province codes.
# Full mapping would use a shapefile; this heuristic covers the hotspot cities.
PROVINCE_LOOKUP = [
    # (province_code, subdistrict_base, min_lat, max_lat, min_lon, max_lon)
    ("10",  100,  13.50, 14.00, 100.30, 100.95),   # Bangkok
    ("50",  500,  18.10, 19.76,  98.06,  99.54),   # Chiang Mai
    ("57",  570,  19.50, 20.50,  99.20, 100.60),   # Chiang Rai
    ("30",  300,  14.30, 15.80, 101.00, 103.00),   # Nakhon Ratchasima
    ("40",  400,  15.80, 17.00, 101.80, 103.30),   # Khon Kaen
    ("90",  900,   6.30,  7.60, 100.00, 101.00),   # Songkhla
    ("41",  410,  16.80, 18.00, 102.20, 103.30),   # Udon Thani
    ("80",  800,   7.80,  9.00,  99.20, 100.30),   # Nakhon Si Thammarat
]


# ---------------------------------------------------------------------------
# Helper: assign province_code and subdistrict_code from coordinates
# ---------------------------------------------------------------------------

def assign_province(lats: np.ndarray, lons: np.ndarray):
    """
    Vectorised province assignment based on bounding-box lookup.
    Returns (province_codes, subdistrict_codes) as object arrays.
    """
    n = len(lats)
    province_codes = np.full(n, "99", dtype=object)    # default "unknown"
    subdistrict_codes = np.zeros(n, dtype=np.int32)

    for pcode, sub_base, lat_min, lat_max, lon_min, lon_max in PROVINCE_LOOKUP:
        mask = (
            (lats >= lat_min) & (lats <= lat_max) &
            (lons >= lon_min) & (lons <= lon_max)
        )
        province_codes[mask] = pcode
        # Subdistrict: deterministic hash from coords for variety
        subdistrict_codes[mask] = sub_base + (
            (lats[mask] * 1000).astype(np.int32) % 20 + 1
        )

    return province_codes, subdistrict_codes


# ---------------------------------------------------------------------------
# Core generator
# ---------------------------------------------------------------------------

def generate_chunk(n: int, rng: np.random.Generator) -> pd.DataFrame:
    """
    Generate *n* rows of synthetic patient data.
    All heavy lifting uses NumPy vectorised ops -- no Python row loops.
    """

    # --- Hotspot selection --------------------------------------------------
    hotspot_labels = [h[0] for h in HOTSPOTS]
    hotspot_lats   = np.array([h[1] for h in HOTSPOTS])
    hotspot_lons   = np.array([h[2] for h in HOTSPOTS])
    hotspot_wts    = np.array([h[3] for h in HOTSPOTS])
    hotspot_wts   /= hotspot_wts.sum()  # normalise

    indices = rng.choice(len(HOTSPOTS), size=n, p=hotspot_wts)

    # --- Spatial coordinates (Gaussian scatter around hotspot centres) ------
    sigma = 0.02   # ~2 km at Thai latitudes
    latitudes  = hotspot_lats[indices] + rng.normal(0, sigma, n)
    longitudes = hotspot_lons[indices] + rng.normal(0, sigma, n)

    # Clamp to Thailand bounding box (5.5-20.5 N, 97.3-105.6 E)
    latitudes  = np.clip(latitudes,   5.5,  20.5)
    longitudes = np.clip(longitudes, 97.3, 105.6)

    # --- Province assignment ------------------------------------------------
    province_codes, subdistrict_codes = assign_province(latitudes, longitudes)

    # --- Patient IDs (UUID4) ------------------------------------------------
    patient_ids = [str(uuid.uuid4()) for _ in range(n)]

    # --- Infection date: uniform over 2023-01-01 to 2024-12-31 (730 days) --
    start_date = np.datetime64("2023-01-01")
    random_days = rng.integers(0, 730, size=n)
    infection_dates = start_date + random_days.astype("timedelta64[D]")

    # --- Disease code (weighted) --------------------------------------------
    disease_codes = rng.choice(DISEASES, size=n, p=DISEASE_WEIGHTS)

    # --- Severity (1-10, skewed lower for most cases) -----------------------
    # Beta distribution stretched to 1-10 gives a right skew.
    severity_raw = rng.beta(2, 5, size=n)
    severity_scores = np.clip(np.round(severity_raw * 10 + 1).astype(int), 1, 10)

    # --- Outcome (weighted) -------------------------------------------------
    outcomes = rng.choice(OUTCOMES, size=n, p=OUTCOME_WEIGHTS)

    # --- Age (truncated normal, mean=35, std=15, range 1-90) ----------------
    ages_raw = rng.normal(35, 15, size=n)
    ages = np.clip(np.round(ages_raw).astype(int), 1, 90)

    # --- Gender (weighted) --------------------------------------------------
    genders = rng.choice(GENDERS, size=n, p=GENDER_WEIGHTS)

    # --- Assemble DataFrame -------------------------------------------------
    df = pd.DataFrame({
        "patient_id":      patient_ids,
        "infection_date":  infection_dates,
        "disease_code":    disease_codes,
        "severity_score":  severity_scores,
        "outcome":         outcomes,
        "age":             ages,
        "gender":          genders,
        "latitude":        np.round(latitudes, 6),
        "longitude":       np.round(longitudes, 6),
        "province_code":   province_codes,
        "subdistrict_code": subdistrict_codes,
    })

    return df


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate realistic DDC patient data for Vertica training."
    )
    parser.add_argument(
        "--rows",
        type=int,
        default=DEFAULT_ROW_COUNT,
        help=f"Total number of rows to generate (default: {DEFAULT_ROW_COUNT:,})",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=OUTPUT_FILENAME,
        help=f"Output CSV filename (default: {OUTPUT_FILENAME})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=RANDOM_SEED,
        help=f"Random seed for reproducibility (default: {RANDOM_SEED})",
    )
    args = parser.parse_args()

    total_rows = args.rows
    output_path = Path(args.output)
    rng = np.random.default_rng(args.seed)

    print(f"{'=' * 60}")
    print(f"  DDC Patient Data Generator")
    print(f"  Target rows : {total_rows:>12,}")
    print(f"  Output file : {output_path}")
    print(f"  Random seed : {args.seed}")
    print(f"{'=' * 60}")

    t_start = time.time()
    rows_written = 0
    first_chunk = True

    while rows_written < total_rows:
        chunk_n = min(CHUNK_SIZE, total_rows - rows_written)
        df = generate_chunk(chunk_n, rng)

        df.to_csv(
            output_path,
            mode="w" if first_chunk else "a",
            header=first_chunk,
            index=False,
        )

        rows_written += chunk_n
        elapsed = time.time() - t_start
        rate = rows_written / elapsed if elapsed > 0 else 0
        print(
            f"  [PROGRESS] {rows_written:>12,} / {total_rows:,} rows "
            f"({rows_written / total_rows * 100:5.1f}%)  "
            f"| {elapsed:6.1f}s | {rate:,.0f} rows/s"
        )
        first_chunk = False

    elapsed_total = time.time() - t_start
    file_size_mb = output_path.stat().st_size / (1024 * 1024)

    print(f"{'=' * 60}")
    print(f"  DONE")
    print(f"  Rows written : {rows_written:>12,}")
    print(f"  File size    : {file_size_mb:>12.1f} MB")
    print(f"  Time elapsed : {elapsed_total:>12.1f} s")
    print(f"  Output       : {output_path.resolve()}")
    print(f"{'=' * 60}")
    print()
    print("Next step: load into Vertica with:")
    print(f"  COPY ddc_patients FROM LOCAL '{output_path.resolve()}'")
    print(f"       DELIMITER ','  ENCLOSED BY '\"'  SKIP 1  DIRECT;")


if __name__ == "__main__":
    main()
