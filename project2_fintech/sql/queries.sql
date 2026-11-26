-- =====================================================================
-- Проект: Аналитика выдач команды продаж (залоговые / беззалоговые займы)
-- СУБД: SQLite 3.25+ (оконные функции). Сборка БД: python src/build_db.py
-- Каждый запрос помечен «-- name: …» — ноутбук загружает их по имени.
-- Стиль: только CTE, без вложенных подзапросов.
-- =====================================================================


-- name: reconciliation
-- Сверка детализации с итогами исходного отчёта (JOIN + агрегаты).
-- Ожидаем 0 расхождений по количеству и сумме.
WITH detail AS (
    SELECT year, month, product,
           COUNT(*)        AS cnt,
           SUM(amount_kzt) AS amount_kzt
    FROM loans
    GROUP BY year, month, product
)
SELECT d.year, d.month, d.product,
       d.cnt, s.src_cnt,
       d.amount_kzt, s.src_amount_kzt,
       d.cnt - s.src_cnt                AS diff_cnt,
       d.amount_kzt - s.src_amount_kzt  AS diff_amount
FROM detail d
LEFT JOIN source_monthly s
       ON s.year = d.year AND s.month = d.month AND s.product = d.product
ORDER BY d.year, d.month, d.product;


-- name: monthly_kpi
-- Помесячные KPI по продуктам: объём, штуки, средний чек,
-- MoM и YoY через LAG, доля продукта в объёме месяца через оконный SUM.
WITH m AS (
    SELECT year, month,
           printf('%d-%02d', year, month)   AS ym,
           product,
           COUNT(*)                         AS cnt,
           SUM(amount_kzt)                  AS amount_kzt,
           ROUND(AVG(amount_kzt))           AS avg_ticket_kzt,
           COUNT(DISTINCT manager_id)       AS active_managers
    FROM loans
    GROUP BY year, month, product
)
SELECT ym, year, month, product, cnt, amount_kzt, avg_ticket_kzt, active_managers,
       ROUND(1.0 * amount_kzt / SUM(amount_kzt) OVER (PARTITION BY ym), 4)              AS share_in_month,
       LAG(amount_kzt, 1)  OVER (PARTITION BY product ORDER BY year, month)             AS amount_prev_month,
       LAG(amount_kzt, 12) OVER (PARTITION BY product ORDER BY year, month)             AS amount_same_month_ly,
       SUM(amount_kzt)     OVER (PARTITION BY product, year ORDER BY month)             AS amount_ytd
FROM m
ORDER BY year, month, product;


-- name: manager_month
-- Витрина «менеджер × месяц»: продуктивность, микс, стаж в команде, ранг в месяце.
-- LEFT JOIN со справочником помечает менеджеров, которых нет в справочнике.
WITH mm AS (
    SELECT manager_id, year, month,
           printf('%d-%02d', year, month)                                   AS ym,
           COUNT(*)                                                         AS cnt,
           SUM(amount_kzt)                                                  AS amount_kzt,
           SUM(CASE WHEN product = 'Залоговый займ' THEN 1 ELSE 0 END)      AS cnt_secured,
           SUM(CASE WHEN product = 'Беззалоговый займ' THEN 1 ELSE 0 END)   AS cnt_unsecured,
           ROUND(AVG(amount_kzt))                                           AS avg_ticket_kzt
    FROM loans
    GROUP BY manager_id, year, month
),
first_month AS (
    SELECT manager_id, MIN(year * 12 + month) AS first_idx
    FROM mm
    GROUP BY manager_id
)
SELECT mm.*,
       CASE WHEN g.manager_id IS NULL THEN 0 ELSE 1 END                     AS in_directory,
       (mm.year * 12 + mm.month) - f.first_idx + 1                          AS tenure_month,
       RANK() OVER (PARTITION BY mm.ym ORDER BY mm.amount_kzt DESC)         AS rank_in_month,
       ROUND(1.0 * mm.amount_kzt / SUM(mm.amount_kzt) OVER (PARTITION BY mm.ym), 4) AS share_of_team
FROM mm
JOIN first_month f   ON f.manager_id = mm.manager_id
LEFT JOIN managers g ON g.manager_id = mm.manager_id
ORDER BY mm.year, mm.month, mm.amount_kzt DESC;


