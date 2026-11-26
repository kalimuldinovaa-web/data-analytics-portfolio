"""
Выполняет sql/queries.sql на базе data/regions_kz.db:
- блоки v_* создают представления;
- блоки q* выполняются, результат сохраняется в data/processed/<name>.csv.

Запуск из корня проекта:
    python src/run_queries.py
"""

import math
import re
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "regions_kz.db"
SQL_PATH = ROOT / "sql" / "queries.sql"
OUT = ROOT / "data" / "processed"


def ensure_math(con: sqlite3.Connection) -> None:
    """SQRT и POWER есть не во всех сборках SQLite — при необходимости добавляем из Python."""
    try:
        con.execute("SELECT SQRT(4), POWER(2, 0.5)").fetchone()
    except sqlite3.OperationalError:
        con.create_function("SQRT", 1, lambda x: None if x is None or x < 0 else math.sqrt(x))
        con.create_function("POWER", 2, lambda x, y: None if x is None or y is None else x ** y)


def split_blocks(sql_text: str) -> list[tuple[str, str]]:
    parts = re.split(r"^-- name:\s*(\S+)\s*$", sql_text, flags=re.MULTILINE)
    return [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    ensure_math(con)

    for name, sql in split_blocks(SQL_PATH.read_text(encoding="utf-8")):
        if name.startswith("v_"):
            con.executescript(sql)
            print(f"VIEW  {name}")
        else:
            df = pd.read_sql_query(sql, con)
            df.to_csv(OUT / f"{name}.csv", index=False, encoding="utf-8-sig")
            print(f"QUERY {name:<28} {df.shape[0]:>4} строк × {df.shape[1]:>2} столбцов → data/processed/{name}.csv")

    con.close()


if __name__ == "__main__":
    main()
