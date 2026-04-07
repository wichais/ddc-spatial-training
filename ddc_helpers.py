"""
DDC Training Helpers -- run SQL and visualize results in Jupyter.

Usage (students only need to know this):
    from ddc_helpers import run_query, show_on_map, show_buffers, show_heatmap, explain_query

    run_query("SELECT * FROM hospitals")
    show_on_map("SELECT name, ST_AsText(geom) AS wkt FROM hospitals")
"""

import os
import warnings

import pandas as pd
import vertica_python
import folium
from folium import FeatureGroup, GeoJson, Marker, Icon
from folium.plugins import MeasureControl
from shapely import wkt as shapely_wkt
from shapely.geometry import mapping as shapely_mapping
from IPython.display import display, HTML

warnings.filterwarnings("ignore", message=".*TLS is not configured.*")
warnings.filterwarnings("ignore", message=".*NOTICE.*")
warnings.filterwarnings("ignore", message=".*INFO.*")

# ---------------------------------------------------------------------------
# Connection management
# ---------------------------------------------------------------------------

_conn = None


def _get_connection():
    """Create a new Vertica connection from environment variables."""
    return vertica_python.connect(
        host=os.environ.get("VERTICA_HOST", "ddc-vertica"),
        port=int(os.environ.get("VERTICA_PORT", 5433)),
        user=os.environ.get("VERTICA_USER", "dbadmin"),
        password=os.environ.get("VERTICA_PASSWORD", ""),
        database=os.environ.get("VERTICA_DATABASE", "VMart"),
        autocommit=True,
    )


def _ensure_connection():
    """Return a live connection, reconnecting if needed."""
    global _conn
    if _conn is not None:
        try:
            cur = _conn.cursor()
            cur.execute("SELECT 1")
            cur.fetchone()
            return _conn
        except Exception:
            try:
                _conn.close()
            except Exception:
                pass
            _conn = None
    _conn = _get_connection()
    _conn.cursor().execute(
        "SET SEARCH_PATH TO ddc_training, public, v_catalog, v_monitor"
    )
    return _conn


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run_query(sql, limit=1000):
    """
    Execute a SQL query and display results as a formatted table.

    Parameters
    ----------
    sql : str
        Any SQL SELECT statement.
    limit : int
        Maximum rows to display (default 1000).

    Returns
    -------
    pandas.DataFrame
    """
    try:
        conn = _ensure_connection()
        cur = conn.cursor()
        cur.execute(sql)

        if cur.description is None:
            display(HTML("<i>Query executed successfully (no results).</i>"))
            return pd.DataFrame()

        cols = [d.name for d in cur.description]
        rows = cur.fetchall()
        df = pd.DataFrame(rows, columns=cols)

        if len(df) > limit:
            display(HTML(
                f"<i>Showing first {limit:,} of {len(df):,} rows.</i>"
            ))
            display(df.head(limit))
        else:
            display(df)

        return df

    except Exception as e:
        msg = str(e).split("\n")[0]
        display(HTML(
            f'<div style="color:#c0392b;padding:8px;background:#fdf2f2;'
            f'border-radius:4px;">'
            f"<b>Query error:</b> {msg}</div>"
        ))
        return pd.DataFrame()


def explain_query(sql):
    """
    Show the EXPLAIN plan for a SQL query.

    Parameters
    ----------
    sql : str
        A SQL SELECT statement (EXPLAIN is prepended automatically).
    """
    try:
        conn = _ensure_connection()
        cur = conn.cursor()
        cur.execute(f"EXPLAIN {sql}")
        rows = cur.fetchall()
        plan_text = "\n".join(str(row[0]) for row in rows)
        display(HTML(
            f'<pre style="background:#f8f9fa;padding:12px;border-radius:4px;'
            f'font-size:12px;overflow-x:auto;max-height:500px;">'
            f"{plan_text}</pre>"
        ))
    except Exception as e:
        msg = str(e).split("\n")[0]
        display(HTML(
            f'<div style="color:#c0392b;padding:8px;background:#fdf2f2;'
            f'border-radius:4px;">'
            f"<b>EXPLAIN error:</b> {msg}</div>"
        ))


# ---------------------------------------------------------------------------
# Map visualization
# ---------------------------------------------------------------------------

# Color ramps (from visualize_outbreak.py)
_RISK_BUFFER_STYLES = {
    500:  ("#e74c3c", 0.45),   # RED
    1000: ("#e67e22", 0.30),   # ORANGE
    2000: ("#f1c40f", 0.18),   # YELLOW
}

