"""
Этап 2. Сбор данных: исходные выгрузки БНС (Талдау, stat.gov.kz) → база SQLite.

Запуск из корня проекта:
    python src/build_db.py

Что делает:
1. Читает все файлы из data/raw/ (форматы .xls / .xlsx трёх видов: Талдау, ВРП, жильё).
2. Приводит названия регионов к единому коду КАТО («Г.АСТАНА», «г.Астана» → 71).
3. Переводит таблицы «регион × годы» в длинный формат «регион, год, показатель, значение».
4. Записывает всё в data/regions_kz.db (схема — sql/schema.sql).

Очистка (выбросы, пропуски, проверки логики) — на этапе 3, здесь только загрузка.
"""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
DB_PATH = ROOT / "data" / "regions_kz.db"
SCHEMA = ROOT / "sql" / "schema.sql"

YEAR_MIN, YEAR_MAX = 2015, 2025

# ---------------------------------------------------------------------------
# Справочник регионов
# region_id = код КАТО, unit_id = сопоставимая единица для динамики 2015–2024
# ---------------------------------------------------------------------------
REGIONS = [
    # id, name_ru,                    name_en (geojson),         type,      macro,     resource, created, abolished, unit_id
    (0,  "Республика Казахстан",       None,                      "country", None,      0, None, None, None),
    (10, "Абай",                       "Abay Region",             "oblast",  "Восток",  0, 2022, None, 63),
    (11, "Акмолинская",                "Akmola Region",           "oblast",  "Север",   0, None, None, 11),
    (15, "Актюбинская",                "Aktobe Region",           "oblast",  "Запад",   1, None, None, 15),
    (19, "Алматинская",                "Almaty Region",           "oblast",  "Юг",      0, None, None, 19),
    (23, "Атырауская",                 "Atyrau Region",           "oblast",  "Запад",   1, None, None, 23),
    (27, "Западно-Казахстанская",      "West Kazakhstan Region",  "oblast",  "Запад",   1, None, None, 27),
    (31, "Жамбылская",                 "Jambyl Region",           "oblast",  "Юг",      0, None, None, 31),
    (33, "Жетісу",                     "Jetisu Region",           "oblast",  "Юг",      0, 2022, None, 19),
    (35, "Карагандинская",             "Karaganda Region",        "oblast",  "Центр",   0, None, None, 35),
    (39, "Костанайская",               "Kostanay Region",         "oblast",  "Север",   0, None, None, 39),
    (43, "Кызылординская",             "Kyzylorda Region",        "oblast",  "Юг",      0, None, None, 43),
    (47, "Мангистауская",              "Mangystau Region",        "oblast",  "Запад",   1, None, None, 47),
    (51, "Южно-Казахстанская",         None,                      "oblast",  "Юг",      0, None, 2018, 51),
    (55, "Павлодарская",               "Pavlodar Region",         "oblast",  "Север",   0, None, None, 55),
    (59, "Северо-Казахстанская",       "North Kazakhstan Region", "oblast",  "Север",   0, None, None, 59),
    (61, "Туркестанская",              "Turkistan Region",        "oblast",  "Юг",      0, 2018, None, 51),
    (62, "Ұлытау",                     "Ulytau Region",           "oblast",  "Центр",   0, 2022, None, 35),
    (63, "Восточно-Казахстанская",     "East Kazakhstan Region",  "oblast",  "Восток",  0, None, None, 63),
    (71, "г. Астана",                  "Astana",                  "city",    "Города",  0, None, None, 71),
    (75, "г. Алматы",                  "Almaty",                  "city",    "Города",  0, None, None, 75),
    (79, "г. Шымкент",                 "Shymkent",                "city",    "Города",  0, 2018, None, 51),
]

# Названия сопоставимых единиц (границы до реформ 2018 и 2022 гг.)
UNIT_NAMES = {
    19: "Алматинская + Жетісу",
    35: "Карагандинская + Ұлытау",
    51: "Южно-Казахстанская (Туркестанская + Шымкент)",
    63: "Восточно-Казахстанская + Абай",
}

