#!/usr/bin/env python3
# pip install vertica-python pandas folium shapely
"""
Dengue Outbreak Map -- Vertica Spatial Analytics Visualisation
==============================================================

Connects to a Vertica database that holds pre-computed spatial layers
(hexbin aggregations and risk buffer zones) and renders them on an
interactive Folium map centred on Thailand.

If Vertica is unavailable the script falls back gracefully to built-in
sample data so attendees can still see the visualisation during early
course setup.

Layers
------
1. Hexbin heatmap   -- coloured polygons from ``dengue_hexbin_report``,
                       intensity driven by case count.
2. Risk buffers     -- concentric circles (500 m / 1 km / 2 km) around
                       high-risk locations from ``dengue_risk_zones``.
3. Hospital markers -- blue icons with popup facility names.
4. School markers   -- green icons with popup school names.

Environment variables (all optional)
------------------------------------
    VERTICA_HOST      default: localhost
    VERTICA_PORT      default: 5433
    VERTICA_USER      default: dbadmin
    VERTICA_PASSWORD  default: (empty)
    VERTICA_DATABASE  default: VMart

Output
------
    outbreak_map.html   -- open in any browser.
"""

import os
import sys
import warnings
from pathlib import Path

import pandas as pd

try:
    import folium
    from folium import FeatureGroup, GeoJson, Marker, Icon
    from folium.plugins import MeasureControl
except ImportError:
    sys.exit(
        "ERROR: folium is not installed.  Run:\n"
        "  pip install folium\n"
    )

try:
    from shapely import wkt as shapely_wkt
    from shapely.geometry import mapping as shapely_mapping
    HAS_SHAPELY = True
except ImportError:
    HAS_SHAPELY = False
    warnings.warn(
        "shapely is not installed -- hexbin WKT polygons will be skipped. "
        "Install with:  pip install shapely"
    )


# ---------------------------------------------------------------------------
# Vertica connection configuration (from environment)
# ---------------------------------------------------------------------------

VERTICA_CONFIG = {
    "host":     os.getenv("VERTICA_HOST",     "localhost"),
    "port":     int(os.getenv("VERTICA_PORT",  "5433")),
    "user":     os.getenv("VERTICA_USER",      "dbadmin"),
    "password": os.getenv("VERTICA_PASSWORD",  ""),
    "database": os.getenv("VERTICA_DATABASE",  "VMart"),
    "read_timeout": 30,
    "connection_timeout": 10,
}

VERTICA_SCHEMA = os.getenv("VERTICA_SCHEMA", "ddc_training")

OUTPUT_FILE = "outbreak_map.html"

# ---------------------------------------------------------------------------
# Map colour scheme
# ---------------------------------------------------------------------------

# Risk buffer styling: radius in metres -> (colour, fill_opacity)
RISK_BUFFER_STYLES = {
    500:  ("#e74c3c", 0.45),   # 500 m  -- red   (high risk)
    1000: ("#e67e22", 0.30),   # 1 km   -- orange (medium)
    2000: ("#f1c40f", 0.18),   # 2 km   -- yellow (watch zone)
}

# Hexbin colour ramp: maps normalised intensity (0..1) to fill colour.
HEXBIN_RAMP = [
    (0.0,  "#ffffb2"),
    (0.25, "#fecc5c"),
    (0.50, "#fd8d3c"),
    (0.75, "#f03b20"),
    (1.0,  "#bd0026"),
]


def intensity_to_colour(value: float) -> str:
    """Return a hex colour by linearly interpolating the ramp."""
    for i in range(len(HEXBIN_RAMP) - 1):
        lo_v, lo_c = HEXBIN_RAMP[i]
        hi_v, hi_c = HEXBIN_RAMP[i + 1]
        if value <= hi_v:
            # Linear blend between lo_c and hi_c
            t = (value - lo_v) / (hi_v - lo_v) if hi_v != lo_v else 0.0
            r = int(int(lo_c[1:3], 16) * (1 - t) + int(hi_c[1:3], 16) * t)
            g = int(int(lo_c[3:5], 16) * (1 - t) + int(hi_c[3:5], 16) * t)
            b = int(int(lo_c[5:7], 16) * (1 - t) + int(hi_c[5:7], 16) * t)
            return f"#{r:02x}{g:02x}{b:02x}"
    return HEXBIN_RAMP[-1][1]


# ---------------------------------------------------------------------------
# Data loading: try Vertica first, then CSV fallback, then hardcoded demo
# ---------------------------------------------------------------------------