_RISK_TIER_COLORS = {
    "RED":    ("#e74c3c", 0.45),
    "ORANGE": ("#e67e22", 0.30),
    "YELLOW": ("#f1c40f", 0.18),
}

_HEXBIN_RAMP = [
    (0.0,  "#ffffb2"),
    (0.25, "#fecc5c"),
    (0.50, "#fd8d3c"),
    (0.75, "#f03b20"),
    (1.0,  "#bd0026"),
]


def _intensity_color(value):
    """Linearly interpolate a hex color from the heatmap ramp."""
    for i in range(len(_HEXBIN_RAMP) - 1):
        lo_v, lo_c = _HEXBIN_RAMP[i]
        hi_v, hi_c = _HEXBIN_RAMP[i + 1]
        if value <= hi_v:
            t = (value - lo_v) / (hi_v - lo_v) if hi_v != lo_v else 0.0
            r = int(int(lo_c[1:3], 16) * (1 - t) + int(hi_c[1:3], 16) * t)
            g = int(int(lo_c[3:5], 16) * (1 - t) + int(hi_c[3:5], 16) * t)
            b = int(int(lo_c[5:7], 16) * (1 - t) + int(hi_c[5:7], 16) * t)
            return f"#{r:02x}{g:02x}{b:02x}"
    return _HEXBIN_RAMP[-1][1]


def _base_map(center=None, zoom=None):
    """Create a base Folium map centered on Thailand."""
    m = folium.Map(
        location=center or [14.0, 100.5],
        zoom_start=zoom or 6,
        tiles="CartoDB positron",
        control_scale=True,
    )
    folium.TileLayer("OpenStreetMap", name="OpenStreetMap").add_to(m)
    MeasureControl(position="topleft", primary_length_unit="meters").add_to(m)
    return m


def _auto_bounds(m, coords):
    """Fit map to show all coordinates."""
    if coords:
        lats = [c[0] for c in coords]
        lons = [c[1] for c in coords]
        m.fit_bounds([[min(lats), min(lons)], [max(lats), max(lons)]])


def show_on_map(sql, geom_col="wkt", lat_col=None, lon_col=None,
                color="blue", popup_cols=None, title=None):
    """
    Execute a SQL query and display results on an interactive map.

    The query should return either:
    - A WKT geometry column (use ST_AsText()) for polygons/points, OR
    - Separate lat/lon columns for point markers.

    Parameters
    ----------
    sql : str
        SQL query returning spatial data.
    geom_col : str
        Column name containing WKT geometry (default 'wkt').
    lat_col, lon_col : str or None
        Column names for latitude/longitude (if using point markers).
    color : str
        Marker color for point data (default 'blue').
    popup_cols : list of str or None
        Columns to show in popup. If None, shows all non-geometry columns.
    title : str or None
        Optional map title.
    """
    try:
        conn = _ensure_connection()
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d.name for d in cur.description]
        rows = cur.fetchall()
        df = pd.DataFrame(rows, columns=cols)
    except Exception as e:
        msg = str(e).split("\n")[0]
        display(HTML(
            f'<div style="color:#c0392b;padding:8px;background:#fdf2f2;'
            f'border-radius:4px;">'
            f"<b>Query error:</b> {msg}</div>"
        ))
        return None

    if df.empty:
        display(HTML("<i>No data returned.</i>"))
        return None

    m = _base_map()
    bounds = []

    # Point markers via lat/lon columns
    if lat_col and lon_col and lat_col in df.columns and lon_col in df.columns:
        fg = FeatureGroup(name="Points", show=True)
        info_cols = popup_cols or [c for c in df.columns if c not in (lat_col, lon_col)]
        for _, row in df.iterrows():
            lat, lon = float(row[lat_col]), float(row[lon_col])
            bounds.append([lat, lon])
            popup_html = "<br>".join(
                f"<b>{c}:</b> {row[c]}" for c in info_cols if c in row.index
            )
            Marker(
                location=[lat, lon],
                popup=folium.Popup(popup_html, max_width=300),
                tooltip=str(row[info_cols[0]]) if info_cols else "",
                icon=Icon(color=color, icon="info-sign", prefix="glyphicon"),
            ).add_to(fg)
        fg.add_to(m)

    # WKT geometry column
    elif geom_col in df.columns:
        fg = FeatureGroup(name="Geometry", show=True)
        info_cols = popup_cols or [c for c in df.columns if c != geom_col]
        for _, row in df.iterrows():
            try:
                geom = shapely_wkt.loads(str(row[geom_col]))
            except Exception:
                continue

            centroid = geom.centroid
            bounds.append([centroid.y, centroid.x])

            tooltip_parts = [
                f"{c}: {row[c]}" for c in info_cols if c in row.index
            ]
            tooltip = "<br>".join(tooltip_parts[:5])

            if geom.geom_type == "Point":
                Marker(
                    location=[centroid.y, centroid.x],
                    tooltip=tooltip,
                    icon=Icon(color=color, icon="info-sign", prefix="glyphicon"),
                ).add_to(fg)
            else:
                geojson = shapely_mapping(geom)
                GeoJson(
                    {"type": "Feature", "geometry": geojson, "properties": {}},
                    style_function=lambda feat: {
                        "fillColor": "#3498db",
                        "color": "#2c3e50",
                        "weight": 2,
                        "fillOpacity": 0.4,
                    },
                    tooltip=tooltip,
                ).add_to(fg)
        fg.add_to(m)
    else:
        display(HTML(
            f"<i>No geometry column '{geom_col}' found. "
            f"Use ST_AsText() in your SQL to create a 'wkt' column.</i>"
        ))
        return None

    if title:
        m.get_root().html.add_child(folium.Element(
            f'<div style="position:fixed;top:10px;left:60px;z-index:9999;'
            f'background:rgba(255,255,255,0.9);padding:8px 16px;'
            f'border-radius:6px;box-shadow:0 2px 6px rgba(0,0,0,0.2);'
            f'font-family:sans-serif;">'
            f'<b>{title}</b></div>'
        ))

    _auto_bounds(m, bounds)
    folium.LayerControl(collapsed=True).add_to(m)
    return m