-- name: manager_pareto
-- Концентрация объёма внутри года: ранг менеджера и накопленная доля (Парето).
WITH y AS (
    SELECT year, manager_id, COUNT(*) AS cnt, SUM(amount_kzt) AS amount_kzt
    FROM loans
    GROUP BY year, manager_id
)
SELECT year, manager_id, cnt, amount_kzt,
       RANK() OVER (PARTITION BY year ORDER BY amount_kzt DESC)                                  AS rnk,
       ROUND(1.0 * amount_kzt / SUM(amount_kzt) OVER (PARTITION BY year), 4)                     AS share,
       ROUND(1.0 * SUM(amount_kzt) OVER (PARTITION BY year ORDER BY amount_kzt DESC
                                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(amount_kzt) OVER (PARTITION BY year), 4)                                      AS cum_share
FROM y
ORDER BY year, rnk;


-- name: channel_mix
-- Откуда приходят залоговые сделки: канал/застройщик (JOIN со справочником нормализации).
WITH l AS (
    SELECT l.year, l.product, l.amount_kzt,
           COALESCE(d.channel, 'Не указано')   AS channel,
           COALESCE(d.developer, '—')          AS developer
    FROM loans l
    LEFT JOIN dim_source_product d ON d.source_product_raw = l.source_product_raw
),
agg AS (
    SELECT year, product, channel, developer,
           COUNT(*) AS cnt, SUM(amount_kzt) AS amount_kzt
    FROM l
    GROUP BY year, product, channel, developer
)
SELECT agg.*,
       ROUND(1.0 * cnt / SUM(cnt) OVER (PARTITION BY year, product), 4) AS share_cnt_in_year_product
FROM agg
ORDER BY year, product, cnt DESC;


-- name: manager_cohorts
-- Когорты менеджеров по месяцу первой выдачи: сколько из когорты активны
-- на N-м месяце и сколько выдают в среднем (retention + ramp-up).
WITH mm AS (
    SELECT manager_id, year * 12 + month AS idx, SUM(amount_kzt) AS amount_kzt, COUNT(*) AS cnt
    FROM loans
    GROUP BY manager_id, year, month
),
first_month AS (
    SELECT manager_id, MIN(idx) AS first_idx FROM mm GROUP BY manager_id
),
cohort AS (
    SELECT mm.manager_id,
           printf('%d-%02d', (f.first_idx - 1) / 12, (f.first_idx - 1) % 12 + 1) AS cohort_ym,
           mm.idx - f.first_idx + 1                                              AS tenure_month,
           mm.amount_kzt, mm.cnt
    FROM mm JOIN first_month f ON f.manager_id = mm.manager_id
)
SELECT cohort_ym, tenure_month,
       COUNT(DISTINCT manager_id)  AS active_managers,
       ROUND(AVG(cnt), 1)          AS avg_cnt,
       ROUND(AVG(amount_kzt))      AS avg_amount_kzt
FROM cohort
GROUP BY cohort_ym, tenure_month
ORDER BY cohort_ym, tenure_month;


-- name: repeat_clients
-- Повторные клиенты и кросс-продажа (клиент взял оба продукта).
-- Только внутри одного года: межгодовая связь Клиент_ID не подтверждена.
WITH c AS (
    SELECT year, client_id,
           COUNT(*)                                                       AS loans,
           COUNT(DISTINCT product)                                        AS products,
           COUNT(DISTINCT issue_date)                                     AS dates,
           SUM(amount_kzt)                                                AS amount_kzt
    FROM loans
    GROUP BY year, client_id
)
SELECT year,
       COUNT(*)                                                    AS clients,
       SUM(CASE WHEN loans > 1 THEN 1 ELSE 0 END)                  AS repeat_clients,
       SUM(CASE WHEN products = 2 THEN 1 ELSE 0 END)               AS cross_sell_clients,
       SUM(CASE WHEN products = 2 AND dates = 1 THEN 1 ELSE 0 END) AS cross_sell_same_day,
       ROUND(1.0 * SUM(amount_kzt) / COUNT(*))                     AS amount_per_client_kzt
FROM c
GROUP BY year
ORDER BY year;


-- name: day_of_month
-- Сезонность внутри месяца: доля выдач по декадам и в последние 5 дней месяца.
WITH d AS (
    SELECT year, product,
           CAST(strftime('%d', issue_date) AS INTEGER)                               AS dom,
           CAST(strftime('%d', date(issue_date, 'start of month', '+1 month', '-1 day')) AS INTEGER) AS last_dom,
           CAST(strftime('%w', issue_date) AS INTEGER)                               AS dow,
           amount_kzt
    FROM loans
    WHERE date_quality NOT LIKE 'Условн%' AND date_quality NOT LIKE 'Смоделир%'
)
SELECT product,
       CASE WHEN dom <= 10 THEN '1-10' WHEN dom <= 20 THEN '11-20' ELSE '21-31' END AS decade,
       COUNT(*)                                                   AS cnt,
       SUM(CASE WHEN last_dom - dom < 5 THEN 1 ELSE 0 END)        AS cnt_last5days,
       ROUND(1.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY product), 4) AS share
FROM d
GROUP BY product, decade
ORDER BY product, decade;