# Ключ после нормализации названия → код КАТО
NAME_TO_ID = {
    "РЕСПУБЛИКА КАЗАХСТАН": 0, "АБАЙ": 10, "АКМОЛИНСКАЯ": 11, "АКТЮБИНСКАЯ": 15,
    "АЛМАТИНСКАЯ": 19, "АТЫРАУСКАЯ": 23, "ЗАПАДНО-КАЗАХСТАНСКАЯ": 27, "ЖАМБЫЛСКАЯ": 31,
    "ЖЕТІСУ": 33, "КАРАГАНДИНСКАЯ": 35, "КОСТАНАЙСКАЯ": 39, "КЫЗЫЛОРДИНСКАЯ": 43,
    "МАНГИСТАУСКАЯ": 47, "ЮЖНО-КАЗАХСТАНСКАЯ": 51, "ПАВЛОДАРСКАЯ": 55,
    "СЕВЕРО-КАЗАХСТАНСКАЯ": 59, "ТУРКЕСТАНСКАЯ": 61, "ҰЛЫТАУ": 62,
    "ВОСТОЧНО-КАЗАХСТАНСКАЯ": 63, "АСТАНА": 71, "АЛМАТЫ": 75, "ШЫМКЕНТ": 79,
}

# ---------------------------------------------------------------------------
# Справочник показателей
# file — шаблон имени в data/raw; parser — формат файла
# ---------------------------------------------------------------------------
INDICATORS = [
    # code,              name_ru,                                                      unit,                agg,    file pattern,              parser,    role
    ("income_pc",        "Среднедушевые номинальные денежные доходы населения",        "тенге в месяц",     "wavg", "income_per_capita.xls*",  "taldau",  "target"),
    ("wage",             "Среднемесячная номинальная заработная плата",                "тенге",             "wavg", "wage.xls*",               "taldau",  "target_alt"),
    ("population",       "Численность населения на начало года",                       "человек",           "sum",  "population.xls*",         "taldau",  "helper"),
    ("unemployment",     "Уровень безработицы",                                        "%",                 "wavg", "unemployment.xls*",       "taldau",  "factor"),
    ("informal_share",   "Доля неформально занятых в общей численности занятых",       "%",                 "wavg", "informal_share.xls*",     "taldau",  "factor"),
    ("investments",      "Инвестиции в основной капитал",                              "тыс. тенге",        "sum",  "investments.xls*",        "taldau",  "factor"),
    ("grp",              "Валовой региональный продукт",                               "млн тенге",         "sum",  "grp_per_capita.xls*",     "grp",     "control"),
    ("housing",          "Ввод в эксплуатацию жилых зданий, общая площадь",            "тыс. кв. м",        "sum",  "housing.xls*",            "housing", "factor"),
    ("doctors",          "Списочная численность врачей всех специальностей",           "человек",           "sum",  "doctors.xls*",            "taldau",  "factor"),
    ("doctors_per10k",   "Врачи на 10 000 населения (официальный расчёт БНС)",         "на 10 000 чел.",    "wavg", "doctors_per10k.xls*",     "taldau",  "check"),
    ("migration_per1000","Сальдо миграции по всем потокам на 1000 человек",            "на 1000 чел.",      "wavg", "migration_per1000.xls*",  "taldau",  "outcome"),
    ("poverty",          "Доля населения с доходами ниже прожиточного минимума",       "%",                 "wavg", "poverty.xls*",            "taldau",  "outcome"),
    ("life_expectancy",  "Ожидаемая продолжительность жизни при рождении",             "лет",               "wavg", "life_expectancy.xls*",    "taldau",  "outcome"),
    ("education_low",    "Доля рабочей силы без профессионального образования",        "%",                 "wavg", "education.xls*",          "taldau",  "factor"),
]
SUBSISTENCE_FILE = "subsistence_min.xls*"
POPULATION_2025_FILE = "population_2025.xls*"


# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------
def read_excel_any(path: Path, **kwargs) -> pd.DataFrame:
    """Читает .xls/.xlsx. Для старого .xls нужен xlrd (есть в Anaconda) или python-calamine."""
    try:
        return pd.read_excel(path, header=None, **kwargs)
    except ImportError:
        return pd.read_excel(path, header=None, engine="calamine", **kwargs)


