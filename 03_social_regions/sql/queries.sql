-- =====================================================================
-- Этап 2. Выгрузка срезов для анализа
-- База: data/regions_kz.db (SQLite), строится скриптом src/build_db.py
--
-- Часть 1 — представления (VIEW): из них берутся все срезы.
-- Часть 2 — аналитические запросы: результат каждого сохраняется
--           в data/processed/<name>.csv скриптом src/run_queries.py.
--
-- Каждый блок начинается с маркера «-- name: ...».
-- =====================================================================


-- =====================================================================
-- ЧАСТЬ 1. ПРЕДСТАВЛЕНИЯ
-- =====================================================================

-- name: v_region_years
-- Какие пары «регион × год» существовали на самом деле.
-- Нужно, чтобы отличать структурный пропуск (области Абай в 2019 г. ещё не было)
-- от настоящего пропуска в данных.
DROP VIEW IF EXISTS v_region_years;
CREATE VIEW v_region_years AS
WITH RECURSIVE years(year) AS (
    SELECT 2015
    UNION ALL
    SELECT year + 1 FROM years WHERE year < 2025
)
SELECT r.region_id, y.year
FROM regions AS r
CROSS JOIN years AS y
WHERE r.region_type <> 'country'
  AND y.year >= COALESCE(r.created_year, 0)
  AND y.year <  COALESCE(r.abolished_year, 9999);


-- name: v_subsistence_annual
-- Прожиточный минимум: среднее по кварталам года.
-- В год реформы новые регионы публикуются со 2-го квартала (Туркестанская
-- и Шымкент в 2018 г., Абай, Жетісу, Ұлытау в 2022 г.), поэтому для них
-- берём среднее из трёх кварталов. Год с 1–2 кварталами не используем.
DROP VIEW IF EXISTS v_subsistence_annual;
CREATE VIEW v_subsistence_annual AS
SELECT region_id,
       year,
       AVG(value)   AS subsistence,
       COUNT(value) AS n_quarters
FROM subsistence_quarterly
GROUP BY region_id, year
HAVING COUNT(value) >= 3;


-- name: v_panel_regions
-- Основная панель: 20 регионов (+ ЮКО до 2018 г.) × 2015–2024.
-- Длинный формат разворачивается в широкий через условную агрегацию,
-- абсолютные величины пересчитываются на душу населения.
DROP VIEW IF EXISTS v_panel_regions;
CREATE VIEW v_panel_regions AS
WITH wide AS (
    SELECT region_id,
           year,
           MAX(CASE WHEN indicator_code = 'population'        THEN value END) AS population,
           MAX(CASE WHEN indicator_code = 'income_pc'         THEN value END) AS income_pc,
           MAX(CASE WHEN indicator_code = 'wage'              THEN value END) AS wage,
           MAX(CASE WHEN indicator_code = 'unemployment'      THEN value END) AS unemployment,
           MAX(CASE WHEN indicator_code = 'informal_share'    THEN value END) AS informal_share,
           MAX(CASE WHEN indicator_code = 'investments'       THEN value END) AS investments_thous,
           MAX(CASE WHEN indicator_code = 'grp'               THEN value END) AS grp_mln,
           MAX(CASE WHEN indicator_code = 'housing'           THEN value END) AS housing_thous_m2,
           MAX(CASE WHEN indicator_code = 'doctors'           THEN value END) AS doctors,
           MAX(CASE WHEN indicator_code = 'migration_per1000' THEN value END) AS migration_per1000,
           MAX(CASE WHEN indicator_code = 'poverty'           THEN value END) AS poverty,
           MAX(CASE WHEN indicator_code = 'life_expectancy'   THEN value END) AS life_expectancy,
           MAX(CASE WHEN indicator_code = 'education_low'     THEN value END) AS education_low
    FROM observations
    WHERE year BETWEEN 2015 AND 2024
    GROUP BY region_id, year
)
SELECT r.region_id,
       r.name_ru                                         AS region,
       r.name_en,
       r.macro_region,
       r.is_resource,
       r.unit_id,
       w.year,
       w.population,
       w.income_pc,
       s.subsistence,
       ROUND(w.income_pc / s.subsistence, 3)             AS income_to_subsistence,
       w.wage,
       w.unemployment,
       w.informal_share,
       ROUND(w.investments_thous * 1000.0 / w.population)  AS investments_pc,     -- тенге на человека
       ROUND(w.grp_mln * 1000000.0 / w.population)         AS grp_pc,             -- тенге на человека
       ROUND(w.housing_thous_m2 * 1000000.0 / w.population, 1) AS housing_m2_per1000,
       ROUND(w.doctors * 10000.0 / w.population, 1)        AS doctors_per10k,
       w.migration_per1000,
       w.poverty,
       w.life_expectancy,
       w.education_low,
       -- абсолютные значения: нужны на этапе 3 для пересчёта на среднегодовое население
       w.investments_thous,
       w.grp_mln,
       w.housing_thous_m2,
       w.doctors
