#!/usr/bin/env python3
"""
Execute Vertica SQL files via vertica-python.

Handles vsql meta-commands (\echo, etc.) and COPY LOCAL statements
so that SQL scripts designed for vsql work without modification.
"""
import os
import re
import sys
import time

import vertica_python


def get_connection():
    """Create a Vertica connection from environment variables."""
    return vertica_python.connect(
        host=os.environ.get('VERTICA_HOST', 'ddc-vertica'),
        port=int(os.environ.get('VERTICA_PORT', 5433)),
        user=os.environ.get('VERTICA_USER', 'dbadmin'),
        password=os.environ.get('VERTICA_PASSWORD', ''),
        database=os.environ.get('VERTICA_DATABASE', 'VMart'),
        autocommit=False,
    )


def wait_for_vertica(max_retries=40, delay=5):
    """Block until Vertica accepts connections."""
    for i in range(max_retries):
        try:
            conn = get_connection()
            cur = conn.cursor()
            cur.execute("SELECT 1")
            conn.close()
            print("  Vertica is ready!")
            return
        except Exception:
            print(f"  Waiting for Vertica... ({i + 1}/{max_retries})")
            time.sleep(delay)
    raise RuntimeError("Vertica did not become ready in time")


def split_statements(sql_text):
    """Split SQL text by semicolons, respecting single-quoted strings."""
    statements = []
    current = []
    in_string = False
    i = 0
    while i < len(sql_text):
        ch = sql_text[i]
        if in_string:
            current.append(ch)
            if ch == "'" and (i + 1 >= len(sql_text) or sql_text[i + 1] != "'"):
                in_string = False
            elif ch == "'" and i + 1 < len(sql_text) and sql_text[i + 1] == "'":
                # Escaped quote ''
                current.append(sql_text[i + 1])
                i += 1
        elif ch == "'":
            in_string = True
            current.append(ch)
        elif ch == ';':
            stmt = ''.join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
        elif ch == '-' and i + 1 < len(sql_text) and sql_text[i + 1] == '-':
            # Single-line comment: skip to end of line
            while i < len(sql_text) and sql_text[i] != '\n':
                i += 1
            current.append('\n')
        else:
            current.append(ch)
        i += 1
    # Trailing statement without semicolon
    stmt = ''.join(current).strip()
    if stmt:
        statements.append(stmt)
    return statements


def execute_sql_file(conn, filepath, csv_dir=None):
    """Execute a SQL file, handling \\echo and COPY LOCAL."""
    print(f"\n{'=' * 60}")
    print(f"  Running: {filepath}")
    print(f"{'=' * 60}")

    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # Process line by line: handle \echo and other meta-commands
    clean_lines = []
    for line in content.split('\n'):
        stripped = line.strip()
        if stripped.startswith('\\echo'):
            msg = stripped[5:].strip().strip("'\"")
            print(f"  {msg}")
        elif stripped.startswith('\\'):
            # Skip other vsql meta-commands (\set, \pset, etc.)
            continue
        else:
            clean_lines.append(line)

    sql_text = '\n'.join(clean_lines)
    statements = split_statements(sql_text)

    cur = conn.cursor()
    for stmt in statements:
        stmt_upper = stmt.upper().strip()
        if not stmt_upper:
            continue

        # Handle COPY ... FROM LOCAL ... → COPY FROM STDIN via vertica_python
        if 'FROM LOCAL' in stmt_upper and stmt_upper.startswith('COPY'):
            _handle_copy_local(conn, cur, stmt, csv_dir)
            continue

        try:
            cur.execute(stmt)
            # Print SELECT results for verification queries
            if stmt_upper.startswith('SELECT') and not stmt_upper.startswith('SELECT REFRESH') \
               and not stmt_upper.startswith('SELECT ANALYZE'):
                try:
                    rows = cur.fetchall()
                    if rows and len(rows) <= 50:
                        cols = [d.name for d in cur.description] if cur.description else []
                        if cols:
                            print(f"  {' | '.join(cols)}")
                            print(f"  {'-' * (sum(len(c) for c in cols) + 3 * (len(cols) - 1))}")
                        for row in rows:
                            print(f"  {' | '.join(str(v) for v in row)}")
                    elif rows:
                        print(f"  ({len(rows)} rows returned)")
                except Exception:
                    pass
        except Exception as e:
            err_msg = str(e)
            # Non-critical: already exists, etc.
            if 'already exists' in err_msg.lower():
                continue
            print(f"  [WARN] {err_msg[:200]}")

    # Commit after each file
    conn.commit()
    print(f"  Completed: {os.path.basename(filepath)}")


def _handle_copy_local(conn, cur, stmt, csv_dir):
    """Convert COPY FROM LOCAL to COPY FROM STDIN and stream the file."""
    # Extract filename from: COPY table FROM LOCAL 'filename' ...
    match = re.search(r"FROM\s+LOCAL\s+'([^']+)'", stmt, re.IGNORECASE)
    if not match:
        print(f"  [WARN] Could not parse COPY LOCAL: {stmt[:100]}")
        return

    filename = match.group(1)
    csv_path = os.path.join(csv_dir, filename) if csv_dir else filename

    if not os.path.exists(csv_path):
        print(f"  [ERROR] CSV not found: {csv_path}")
        return

    # Rewrite: FROM LOCAL 'file' → FROM STDIN
    new_stmt = re.sub(
        r"FROM\s+LOCAL\s+'[^']+'",
        "FROM STDIN",
        stmt,
        flags=re.IGNORECASE,
    )

    file_size_mb = os.path.getsize(csv_path) / (1024 * 1024)
    print(f"  Loading {filename} ({file_size_mb:.0f} MB) via COPY FROM STDIN...")

    with open(csv_path, 'rb') as f:
        cur.copy(new_stmt, f)
    conn.commit()
    print(f"  COPY complete.")


def main():
    """Run SQL files passed as command-line arguments."""
    if len(sys.argv) < 2:
        print("Usage: run_sql.py <file1.sql> [file2.sql ...] [--csv-dir /path]")
        sys.exit(1)

    csv_dir = None
    files = []
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == '--csv-dir' and i + 1 < len(sys.argv):
            csv_dir = sys.argv[i + 1]
            i += 2
        else:
            files.append(sys.argv[i])
            i += 1

    print("Connecting to Vertica...")
    wait_for_vertica()
    conn = get_connection()

    for filepath in files:
        execute_sql_file(conn, filepath, csv_dir=csv_dir)

    conn.close()
    print("\nAll SQL files executed successfully.")


if __name__ == '__main__':
    main()
