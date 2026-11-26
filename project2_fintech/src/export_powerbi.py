"""Этап 8. Выгрузка модели данных для Power BI (схема «звезда»).

Запуск из корня репозитория (после build_db.py и ноутбука, который считает прогноз):
    python src/export_powerbi.py

Создаёт data/powerbi/:
    fact_loans.csv     — факт: 1 строка = 1 выдача
    dim_date.csv       — календарь (2023-01-01 … 2026-12-31)
    dim_manager.csv    — менеджеры: период работы, тип найма, статус
    dim_channel.csv    — каналы и застройщики (нормализованная подпись продукта)
    fact_forecast.csv  — прогноз и сценарии на 4 квартал 2026 (из ноутбука, §6.3–6.4)
CSV в UTF-8 с BOM — Power BI и Excel корректно читают кириллицу.
"""
from pathlib import Path
import sqlite3

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "processed" / "loans.sqlite"
OUT = ROOT / "data" / "powerbi"
FORECAST = ROOT / "data" / "processed" / "forecast_q4_2026.csv"

MONTHS_RU = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь",
             "Октябрь", "Ноябрь", "Декабрь"]
DAYS_RU = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]


def segment(product: str, channel: str, developer: str) -> str:
    """Сегмент для анализа потерь (как в ноутбуке, §5.1)."""
    if product == "Беззалоговый займ":
        return "Беззалоговые займы"
    if channel == "Партнёр-застройщик":
        return "Застройщик: BI Group" if developer == "BI Group" else "Застройщики: прочие"
    if channel == "Не указано":
        return "Залог: канал не указан"
    if channel.startswith("Беззалоговый") or channel.startswith("Прочее"):
        return "Залог: прочее"
    return "Залог: " + channel


def main() -> None:
    if not DB.exists():
        import build_db
        build_db.main()
    OUT.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB) as con:
        loans = pd.read_sql_query("""
            WITH l AS (
                SELECT l.*, COALESCE(d.channel, 'Не указано') AS channel, COALESCE(d.developer, '—') AS developer
                FROM loans l LEFT JOIN dim_source_product d ON d.source_product_raw = l.source_product_raw
            )
            SELECT loan_id, issue_date, manager_id, client_id, product, channel, developer, amount_kzt, date_quality
            FROM l
        """, con)

    loans["issue_date"] = pd.to_datetime(loans["issue_date"])
    loans = loans.sort_values(["client_id", "issue_date", "loan_id"])
    # Повторная выдача: клиент уже брал займ раньше (связь клиентов видна в 01–09.2025)
    loans["loan_seq"] = loans.groupby("client_id").cumcount() + 1
    loans["is_repeat"] = (loans["loan_seq"] > 1).astype(int)
    loans["is_conditional_date"] = loans["date_quality"].str.contains("Условн|Смоделир").astype(int)
    loans["segment"] = [segment(p, c, d) for p, c, d in zip(loans["product"], loans["channel"], loans["developer"])]
    loans["channel_key"] = loans["channel"] + " | " + loans["developer"]
    loans["date"] = loans["issue_date"].dt.date

    fact = loans[["loan_id", "date", "manager_id", "client_id", "product", "channel_key", "segment",
                  "amount_kzt", "is_repeat", "loan_seq", "is_conditional_date"]].sort_values("loan_id")
    fact.to_csv(OUT / "fact_loans.csv", index=False, encoding="utf-8-sig")

    dates = pd.date_range("2023-01-01", "2026-12-31", freq="D")
    dim_date = pd.DataFrame({
        "date": dates.date, "year": dates.year, "quarter": "Q" + dates.quarter.astype(str),
        "month_num": dates.month, "month_name": [MONTHS_RU[m - 1] for m in dates.month],
        "year_month": dates.strftime("%Y-%m"), "day": dates.day,
        "weekday_num": dates.dayofweek + 1, "weekday": [DAYS_RU[d] for d in dates.dayofweek],
        "is_weekend": (dates.dayofweek >= 5).astype(int),
        "is_last5_days": (dates.days_in_month - dates.day < 5).astype(int),
        "half_year": ["H1" if m <= 6 else "H2" for m in dates.month],
    })
    dim_date["month_start"] = pd.to_datetime(dim_date["year_month"] + "-01").dt.date
    dim_date.to_csv(OUT / "dim_date.csv", index=False, encoding="utf-8-sig")

    last_month = loans["issue_date"].max().to_period("M")
    mm = loans.assign(ym=loans["issue_date"].dt.to_period("M")).groupby("manager_id")["ym"].agg(["min", "max", "nunique"])
    dim_mgr = pd.DataFrame({
        "manager_id": mm.index,
        "first_month": mm["min"].astype(str).values,
        "last_month": mm["max"].astype(str).values,
        "months_active": mm["nunique"].values,
    })
    dim_mgr["hire_type"] = [
        "Работал до начала данных" if f == "2023-01" else ("Январская смена команды" if f.endswith("-01") else "Найм в течение года")
        for f in dim_mgr["first_month"]]
    dim_mgr["status"] = ["Работает" if pd.Period(l, "M") >= last_month - 1 else "Уволился" for l in dim_mgr["last_month"]]
    dim_mgr.to_csv(OUT / "dim_manager.csv", index=False, encoding="utf-8-sig")

    dim_ch = (loans[["channel_key", "channel", "developer"]].drop_duplicates().sort_values("channel_key"))
    dim_ch["is_partner"] = (dim_ch["channel"] == "Партнёр-застройщик").astype(int)
    dim_ch.to_csv(OUT / "dim_channel.csv", index=False, encoding="utf-8-sig")

    if FORECAST.exists():
        fc = pd.read_csv(FORECAST)
        fc = fc.rename(columns={"base": "base_mln", "lo": "low_mln", "hi": "high_mln", "s1": "s1_unsecured_mln",
                                "s2": "s2_secured_mln", "s3": "s3_repeat_clients_mln"})
        fc.insert(1, "month_start", pd.to_datetime(fc["ym"] + "-01").dt.date)
        fc.to_csv(OUT / "fact_forecast.csv", index=False, encoding="utf-8-sig")
    else:
        print("! Нет прогноза: сначала выполните ноутбук (§6.3–6.4), затем перезапустите скрипт.")

    print(f"Готово: {OUT.relative_to(ROOT)} | fact_loans={len(fact):,} | dim_manager={len(dim_mgr)} | "
          f"dim_channel={len(dim_ch)} | dim_date={len(dim_date):,}")


if __name__ == "__main__":
    main()