FROM wide AS w
JOIN regions AS r                 ON r.region_id = w.region_id
JOIN v_region_years AS ry         ON ry.region_id = w.region_id AND ry.year = w.year
LEFT JOIN v_subsistence_annual AS s ON s.region_id = w.region_id AND s.year = w.year;


-- name: v_panel_units
-- Сопоставимая панель для динамики: 16 единиц в границах до реформ.
--   Туркестанская + Шымкент   → Южно-Казахстанская
--   Абай + ВКО, Жетісу + Алматинская, Ұлытау + Карагандинская.
-- Абсолютные показатели складываются (sum),
-- относительные усредняются с весами по численности населения (wavg).
DROP VIEW IF EXISTS v_panel_units;
CREATE VIEW v_panel_units AS
WITH pop AS (
    SELECT region_id, year, value AS population
    FROM observations
    WHERE indicator_code = 'population'
),
facts AS (
    -- все показатели + прожиточный минимум как ещё один относительный показатель
    SELECT o.region_id, o.year, o.indicator_code, o.value, i.agg_rule
    FROM observations AS o
    JOIN indicators AS i ON i.indicator_code = o.indicator_code
    UNION ALL
    SELECT region_id, year, 'subsistence', subsistence, 'wavg'
    FROM v_subsistence_annual
),
parts AS (
    SELECT r.unit_id, f.year, f.indicator_code, f.agg_rule, f.value, p.population
    FROM facts AS f
    JOIN regions AS r ON r.region_id = f.region_id
    LEFT JOIN pop AS p ON p.region_id = f.region_id AND p.year = f.year
    WHERE r.unit_id IS NOT NULL
      AND f.year BETWEEN 2015 AND 2024
      AND f.value IS NOT NULL
),
expected AS (
    -- сколько частей должно быть у единицы в данном году
    SELECT r.unit_id, ry.year, COUNT(*) AS n_expected
    FROM v_region_years AS ry
    JOIN regions AS r ON r.region_id = ry.region_id
    GROUP BY r.unit_id, ry.year
),
agg AS (
    SELECT p.unit_id,
           p.year,
           p.indicator_code,
           CASE WHEN p.agg_rule = 'sum'
                THEN SUM(p.value)
                ELSE SUM(p.value * p.population) / SUM(p.population)
           END       AS value,
           COUNT(*)  AS n_parts
    FROM parts AS p
    GROUP BY p.unit_id, p.year, p.indicator_code
),
complete AS (
    -- если какой-то части не хватает, сумма будет занижена — такой год обнуляем
    SELECT a.unit_id, a.year, a.indicator_code,
           CASE WHEN a.n_parts >= e.n_expected THEN a.value END AS value
    FROM agg AS a
    JOIN expected AS e ON e.unit_id = a.unit_id AND e.year = a.year
),
wide AS (
    SELECT unit_id,
           year,
           MAX(CASE WHEN indicator_code = 'population'        THEN value END) AS population,
           MAX(CASE WHEN indicator_code = 'income_pc'         THEN value END) AS income_pc,
           MAX(CASE WHEN indicator_code = 'subsistence'       THEN value END) AS subsistence,
           MAX(CASE WHEN indicator_code = 'wage'              THEN value END) AS wage,
           MAX(CASE WHEN indicator_code = 'unemployment'      THEN value END) AS unemployment,
           MAX(CASE WHEN indicator_code = 'informal_share'    THEN value END) AS informal_share,
           MAX(CASE WHEN indicator_code = 'investments'       THEN value END) AS investments_thous,
           MAX(CASE WHEN indicator_code = 'grp'               THEN value END) AS grp_mln,
           MAX(CASE WHEN indicator_code = 'housing'           THEN value END) AS housing_thous_m2,
           MAX(CASE WHEN indicator_code = 'doctors'           THEN value END) AS doctors,
           MAX(CASE WHEN indicator_code = 'migration_per1000' THEN value END) AS migration_per1000,
           MAX(CASE WHEN indicator_code = 'poverty'           THEN value END) AS poverty,
           MAX(CASE WHEN indicator_code = 'life_expectancy'   THEN value END) AS life_expectancy,
           MAX(CASE WHEN indicator_code = 'education_low'     THEN value END) AS education_low
    FROM complete
    GROUP BY unit_id, year
)
SELECT w.unit_id,
       u.unit_name,
       u.macro_region,
       u.is_resource,
       w.year,
       ROUND(w.population)                                  AS population,
       ROUND(w.income_pc)                                   AS income_pc,
       ROUND(w.subsistence)                                 AS subsistence,
       ROUND(w.income_pc / w.subsistence, 3)                AS income_to_subsistence,
       ROUND(w.wage)                                        AS wage,
       ROUND(w.unemployment, 2)                             AS unemployment,
       ROUND(w.informal_share, 2)                           AS informal_share,
       ROUND(w.investments_thous * 1000.0 / w.population)   AS investments_pc,
       ROUND(w.grp_mln * 1000000.0 / w.population)          AS grp_pc,
       ROUND(w.housing_thous_m2 * 1000000.0 / w.population, 1) AS housing_m2_per1000,
       ROUND(w.doctors * 10000.0 / w.population, 1)         AS doctors_per10k,
       ROUND(w.migration_per1000, 2)                        AS migration_per1000,
       ROUND(w.poverty, 2)                                  AS poverty,
       ROUND(w.life_expectancy, 2)                          AS life_expectancy,
       ROUND(w.education_low, 2)                            AS education_low,
       -- абсолютные значения для пересчёта на этапе 3
       w.investments_thous,
       w.grp_mln,
       w.housing_thous_m2,
       w.doctors