def load_from_vertica():
    """
    Attempt to connect to Vertica and pull the three datasets.
    Returns (hexbin_df, risk_df, hospitals_df, schools_df) or raises.
    """
    try:
        import vertica_python
    except ImportError:
        raise RuntimeError(
            "vertica_python is not installed. "
            "Run: pip install vertica-python"
        )

    print(f"  Connecting to Vertica at "
          f"{VERTICA_CONFIG['host']}:{VERTICA_CONFIG['port']} ...")

    conn = vertica_python.connect(**VERTICA_CONFIG)
    cur = conn.cursor()
    cur.execute(f"SET SEARCH_PATH TO {VERTICA_SCHEMA}, public, v_catalog, v_monitor")

    # -- hexbin report -------------------------------------------------------
    print("  Querying dengue_hexbin_report ...")
    cur.execute("""
        SELECT
            ST_AsText(hex_geom)       AS wkt,
            case_count,
            dhf_count + dss_count     AS severe_count,
            avg_age
        FROM dengue_hexbin_report
        ORDER BY case_count DESC
    """)
    hexbin_rows = cur.fetchall()
    hexbin_df = pd.DataFrame(
        hexbin_rows, columns=["wkt", "case_count", "severe_count", "avg_age"]
    )
    print(f"    -> {len(hexbin_df)} hexbins loaded")

    # -- risk buffer zones ---------------------------------------------------
    print("  Querying dengue_risk_zones ...")
    cur.execute("""
        SELECT
            province_name,
            risk_tier,
            radius_meters,
            case_count,
            area_sq_km,
            ST_AsText(zone_geom) AS wkt
        FROM dengue_risk_zones
        ORDER BY radius_meters
    """)
    risk_rows = cur.fetchall()
    risk_df = pd.DataFrame(
        risk_rows,
        columns=["province_name", "risk_tier", "radius_meters",
                  "case_count", "area_sq_km", "wkt"],
    )
    print(f"    -> {len(risk_df)} risk zones loaded")

    # -- hospitals -----------------------------------------------------------
    print("  Querying hospitals ...")
    cur.execute("""
        SELECT
            name,
            province,
            ST_X(geom)  AS lon,
            ST_Y(geom)  AS lat
        FROM hospitals
    """)
    hosp_rows = cur.fetchall()
    hospitals_df = pd.DataFrame(
        hosp_rows, columns=["name", "province", "lon", "lat"]
    )
    print(f"    -> {len(hospitals_df)} hospitals loaded")

    # -- schools -------------------------------------------------------------
    print("  Querying schools ...")
    cur.execute("""
        SELECT
            name,
            district,
            ST_X(geom)  AS lon,
            ST_Y(geom)  AS lat
        FROM schools
    """)
    school_rows = cur.fetchall()
    schools_df = pd.DataFrame(
        school_rows, columns=["name", "district", "lon", "lat"]
    )
    print(f"    -> {len(schools_df)} schools loaded")

    cur.close()
    conn.close()
    return hexbin_df, risk_df, hospitals_df, schools_df


def load_from_csv():
    """
    Fallback: look for CSV exports in the working directory.
    Expected files: hexbin_report.csv, risk_zones.csv,
                    hospitals.csv, schools.csv
    """
    cwd = Path(".")
    required = ["hexbin_report.csv", "risk_zones.csv",
                "hospitals.csv", "schools.csv"]
    for fname in required:
        if not (cwd / fname).exists():
            raise FileNotFoundError(f"CSV fallback file not found: {fname}")

    hexbin_df   = pd.read_csv("hexbin_report.csv")
    risk_df     = pd.read_csv("risk_zones.csv")
    hospitals_df = pd.read_csv("hospitals.csv")
    schools_df  = pd.read_csv("schools.csv")
    return hexbin_df, risk_df, hospitals_df, schools_df


