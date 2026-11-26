"""Загрузка listings_*.csv в SQLite (используется в 02_sql.ipynb)."""
import re
import sqlite3
from pathlib import Path

import pandas as pd

DISTRICTS = pd.DataFrame([
    # district, bank, note
    ("Есильский", "Левый берег", "деловой центр, новостройки"),
    ("Нура", "Левый берег", "новый район, массовые ЖК"),
    ("Алматинский", "Правый берег", "часть территории отошла району Сарайшык"),
    ("Сарайшык", "Правый берег", "выделен из Алматинского района в 2024 г."),
    ("Сарыарка", "Правый берег", "старый центр, вторичка"),
    ("Байконур", "Правый берег", "старый центр, вторичка"),
], columns=["district", "bank", "note"])

DISTRICT_ALIASES = {
    "есильский": "Есильский", "есиль": "Есильский",
    "нура": "Нура",
    "алматы": "Алматинский", "алматинский": "Алматинский",
    "сарайшык": "Сарайшык", "сарайшик": "Сарайшык",
    "сарыарка": "Сарыарка", "сарыаркинский": "Сарыарка",
    "байконур": "Байконур", "байқоңыр": "Байконур",
}


def extract_district(address: str):
    """'Нура р-н, Улы Дала 12' или 'р-н Байконур, Абая 92' -> 'Нура' / 'Байконур'."""
    if not isinstance(address, str):
        return None
    m = re.match(r"\s*(?:р-н\s+([^,]+)|([^,]+?)\s+р-н)", address)
    if not m:
        return None
    raw = (m.group(1) or m.group(2)).strip().lower()
    return DISTRICT_ALIASES.get(raw, raw.title())


def build(csv_path, db_path="data/krisha.db"):
    df = pd.read_csv(csv_path)
    df["district"] = df["address"].map(extract_district)
    df["street"] = df["address"].str.replace(r"^\s*(р-н\s+[^,]+|[^,]+?\s+р-н),\s*", "", regex=True)
    listings = df[["id", "deal", "city", "district", "street", "rooms", "area_m2", "floor",
                   "floors_total", "price_kzt", "title", "url", "scraped_at"]].rename(columns={"id": "listing_id"})
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as con:
        listings.to_sql("listings", con, if_exists="replace", index=False)
        DISTRICTS.to_sql("districts", con, if_exists="replace", index=False)
    return listings