FROM wide AS w
JOIN regions AS u ON u.region_id = w.unit_id;


-- =====================================================================
-- ЧАСТЬ 2. АНАЛИТИЧЕСКИЕ ЗАПРОСЫ
-- =====================================================================

-- name: q01_data_coverage
-- Паспорт данных: за какие годы есть каждый показатель
-- и сколько настоящих пропусков (регион существовал, а значения нет).
WITH last_year AS (
    SELECT indicator_code, MAX(year) AS last_year
    FROM observations
    WHERE value IS NOT NULL AND region_id <> 0
    GROUP BY indicator_code
)
SELECT i.indicator_code,
       i.name_ru,
       i.unit,
       i.role,
       MIN(CASE WHEN o.value IS NOT NULL THEN o.year END)              AS first_year,
       ly.last_year,
       COUNT(DISTINCT CASE WHEN o.value IS NOT NULL THEN o.region_id END) AS n_regions,
       SUM(CASE WHEN o.value IS NOT NULL THEN 1 ELSE 0 END)              AS n_values,
       SUM(CASE WHEN o.value IS NULL AND ry.region_id IS NOT NULL
                 AND o.year <= ly.last_year THEN 1 ELSE 0 END)           AS real_gaps
FROM indicators AS i
JOIN observations AS o     ON o.indicator_code = i.indicator_code AND o.region_id <> 0
JOIN last_year AS ly       ON ly.indicator_code = i.indicator_code
LEFT JOIN v_region_years AS ry ON ry.region_id = o.region_id AND ry.year = o.year
GROUP BY i.indicator_code
ORDER BY i.role, i.indicator_code;