def load_demo_data():
    """
    Last-resort fallback: hardcoded sample data so the script always
    produces a map, even without Vertica or CSV files.
    Uses real coordinates from the DDC training SQL setup.
    """
    print("  Using built-in demo data (no Vertica / no CSV).")

    # Sample hexbin polygons (GeoHash-style rectangles around clusters)
    hexbin_df = pd.DataFrame({
        "wkt": [
            "POLYGON((100.550 13.720, 100.556 13.720, 100.556 13.726, "
            "100.550 13.726, 100.550 13.720))",
            "POLYGON((100.556 13.720, 100.562 13.720, 100.562 13.726, "
            "100.556 13.726, 100.556 13.720))",
            "POLYGON((100.554 13.760, 100.560 13.760, 100.560 13.766, "
            "100.554 13.766, 100.554 13.760))",
            "POLYGON((98.978 18.785, 98.984 18.785, 98.984 18.791, "
            "98.978 18.791, 98.978 18.785))",
            "POLYGON((99.876 20.426, 99.882 20.426, 99.882 20.432, "
            "99.876 20.432, 99.876 20.426))",
        ],
        "case_count": [12, 8, 8, 6, 4],
        "severe_count": [3, 2, 3, 1, 1],
        "avg_age": [18.5, 22.0, 20.1, 23.0, 26.0],
    })

    # Risk buffer zones (simplified demo polygons around cluster centres)
    risk_records = []
    demo_provinces = [
        ("Bangkok",    20, 100.5550, 13.7400),
        ("Chiang Mai",  6,  98.9820, 18.7870),
        ("Chiang Rai",  4,  99.8790, 20.4300),
    ]
    for prov, count, clon, clat in demo_provinces:
        for tier, radius in [("RED", 500), ("ORANGE", 1000), ("YELLOW", 2000)]:
            # Approximate circle as bounding box for demo
            d = radius / 111000.0
            wkt = (f"POLYGON(({clon-d} {clat-d}, {clon+d} {clat-d}, "
                   f"{clon+d} {clat+d}, {clon-d} {clat+d}, {clon-d} {clat-d}))")
            risk_records.append({
                "province_name": prov,
                "risk_tier": tier,
                "radius_meters": radius,
                "case_count": count,
                "area_sq_km": round(3.14159 * (radius/1000)**2, 3),
                "wkt": wkt,
            })
    risk_df = pd.DataFrame(risk_records)

    # Hospitals -- matching the SQL setup data
    hospitals_df = pd.DataFrame({
        "name": [
            "Siriraj Hospital", "Ramathibodi Hospital",
            "King Chulalongkorn Memorial",
            "Bamrasnaradura Infectious Diseases",
            "Queen Sirikit National Institute",
            "Nopparat Rajathanee Hospital",
            "Charoen Krung Pracharak Hospital",
            "Taksin Hospital",
            "Maharaj Nakorn Chiang Mai",
            "Chiang Mai Ram Hospital",
            "Nakornping Hospital",
            "San Sai Hospital",
            "Chiang Rai Prachanukroh Hospital",
            "Overbrook Hospital",
            "Mae Sai Hospital",
        ],
        "province": [
            "Bangkok", "Bangkok", "Bangkok", "Bangkok", "Bangkok",
            "Bangkok", "Bangkok", "Bangkok",
            "Chiang Mai", "Chiang Mai", "Chiang Mai", "Chiang Mai",
            "Chiang Rai", "Chiang Rai", "Chiang Rai",
        ],
        "lon": [
            100.4856, 100.5385, 100.5347, 100.5230, 100.5340,
            100.6780, 100.5080, 100.4870,
            98.9720, 98.9870, 98.9580, 99.0320,
            99.8310, 99.8280, 99.8760,
        ],
        "lat": [
            13.7590, 13.7649, 13.7312, 13.8480, 13.7680,
            13.7870, 13.6930, 13.7190,
            18.7880, 18.7920, 18.8900, 18.8370,
            19.9100, 19.9050, 20.4280,
        ],
    })

    # Schools
    schools_df = pd.DataFrame({
        "name": [
            "Wat Khlong Toei School",
            "Khlong Toei Wittaya School",
            "Sukhumvit Pattana School",
            "Din Daeng Wittaya School",
            "Ratchadaphisek Wittayalai School",
            "Huai Khwang School",
            "Satri Witthaya School",
            "Benchama Rajalai School",
            "Suankularb Wittayalai School",
            "Triam Udom Suksa School",
        ],
        "district": [
            "Khlong Toei", "Khlong Toei", "Watthana",
            "Din Daeng", "Din Daeng", "Huai Khwang",
            "Dusit", "Phra Nakhon", "Phra Nakhon", "Pathum Wan",
        ],
        "lon": [
            100.5545, 100.5510, 100.5620,
            100.5590, 100.5640, 100.5730,
            100.5130, 100.5010, 100.4960, 100.5310,
        ],
        "lat": [
            13.7225, 13.7195, 13.7270,
            13.7670, 13.7600, 13.7650,
            13.7720, 13.7530, 13.7440, 13.7370,
        ],
    })

    return hexbin_df, risk_df, hospitals_df, schools_df


