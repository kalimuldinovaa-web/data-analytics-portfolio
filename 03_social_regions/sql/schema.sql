-- =====================================================================
-- Схема базы данных regions_kz.db
-- Модель «звезда»: справочники regions и indicators + таблицы фактов
-- =====================================================================

DROP TABLE IF EXISTS observations;
DROP TABLE IF EXISTS subsistence_quarterly;
DROP TABLE IF EXISTS indicators;
DROP TABLE IF EXISTS regions;

-- Справочник регионов (20 текущих + ЮКО до 2018 г. + РК в целом)
CREATE TABLE regions (
    region_id     INTEGER PRIMARY KEY,   -- код КАТО (2 знака), 0 = Республика Казахстан
    name_ru       TEXT    NOT NULL,
    name_en       TEXT,                  -- совпадает с ADM1_EN в kz_regions.geojson
    region_type   TEXT    NOT NULL,      -- country / oblast / city
    macro_region  TEXT,                  -- Север / Запад / Центр / Восток / Юг / Города
    is_resource   INTEGER NOT NULL DEFAULT 0,  -- 1 = сырьевой регион (гипотеза H2)
    created_year  INTEGER,               -- год образования (2018 — Туркестанская и Шымкент, 2022 — Абай, Жетісу, Ұлытау)
    abolished_year INTEGER,              -- год упразднения (ЮКО — 2018)
    unit_id       INTEGER,               -- сопоставимая единица для динамики 2015–2024 (16 единиц)
    unit_name     TEXT
);

-- Справочник показателей
CREATE TABLE indicators (
    indicator_code TEXT PRIMARY KEY,
    name_ru        TEXT NOT NULL,
    unit           TEXT NOT NULL,
    agg_rule       TEXT NOT NULL CHECK (agg_rule IN ('sum', 'wavg')),
                   -- как объединять новые области с «родительскими»:
                   -- sum  — абсолютные величины (население, инвестиции, ВРП, жильё, врачи)
                   -- wavg — относительные (доходы на душу, %, коэффициенты): среднее, взвешенное по населению
    source_file    TEXT NOT NULL,
    role           TEXT                   -- target / factor / outcome / control / helper
);

-- Факты: регион × год × показатель (длинный формат)
CREATE TABLE observations (
    region_id      INTEGER NOT NULL REFERENCES regions(region_id),
    year           INTEGER NOT NULL,
    indicator_code TEXT    NOT NULL REFERENCES indicators(indicator_code),
    value          REAL,
    PRIMARY KEY (region_id, year, indicator_code)
);

-- Прожиточный минимум публикуется только поквартально
CREATE TABLE subsistence_quarterly (
    region_id INTEGER NOT NULL REFERENCES regions(region_id),
    year      INTEGER NOT NULL,
    quarter   INTEGER NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    value     REAL,
    PRIMARY KEY (region_id, year, quarter)
);

CREATE INDEX idx_obs_indicator_year ON observations (indicator_code, year);