-- name: q02_panel_regions
-- Главный срез для этапов 3–8: 20 регионов × годы, все показатели.
SELECT *
FROM v_panel_regions
ORDER BY region_id, year;


-- name: q03_panel_units
-- Сопоставимая панель (16 единиц × 2015–2024) для динамики и регрессии.
SELECT *
FROM v_panel_units
ORDER BY unit_id, year;


-- name: q04_income_dynamics
-- Доходы по единицам: место в рейтинге, рост к прошлому году и к 2015 г.,
-- отношение к среднему по стране, смена места после поправки на прожиточный минимум (H4).
WITH country AS (
    SELECT year, value AS income_kz
    FROM observations
    WHERE region_id = 0 AND indicator_code = 'income_pc'
),
ranked AS (
    SELECT u.unit_id,
           u.unit_name,
           u.year,
           u.income_pc,
           u.income_to_subsistence,
           RANK() OVER (PARTITION BY u.year ORDER BY u.income_pc DESC)             AS rank_nominal,
           RANK() OVER (PARTITION BY u.year ORDER BY u.income_to_subsistence DESC) AS rank_real,
           u.income_pc * 1.0 / LAG(u.income_pc) OVER w - 1                          AS growth_yoy,
           u.income_pc * 1.0 / FIRST_VALUE(u.income_pc) OVER w - 1                  AS growth_since_2015
    FROM v_panel_units AS u
    WINDOW w AS (PARTITION BY u.unit_id ORDER BY u.year)
)
SELECT r.*,
       r.rank_nominal - r.rank_real              AS rank_shift,   -- > 0: в реальном выражении регион выше
       ROUND(r.income_pc / c.income_kz, 3)       AS ratio_to_country
FROM ranked AS r
JOIN country AS c ON c.year = r.year
ORDER BY r.year, r.rank_nominal;


-- name: q05_inequality_by_year
-- Неравенство между регионами по годам (H3, σ-конвергенция):
-- разрыв max/min и коэффициент вариации номинальных и реальных доходов.
WITH stats AS (
    SELECT year,
           COUNT(*)                                   AS n_units,
           AVG(income_pc)                             AS mean_income,
           AVG(income_pc * income_pc)                 AS mean_sq_income,
           MAX(income_pc)                             AS max_income,
           MIN(income_pc)                             AS min_income,
           AVG(income_to_subsistence)                 AS mean_real,
           AVG(income_to_subsistence * income_to_subsistence) AS mean_sq_real,
           MAX(income_to_subsistence)                 AS max_real,
           MIN(income_to_subsistence)                 AS min_real
    FROM v_panel_units
    GROUP BY year
)
SELECT year,
       n_units,
       ROUND(mean_income)                                                    AS mean_income,
       ROUND(max_income / min_income, 2)                                     AS gap_max_min,
       ROUND(SQRT(mean_sq_income - mean_income * mean_income) / mean_income * 100, 1) AS cv_income_pct,
       ROUND(max_real / min_real, 2)                                         AS gap_real,
       ROUND(SQRT(mean_sq_real - mean_real * mean_real) / mean_real * 100, 1) AS cv_real_pct
FROM stats
ORDER BY year;


-- name: q06_cagr_by_unit
-- Среднегодовой темп роста (CAGR) доходов и зарплат за 2015–2024
-- и квартиль единицы по уровню доходов в 2015 г. (догоняют ли отстающие?).
WITH bounds AS (
    SELECT unit_id,
           MAX(CASE WHEN year = 2015 THEN income_pc END) AS income_2015,
           MAX(CASE WHEN year = 2024 THEN income_pc END) AS income_2024,
           MAX(CASE WHEN year = 2015 THEN wage END)      AS wage_2015,
           MAX(CASE WHEN year = 2024 THEN wage END)      AS wage_2024,
           AVG(migration_per1000)                        AS avg_migration
    FROM v_panel_units
    GROUP BY unit_id
)
SELECT u.unit_name,
       u.macro_region,
       u.is_resource,
       b.income_2015,
       b.income_2024,
       ROUND((POWER(b.income_2024 / b.income_2015, 1.0 / 9) - 1) * 100, 2) AS cagr_income_pct,
       ROUND((POWER(b.wage_2024 / b.wage_2015, 1.0 / 9) - 1) * 100, 2)     AS cagr_wage_pct,
       NTILE(4) OVER (ORDER BY b.income_2015 DESC)                         AS income_quartile_2015,
       ROUND(b.avg_migration, 2)                                           AS avg_migration_per1000