def show_buffers(sql, geom_col="wkt", tier_col="risk_tier",
                 radius_col="radius_meters"):
    """
    Execute a SQL query and display risk buffer zones on a map.

    The query should return columns for WKT geometry, risk tier
    (RED/ORANGE/YELLOW), and buffer radius.

    Parameters
    ----------
    sql : str
        SQL query returning buffer zone data.
    geom_col : str
        Column with WKT polygon (default 'wkt').
    tier_col : str
        Column with risk tier label (default 'risk_tier').
    radius_col : str
        Column with buffer radius in meters (default 'radius_meters').
    """
    try:
        conn = _ensure_connection()
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d.name for d in cur.description]
        rows = cur.fetchall()
        df = pd.DataFrame(rows, columns=cols)
    except Exception as e:
        msg = str(e).split("\n")[0]
        display(HTML(
            f'<div style="color:#c0392b;padding:8px;background:#fdf2f2;'
            f'border-radius:4px;">'
            f"<b>Query error:</b> {msg}</div>"
        ))
        return None

    if df.empty:
        display(HTML("<i>No buffer data returned.</i>"))
        return None

    m = _base_map()
    fg = FeatureGroup(name="Risk Buffers", show=True)
    bounds = []

    # Draw largest buffers first so smaller ones render on top
    sort_col = radius_col if radius_col in df.columns else None
    if sort_col:
        df = df.sort_values(sort_col, ascending=False)

    info_cols = [c for c in df.columns if c not in (geom_col,)]

    for _, row in df.iterrows():
        try:
            geom = shapely_wkt.loads(str(row[geom_col]))
        except Exception:
            continue

        centroid = geom.centroid
        bounds.append([centroid.y, centroid.x])

        # Determine color from tier or radius
        tier = str(row.get(tier_col, "")).upper() if tier_col in df.columns else ""
        radius = int(row.get(radius_col, 0)) if radius_col in df.columns else 0

        colour, opacity = _RISK_TIER_COLORS.get(
            tier, _RISK_BUFFER_STYLES.get(radius, ("#999999", 0.3))
        )

        tooltip_parts = [f"{c}: {row[c]}" for c in info_cols if c in row.index]
        tooltip = "<br>".join(tooltip_parts[:6])

        geojson = shapely_mapping(geom)
        GeoJson(
            {"type": "Feature", "geometry": geojson, "properties": {}},
            style_function=lambda feat, c=colour, o=opacity: {
                "fillColor": c,
                "color": c,
                "weight": 2,
                "fillOpacity": o,
            },
            tooltip=tooltip,
        ).add_to(fg)

    fg.add_to(m)

    # Legend
    legend_html = """
    <div style="position:fixed;bottom:30px;right:20px;z-index:9999;
        background:rgba(255,255,255,0.92);padding:10px 14px;border-radius:6px;
        box-shadow:0 2px 6px rgba(0,0,0,0.2);font-family:sans-serif;font-size:12px;">
        <b>Risk Tiers</b><br>
        <span style="color:#e74c3c;">&#9632;</span> RED: 0-500m (immediate fogging)<br>
        <span style="color:#e67e22;">&#9632;</span> ORANGE: 500m-1km (48hr fogging)<br>
        <span style="color:#f1c40f;">&#9632;</span> YELLOW: 1-2km (surveillance)
    </div>
    """
    m.get_root().html.add_child(folium.Element(legend_html))

    _auto_bounds(m, bounds)
    folium.LayerControl(collapsed=True).add_to(m)
    return m