def region_id(raw_name) -> int | None:
    """'    Г.АСТАНА' / 'г.Астана' / 'Туркестанская2)' / 'ОБЛАСТЬ ЖЕТІСУ' → код КАТО."""
    if pd.isna(raw_name):
        return None
    s = str(raw_name).upper()
    s = re.sub(r"\d+\)", "", s)                 # сноски вида «2)»
    s = s.replace("ОБЛАСТЬ", "").replace("Г.", "")
    s = re.sub(r"\s+", " ", s).strip()
    return NAME_TO_ID.get(s)


def parse_year(label) -> int | None:
    """'2015 год' / 2015.0 / '2021 год 3)' → 2015 / 2021."""
    m = re.search(r"(19|20)\d{2}", str(label))
    return int(m.group(0)) if m else None


def to_number(x) -> float | None:
    """'67 321' / '4,9' / '-' / '...' / 'x' → число или None."""
    if pd.isna(x):
        return None
    if isinstance(x, (int, float)):
        return float(x)
    s = str(x).replace("\xa0", "").replace(" ", "").replace(",", ".").strip()
    if s in {"", "-", "...", "…", "x", "х"}:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def find_file(pattern: str) -> Path | None:
    files = sorted(RAW.glob(pattern))
    return files[0] if files else None


# ---------------------------------------------------------------------------
# Парсеры трёх форматов
# ---------------------------------------------------------------------------
def parse_taldau(path: Path) -> pd.DataFrame:
    """Выгрузка Талдау: шапка с метаданными, затем строка 'Регион | 2015 год | ...'."""
    df = read_excel_any(path)
    header_rows = df.index[df[0].astype(str).str.strip().eq("Регион")]
    if len(header_rows) == 0:
        raise ValueError("не найдена строка заголовка 'Регион' (файл не в формате Талдау)")
    hr = header_rows[0]
    years = {col: parse_year(df.iat[hr, col]) for col in df.columns[1:]}
    records = []
    for _, row in df.iloc[hr + 1:].iterrows():
        rid = region_id(row[0])
        if rid is None:
            continue
        for col, year in years.items():
            if year is not None:
                records.append((rid, year, to_number(row[col])))
    return pd.DataFrame(records, columns=["region_id", "year", "value"])


def parse_taldau_quarterly(path: Path) -> pd.DataFrame:
    """Квартальная выгрузка Талдау: столбцы '1 квартал 2011 г.'."""
    df = read_excel_any(path)
    hr = df.index[df[0].astype(str).str.strip().eq("Регион")][0]
    cols = {}
    for col in df.columns[1:]:
        m = re.match(r"\s*(\d)\s*квартал\s*(\d{4})", str(df.iat[hr, col]))
        if m:
            cols[col] = (int(m.group(2)), int(m.group(1)))
    records = []
    for _, row in df.iloc[hr + 1:].iterrows():
        rid = region_id(row[0])
        if rid is None:
            continue
        for col, (year, q) in cols.items():
            records.append((rid, year, q, to_number(row[col])))
    return pd.DataFrame(records, columns=["region_id", "year", "quarter", "value"])


def parse_grp(path: Path) -> pd.DataFrame:
    """ВРП (stat.gov.kz, динамические ряды): лист '2008-...', годовые столбцы 'YYYY год'."""
    sheet = next(s for s in pd.ExcelFile(path).sheet_names if s.strip().startswith("2008"))
    df = read_excel_any(path, sheet_name=sheet)
    hr = df.index[df[1].astype(str).str.strip().eq("Наименование")][0]
    year_cols = {}
    for col in df.columns[2:]:
        label = str(df.iat[hr, col])
        if re.search(r"\d{4}\s*год", label) and "квартал" not in label and "месяц" not in label \
                and "полугодие" not in label:
            year_cols[col] = parse_year(label)
    records = []
    for _, row in df.iloc[hr + 1:].iterrows():
        rid = region_id(row[1])
        if rid is None:
            continue
        for col, year in year_cols.items():
            records.append((rid, year, to_number(row[col])))
    return pd.DataFrame(records, columns=["region_id", "year", "value"])