FROM bounds AS b
JOIN regions AS u ON u.region_id = b.unit_id
ORDER BY cagr_income_pct DESC;


-- name: q07_resource_vs_other
-- Сырьевые регионы против остальных по годам (подготовка к H2).
-- Средние взвешены по населению, чтобы маленький регион не весил как большой.
SELECT year,
       CASE WHEN is_resource = 1 THEN 'Сырьевые' ELSE 'Остальные' END       AS grp,
       COUNT(*)                                                             AS n_regions,
       ROUND(SUM(income_pc * population) / SUM(population))                 AS income_pc,
       ROUND(SUM(income_to_subsistence * population) / SUM(population), 2)  AS income_to_subsistence,
       ROUND(SUM(poverty * population) / SUM(population), 2)                AS poverty,
       ROUND(SUM(migration_per1000 * population) / SUM(population), 2)      AS migration_per1000,
       ROUND(SUM(life_expectancy * population) / SUM(population), 2)        AS life_expectancy
FROM v_panel_regions
GROUP BY year, is_resource
ORDER BY year, grp DESC;


-- name: q08_latest_snapshot
-- Срез по 20 регионам за последний полный год — для карты (join с GeoJSON по name_en).
WITH latest AS (
    SELECT MAX(year) AS year
    FROM v_panel_regions
    WHERE income_pc IS NOT NULL AND poverty IS NOT NULL
)
SELECT p.*,
       RANK() OVER (ORDER BY p.income_pc DESC)            AS rank_income,
       RANK() OVER (ORDER BY p.income_to_subsistence DESC) AS rank_real_income
FROM v_panel_regions AS p
JOIN latest AS l ON l.year = p.year
ORDER BY rank_income;


-- name: q09_check_doctors
-- Контроль качества: наш расчёт врачей на 10 тыс. против официального показателя БНС.
-- Расхождение > 1 означает проблему с населением или с самим рядом.
SELECT p.region,
       p.year,
       p.doctors_per10k                                AS calc,
       o.value                                         AS official,
       ROUND(p.doctors_per10k - o.value, 1)            AS diff
FROM v_panel_regions AS p
JOIN observations AS o
  ON o.region_id = p.region_id
 AND o.year = p.year
 AND o.indicator_code = 'doctors_per10k'
WHERE o.value IS NOT NULL
ORDER BY ABS(p.doctors_per10k - o.value) DESC;


-- name: q10_check_units_vs_country
-- Контроль качества: сумма 16 единиц должна совпадать с итогом по стране.
WITH units AS (
    SELECT year,
           SUM(population)                          AS population,
           SUM(investments_pc * population) / 1000  AS investments_thous,
           SUM(grp_pc * population) / 1000000       AS grp_mln
    FROM v_panel_units
    GROUP BY year
),
kz AS (
    SELECT year,
           MAX(CASE WHEN indicator_code = 'population'  THEN value END) AS population,
           MAX(CASE WHEN indicator_code = 'investments' THEN value END) AS investments_thous,
           MAX(CASE WHEN indicator_code = 'grp'         THEN value END) AS grp_mln
    FROM observations
    WHERE region_id = 0
    GROUP BY year
)
SELECT u.year,
       ROUND(u.population / k.population * 100, 2)               AS population_pct,
       ROUND(u.investments_thous / k.investments_thous * 100, 2)  AS investments_pct,
       ROUND(u.grp_mln / k.grp_mln * 100, 2)                      AS grp_pct
FROM units AS u
JOIN kz AS k ON k.year = u.year
ORDER BY u.year;