def show_heatmap(sql, geom_col="wkt", value_col="case_count", title=None):
    """
    Execute a SQL query and display a heatmap with colored polygons.

    The query should return WKT polygon geometries and a numeric value
    column for color intensity.

    Parameters
    ----------
    sql : str
        SQL query returning hexbin/grid polygon data.
    geom_col : str
        Column with WKT polygon (default 'wkt').
    value_col : str
        Column with numeric value for color intensity (default 'case_count').
    title : str or None
        Optional map title.
    """
    try:
        conn = _ensure_connection()
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d.name for d in cur.description]
        rows = cur.fetchall()
        df = pd.DataFrame(rows, columns=cols)
    except Exception as e:
        msg = str(e).split("\n")[0]
        display(HTML(
            f'<div style="color:#c0392b;padding:8px;background:#fdf2f2;'
            f'border-radius:4px;">'
            f"<b>Query error:</b> {msg}</div>"
        ))
        return None

    if df.empty:
        display(HTML("<i>No heatmap data returned.</i>"))
        return None

    m = _base_map()
    fg = FeatureGroup(name="Heatmap", show=True)
    bounds = []

    max_val = df[value_col].max() if value_col in df.columns else 1
    info_cols = [c for c in df.columns if c not in (geom_col,)]

    for _, row in df.iterrows():
        try:
            geom = shapely_wkt.loads(str(row[geom_col]))
        except Exception:
            continue

        centroid = geom.centroid
        bounds.append([centroid.y, centroid.x])

        val = float(row.get(value_col, 0))
        intensity = val / max_val if max_val > 0 else 0
        fill_color = _intensity_color(intensity)

        tooltip_parts = [f"{c}: {row[c]}" for c in info_cols if c in row.index]
        tooltip = "<br>".join(tooltip_parts[:5])

        geojson = shapely_mapping(geom)
        GeoJson(
            {"type": "Feature", "geometry": geojson, "properties": {}},
            style_function=lambda feat, fc=fill_color: {
                "fillColor": fc,
                "color": "#333333",
                "weight": 1,
                "fillOpacity": 0.65,
            },
            tooltip=tooltip,
        ).add_to(fg)

    fg.add_to(m)

    # Legend
    legend_html = f"""
    <div style="position:fixed;bottom:30px;right:20px;z-index:9999;
        background:rgba(255,255,255,0.92);padding:10px 14px;border-radius:6px;
        box-shadow:0 2px 6px rgba(0,0,0,0.2);font-family:sans-serif;font-size:12px;">
        <b>Case Count</b><br>
        <span style="color:#bd0026;">&#9632;</span> High ({int(max_val)})<br>
        <span style="color:#fd8d3c;">&#9632;</span> Medium<br>
        <span style="color:#ffffb2;">&#9632;</span> Low (1)
    </div>
    """
    m.get_root().html.add_child(folium.Element(legend_html))

    if title:
        m.get_root().html.add_child(folium.Element(
            f'<div style="position:fixed;top:10px;left:60px;z-index:9999;'
            f'background:rgba(255,255,255,0.9);padding:8px 16px;'
            f'border-radius:6px;box-shadow:0 2px 6px rgba(0,0,0,0.2);'
            f'font-family:sans-serif;">'
            f'<b>{title}</b></div>'
        ))

    _auto_bounds(m, bounds)
    folium.LayerControl(collapsed=True).add_to(m)
    return m