def parse_housing(path: Path) -> pd.DataFrame:
    """Ввод жилья (stat.gov.kz): лист 'показатель', годы в 3-й строке, тыс. кв. м."""
    df = read_excel_any(path, sheet_name="показатель")
    hr = next(i for i in range(10) if parse_year(df.iat[i, 1]) is not None)
    years = {col: parse_year(df.iat[hr, col]) for col in df.columns[1:]}
    records = []
    for _, row in df.iloc[hr + 1:].iterrows():
        rid = region_id(row[0])
        if rid is None:
            continue
        for col, year in years.items():
            if year is not None:
                records.append((rid, year, to_number(row[col])))
    return pd.DataFrame(records, columns=["region_id", "year", "value"])


PARSERS = {"taldau": parse_taldau, "grp": parse_grp, "housing": parse_housing}


# ---------------------------------------------------------------------------
# Сборка базы
# ---------------------------------------------------------------------------
def build() -> None:
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = sqlite3.connect(DB_PATH)
    con.executescript(SCHEMA.read_text(encoding="utf-8"))

    # 1. Справочник регионов
    con.executemany(
        "INSERT INTO regions VALUES (?,?,?,?,?,?,?,?,?,?)",
        [(*r, r[8] and UNIT_NAMES.get(r[8], next(x[1] for x in REGIONS if x[0] == r[8])))
         for r in REGIONS],
    )

    # 2. Показатели
    log = []
    for code, name, unit, agg, pattern, parser, role in INDICATORS:
        path = find_file(pattern)
        if path is None:
            log.append((code, "—", 0, 0, "файл не найден"))
            continue
        try:
            data = PARSERS[parser](path)
        except Exception as e:  # noqa: BLE001 — показываем причину и идём дальше
            log.append((code, path.name, 0, 0, f"пропущен: {e}"))
            continue

        n_regions = data.loc[data.region_id != 0, "region_id"].nunique()
        if n_regions < 15:
            log.append((code, path.name, len(data), n_regions,
                        "пропущен: в файле нет разбивки по регионам — перевыгрузить с боковиком «Регионы»"))
            continue

        # Население на 2025 год лежит в отдельном файле
        if code == "population":
            p25 = find_file(POPULATION_2025_FILE)
            if p25 is not None:
                extra = parse_taldau(p25)
                data = pd.concat([data, extra[~extra.year.isin(data.year)]], ignore_index=True)

        # ВРП: БНС пересчитал Туркестанскую обл. и Шымкент назад до 2011 г., но ЮКО
        # за 2015–2017 тоже оставлена. Чтобы не считать дважды, как в остальных файлах,
        # до 2018 г. оставляем ЮКО, а новые единицы убираем.
        if code == "grp":
            dup = data.region_id.isin([61, 79]) & (data.year < 2018)
            data = data[~dup]

        data = data[data.year.between(YEAR_MIN, YEAR_MAX)]
        n_before = len(data)
        data = data.drop_duplicates(["region_id", "year"])
        con.execute("INSERT INTO indicators VALUES (?,?,?,?,?,?)",
                    (code, name, unit, agg, path.name, role))
        con.executemany(
            "INSERT INTO observations VALUES (?,?,?,?)",
            [(int(r.region_id), int(r.year), code, r.value) for r in data.itertuples()],
        )
        status = "ок" if n_before == len(data) else f"ок, удалено дублей: {n_before - len(data)}"
        log.append((code, path.name, len(data), n_regions, status))

    # 3. Прожиточный минимум (кварталы)
    path = find_file(SUBSISTENCE_FILE)
    if path is not None:
        q = parse_taldau_quarterly(path)
        q = q[q.year.between(YEAR_MIN, YEAR_MAX)]
        con.executemany("INSERT INTO subsistence_quarterly VALUES (?,?,?,?)",
                        [(int(r.region_id), int(r.year), int(r.quarter), r.value) for r in q.itertuples()])
        log.append(("subsistence_q", path.name, len(q), q.region_id.nunique() - 1, "ок (кварталы)"))

    con.commit()
    con.close()

    report = pd.DataFrame(log, columns=["показатель", "файл", "строк", "регионов", "статус"])
    print(report.to_string(index=False))
    print(f"\nБаза сохранена: {DB_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    build()
