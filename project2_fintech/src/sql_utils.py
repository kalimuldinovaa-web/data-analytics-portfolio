"""Загрузка именованных запросов из sql/queries.sql и выполнение в SQLite."""
from pathlib import Path
import re
import sqlite3

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "processed" / "loans.sqlite"
SQL_FILE = ROOT / "sql" / "queries.sql"


def load_queries(path: Path = SQL_FILE) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- name:\s*(\w+)\s*$", text, flags=re.M)
    return {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}


def run(name: str, db: Path = DB) -> pd.DataFrame:
    with sqlite3.connect(db) as con:
        return pd.read_sql_query(load_queries()[name], con)