def load_data():
    """
    Try each data source in order: Vertica -> CSV -> hardcoded demo.
    Always returns four DataFrames.
    """
    # Attempt 1: Vertica
    try:
        return load_from_vertica()
    except Exception as exc:
        print(f"  Vertica unavailable: {exc}")

    # Attempt 2: CSV files in current directory
    try:
        print("  Trying CSV fallback ...")
        return load_from_csv()
    except FileNotFoundError as exc:
        print(f"  CSV fallback unavailable: {exc}")

    # Attempt 3: built-in demo
    return load_demo_data()


# ---------------------------------------------------------------------------
# Map construction
# ---------------------------------------------------------------------------

def add_hexbin_layer(m: folium.Map, hexbin_df: pd.DataFrame):
    """
    Render hexbin polygons as coloured GeoJSON features.
    Colour intensity is proportional to case_count.
    """
    if not HAS_SHAPELY:
        print("  [SKIP] Hexbin layer requires shapely. Install it to enable.")
        return

    if hexbin_df.empty:
        return

    fg = FeatureGroup(name="Hexbin Heatmap", show=True)
    max_count = hexbin_df["case_count"].max()

    for _, row in hexbin_df.iterrows():
        try:
            geom = shapely_wkt.loads(row["wkt"])
        except Exception:
            continue

        intensity = row["case_count"] / max_count if max_count > 0 else 0
        fill_colour = intensity_to_colour(intensity)

        geojson = shapely_mapping(geom)
        severe = int(row.get("severe_count", 0))
        feature = {
            "type": "Feature",
            "geometry": geojson,
            "properties": {
                "case_count": int(row["case_count"]),
                "severe_count": severe,
            },
        }

        tooltip = (
            f"Cases: {int(row['case_count'])}<br>"
            f"Severe (DHF/DSS): {severe}"
        )

        GeoJson(
            feature,
            style_function=lambda feat, fc=fill_colour: {
                "fillColor": fc,
                "color": "#333333",
                "weight": 1,
                "fillOpacity": 0.65,
            },
            tooltip=tooltip,
        ).add_to(fg)

    fg.add_to(m)
    print(f"  Added {len(hexbin_df)} hexbin polygons")


def add_risk_buffer_layer(m: folium.Map, risk_df: pd.DataFrame):
    """
    Draw risk buffer zones as actual merged polygons from Vertica.
    Zones are styled by tier: RED (500 m), ORANGE (1 km), YELLOW (2 km).
    """
    if risk_df.empty:
        return

    if not HAS_SHAPELY:
        print("  [SKIP] Risk buffer layer requires shapely. Install it to enable.")
        return

    fg = FeatureGroup(name="Risk Buffers (500m / 1km / 2km)", show=True)

    # Draw largest radius first so smaller zones render on top
    for _, row in risk_df.sort_values("radius_meters", ascending=False).iterrows():
        radius = int(row["radius_meters"])
        colour, opacity = RISK_BUFFER_STYLES.get(radius, ("#999999", 0.2))

        try:
            geom = shapely_wkt.loads(row["wkt"])
        except Exception:
            continue

        geojson = shapely_mapping(geom)
        feature = {
            "type": "Feature",
            "geometry": geojson,
            "properties": {
                "province": row["province_name"],
                "risk_tier": row["risk_tier"],
                "case_count": int(row["case_count"]),
            },
        }

        tooltip = (
            f"{row['province_name']} -- {row['risk_tier']}<br>"
            f"Buffer: {radius:,} m<br>"
            f"Cases: {int(row['case_count'])}<br>"
            f"Area: {row['area_sq_km']} km&sup2;"
        )

        GeoJson(
            feature,
            style_function=lambda feat, c=colour, o=opacity: {
                "fillColor": c,
                "color": c,
                "weight": 2,
                "fillOpacity": o,
            },
            tooltip=tooltip,
        ).add_to(fg)

    fg.add_to(m)
    print(f"  Added {len(risk_df)} risk buffer zones")


