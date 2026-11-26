"""Этап 2. Сборка учебной БД SQLite из выгрузки Excel.

Запуск из корня репозитория:
    python src/build_db.py

Создаёт data/processed/loans.sqlite с таблицами:
    loans               — детализация выдач (1 строка = 1 выдача)
    managers            — справочник менеджеров
    dim_source_product  — нормализация поля «Продукт_из_источника» (канал/застройщик)
    source_monthly      — помесячные итоги из исходного отчёта (для сверки)
    date_adjustments    — журнал корректировок дат и исключённых строк
"""
from pathlib import Path
import sqlite3

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw" / "astana_loans_2023_2026.xlsx"
DB = ROOT / "data" / "processed" / "loans.sqlite"

LOAN_COLS = {
    "Год": "year",
    "Месяц": "month_name",
    "Месяц_номер": "month",
    "Дата_выдачи": "issue_date",
    "Дата_источника": "date_quality",
    "Менеджер_ID": "manager_id",
    "Клиент_ID": "client_id",
    "Фамилия_клиента_синтетическая": "client_surname_synth",
    "Продукт": "product",
    "Сумма_выдачи_KZT": "amount_kzt",
    "Счетчик_выдачи": "issue_cnt",
    "Продукт_из_источника": "source_product_raw",
}

# Ручной словарь: «грязная» подпись менеджера -> (канал, застройщик)
# Канал описывает, откуда пришла сделка; застройщик — партнёр по первичке.
DEVELOPERS = {
    "BI Group": ["bi", "bi group", "bi-group", "bigroup", "би ай", "биай", "биай готовый",
                 "биай партн", "биай стандарт", "партн  биай", "ци биай"],
    "Sensata": ["sensata", "сенсата", "cенсата", "сенсата партн", "стандарт(сенсата)", "sat ns", "сат нс"],
    "Bazis-A": ["bazis", "bazis a", "bazis-a", "bazisa", "базис", "базис стандарт", "тб bazis-a", "тб базис"],
    "Ulytau": ["ulytau", "ulytau дом", "улытау", "улытау груп", "улытау под собств"],
    "Мой дом": ["moy dom", "moydom", "мой дом", "мойдом", "мой дом бпд"],
    "MWC": ["mwc", "мwc", "партн  mwc"],
    "Онай": ["онай"],
    "Прочие застройщики": ["феррум", "исма", "орда инвест", "house project", "застройщик"],
}
CHANNELS = {
    "Стандарт (без партнёра)": ["стандарт", "станд", "ст", "standart", "cтандарт", "стандрат", "стнадарт",
                                "страндарт", "стандарт тб", "стандрат тб", "тб", "стандарт бпд", "станд бпд",
                                "бпд", "бпд станд", "бпд стандарт"],
    "Цифровая ипотека (ЦИ)": ["ци", "стандарт ци", "цифр ипотека"],
    "Вторичное жильё": ["вторичка", "вточрика"],
    "Под собственный залог": ["свой залог", "под свой залог", "собс залог", "собст залог", "собств залог",
                              "под залог", "потреб залог", "залог", "залоговый"],
    "Госпрограмма 7-20-25": ["7-20-25", "7/20/25", "72025", "7"],
    "Беззалоговый: БЗК/рефинанс": ["бзк", "бзп", "бзв", "бз", "бз реф", "реф", "реф бзк", "беззалог",
                                   "карта", "топ ап"],
}


def build_dim(raw_values: pd.Series) -> pd.DataFrame:
    rows = []
    for raw in sorted(raw_values.dropna().unique()):
        key = str(raw).strip().lower()
        channel, developer = "Прочее / нераспознано", None
        for dev, keys in DEVELOPERS.items():
            if key in keys:
                channel, developer = "Партнёр-застройщик", dev
        for ch, keys in CHANNELS.items():
            if key in keys:
                channel = ch
        rows.append({"source_product_raw": raw, "channel": channel, "developer": developer})
    return pd.DataFrame(rows)


def main() -> None:
    xls = pd.ExcelFile(RAW)
    loans = xls.parse("Детализация_2023_2026").rename(columns=LOAN_COLS)
    loans["issue_date"] = pd.to_datetime(loans["issue_date"]).dt.strftime("%Y-%m-%d")
    loans.insert(0, "loan_id", range(1, len(loans) + 1))

    managers = xls.parse("Справочник_менеджеров").rename(columns={"Менеджер_ID": "manager_id"})
    monthly = xls.parse("Выдачи_год_месяц").rename(columns={
        "Год": "year", "Месяц_номер": "month", "Месяц": "month_name", "Продукт": "product",
        "Количество_выдач": "src_cnt", "Сумма_выдач_KZT": "src_amount_kzt",
        "Уникальных_клиентов": "src_clients"})
    adj = xls.parse("Корректировки_дат")
    adj.columns = [f"c{i}_" + str(c).strip().replace(" ", "_") for i, c in enumerate(adj.columns)]
    dim = build_dim(loans["source_product_raw"])

    DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB) as con:
        loans.to_sql("loans", con, if_exists="replace", index=False)
        managers.to_sql("managers", con, if_exists="replace", index=False)
        dim.to_sql("dim_source_product", con, if_exists="replace", index=False)
        monthly.to_sql("source_monthly", con, if_exists="replace", index=False)
        adj.to_sql("date_adjustments", con, if_exists="replace", index=False)
        con.execute("CREATE INDEX IF NOT EXISTS ix_loans_mgr ON loans(manager_id)")
        con.execute("CREATE INDEX IF NOT EXISTS ix_loans_date ON loans(issue_date)")

    print(f"БД готова: {DB.relative_to(ROOT)} | loans={len(loans):,} | managers={len(managers)} "
          f"| dim_source_product={len(dim)}")


if __name__ == "__main__":
    main()