def add_hospital_layer(m: folium.Map, hospitals_df: pd.DataFrame):
    """Blue hospital markers with name popups."""
    if hospitals_df.empty:
        return

    fg = FeatureGroup(name="Hospitals", show=True)

    for _, row in hospitals_df.iterrows():
        popup_html = (
            f"<b>{row['name']}</b><br>"
            f"Province: {row['province']}"
        )
        Marker(
            location=[float(row["lat"]), float(row["lon"])],
            popup=folium.Popup(popup_html, max_width=250),
            tooltip=row["name"],
            icon=Icon(color="blue", icon="plus-sign", prefix="glyphicon"),
        ).add_to(fg)

    fg.add_to(m)
    print(f"  Added {len(hospitals_df)} hospital markers")


def add_school_layer(m: folium.Map, schools_df: pd.DataFrame):
    """Green school markers with name popups."""
    if schools_df.empty:
        return

    fg = FeatureGroup(name="Schools", show=False)  # off by default

    for _, row in schools_df.iterrows():
        popup_html = (
            f"<b>{row['name']}</b><br>"
            f"District: {row['district']}"
        )
        Marker(
            location=[float(row["lat"]), float(row["lon"])],
            popup=folium.Popup(popup_html, max_width=250),
            tooltip=row["name"],
            icon=Icon(color="green", icon="education", prefix="glyphicon"),
        ).add_to(fg)

    fg.add_to(m)
    print(f"  Added {len(schools_df)} school markers")


def build_map(hexbin_df, risk_df, hospitals_df, schools_df) -> folium.Map:
    """
    Assemble the final Folium map with all layers and controls.
    """
    m = folium.Map(
        location=[13.0, 101.0],
        zoom_start=6,
        tiles="CartoDB positron",
        control_scale=True,
    )

    # Additional tile layers for attendees to switch between
    folium.TileLayer("OpenStreetMap", name="OpenStreetMap").add_to(m)
    folium.TileLayer(
        "CartoDB dark_matter", name="Dark Mode"
    ).add_to(m)

    # Custom title
    title_html = """
    <div style="
        position: fixed; top: 10px; left: 60px; z-index: 9999;
        background: rgba(255,255,255,0.92); padding: 10px 20px;
        border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        font-family: 'Segoe UI', sans-serif;
    ">
        <h3 style="margin:0; color:#333;">
            DDC Dengue Outbreak Map
        </h3>
        <p style="margin:2px 0 0 0; font-size:12px; color:#666;">
            Vertica Spatial Analytics &bull; Department of Disease Control
        </p>
    </div>
    """
    m.get_root().html.add_child(folium.Element(title_html))

    # Legend
    legend_html = """
    <div style="
        position: fixed; bottom: 30px; right: 20px; z-index: 9999;
        background: rgba(255,255,255,0.92); padding: 12px 16px;
        border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        font-family: 'Segoe UI', sans-serif; font-size: 12px;
    ">
        <b style="font-size:13px;">Legend</b><br>
        <span style="color:#e74c3c;">&#9679;</span> High risk (500 m buffer)<br>
        <span style="color:#e67e22;">&#9679;</span> Medium risk (1 km buffer)<br>
        <span style="color:#f1c40f;">&#9679;</span> Watch zone (2 km buffer)<br>
        <span style="color:#bd0026;">&#9632;</span> Hexbin: high case count<br>
        <span style="color:#ffffb2;">&#9632;</span> Hexbin: low case count<br>
        <span style="color:#2980b9;">&#9899;</span> Hospital<br>
        <span style="color:#27ae60;">&#9899;</span> School<br>
    </div>
    """
    m.get_root().html.add_child(folium.Element(legend_html))

    # -- add data layers -----------------------------------------------------
    print("Building map layers ...")
    add_hexbin_layer(m, hexbin_df)
    add_risk_buffer_layer(m, risk_df)
    add_hospital_layer(m, hospitals_df)
    add_school_layer(m, schools_df)

    # Layer control toggle (top-right)
    folium.LayerControl(collapsed=False).add_to(m)

    # Measure tool so attendees can measure distances interactively
    MeasureControl(position="topleft", primary_length_unit="meters").add_to(m)

    return m


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("  DDC Dengue Outbreak Visualisation")
    print("=" * 60)

    hexbin_df, risk_df, hospitals_df, schools_df = load_data()

    m = build_map(hexbin_df, risk_df, hospitals_df, schools_df)

    output_path = Path(OUTPUT_FILE)
    m.save(str(output_path))

    print("=" * 60)
    print(f"  Map saved to: {output_path.resolve()}")
    print(f"  Open in your browser to explore the outbreak data.")
    print("=" * 60)


if __name__ == "__main__":
    main()
