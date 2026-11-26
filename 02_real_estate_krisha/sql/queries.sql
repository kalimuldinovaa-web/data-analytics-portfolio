-- =====================================================================
--  Этап 2. SQL: квартиры в Астане (krisha.kz) — продажа и аренда
--  База: data/krisha.db (SQLite 3.25+, нужны оконные функции)
--  Таблицы:
--    listings  — объявления (deal = 'sale' | 'rent')
--    districts — справочник районов: район -> берег
--  Каждый запрос начинается с метки "-- name: ...".
-- =====================================================================


-- name: create_view_flats
-- Базовое представление: только правдоподобные объявления + расчётные поля.
-- Фильтры: площадь 12–400 м², аренда от 50 тыс. ₸/мес (дешевле — посуточная),
-- продажа от 5 млн ₸.
DROP VIEW IF EXISTS v_flats;
CREATE VIEW v_flats AS
SELECT l.listing_id,
       l.deal,
       COALESCE(l.district, 'Не указан')                     AS district,
       COALESCE(d.bank, 'Не указан')                         AS bank,
       CASE WHEN l.rooms >= 4 THEN 4 ELSE l.rooms END        AS rooms_grp,   -- 4 = «4 и больше»
       l.rooms,
       l.area_m2,
       l.floor,
       l.floors_total,
       CASE
           WHEN l.floor IS NULL OR l.floors_total IS NULL THEN 'Не указан'
           WHEN l.floor = 1                                THEN 'Первый'
           WHEN l.floor = l.floors_total                   THEN 'Последний'
           ELSE 'Средний'
       END                                                   AS floor_type,
       CASE
           WHEN l.floors_total >= 13 THEN 'Высотка (13+)'
           WHEN l.floors_total >= 6  THEN 'Средняя (6–12)'
           WHEN l.floors_total >= 1  THEN 'Малоэтажка (до 5)'
       END                                                   AS building_height,
       l.price_kzt,
       ROUND(l.price_kzt / l.area_m2, 0)                     AS price_per_m2
FROM listings l
LEFT JOIN districts d ON d.district = l.district
WHERE l.area_m2 BETWEEN 12 AND 400
  AND ((l.deal = 'rent' AND l.price_kzt >= 50000)
    OR (l.deal = 'sale' AND l.price_kzt >= 5000000));


-- name: overview_by_district
-- Объём предложения и медианная цена за м² по районам: отдельно продажа и аренда.
-- В SQLite нет MEDIAN, поэтому медиану считаем через ROW_NUMBER и COUNT.
WITH ranked AS (
    SELECT deal, district, bank, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY deal, district ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY deal, district)                       AS cnt
    FROM v_flats
)
SELECT deal,
       district,
       bank,
       MAX(cnt)                                                 AS listings,
       ROUND(100.0 * MAX(cnt) / SUM(MAX(cnt)) OVER (PARTITION BY deal), 1) AS share_pct,
       ROUND(AVG(price_per_m2), 0)                              AS median_price_per_m2
FROM ranked
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
GROUP BY deal, district, bank
ORDER BY deal, listings DESC;


-- name: segment_medians
-- Медианы по сегменту «район × комнаты»: цена за м² продажи и аренды.
WITH ranked AS (
    SELECT deal, district, bank, rooms_grp, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY deal, district, rooms_grp ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY deal, district, rooms_grp)                       AS cnt
    FROM v_flats
    WHERE district <> 'Не указан'
)
SELECT deal, district, bank, rooms_grp,
       MAX(cnt)                    AS n,
       ROUND(AVG(price_per_m2), 0) AS median_price_per_m2
FROM ranked
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
GROUP BY deal, district, bank, rooms_grp
ORDER BY district, rooms_grp, deal;


-- name: yield_by_segment
-- Доходность и окупаемость по сегментам: соединяем медианы продажи и аренды.
-- Валовая доходность = аренда за м² × 12 / цена за м².
-- Окупаемость (лет) = цена за м² / (аренда за м² × 12).
-- Сегменты, где меньше 10 объявлений продажи или аренды, не показываем.
WITH ranked AS (
    SELECT deal, district, bank, rooms_grp, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY deal, district, rooms_grp ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY deal, district, rooms_grp)                       AS cnt
    FROM v_flats
    WHERE district <> 'Не указан'
),
med AS (
    SELECT deal, district, bank, rooms_grp, MAX(cnt) AS n, AVG(price_per_m2) AS med_ppm2
    FROM ranked
    WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
    GROUP BY deal, district, bank, rooms_grp
),
seg AS (
    SELECT s.district, s.bank, s.rooms_grp,
           s.n        AS n_sale,
           r.n        AS n_rent,
           s.med_ppm2 AS sale_ppm2,
           r.med_ppm2 AS rent_ppm2
    FROM med s
    JOIN med r
      ON r.district = s.district AND r.rooms_grp = s.rooms_grp AND r.deal = 'rent'
    WHERE s.deal = 'sale'
      AND s.n >= 10 AND r.n >= 10
)
SELECT district,
       bank,
       rooms_grp,
       n_sale,
       n_rent,
       ROUND(sale_ppm2, 0)                                     AS sale_price_per_m2,
       ROUND(rent_ppm2, 0)                                     AS rent_per_m2_month,
       ROUND(100.0 * rent_ppm2 * 12 / sale_ppm2, 2)            AS gross_yield_pct,
       ROUND(sale_ppm2 / (rent_ppm2 * 12), 1)                  AS payback_years,
       RANK() OVER (ORDER BY rent_ppm2 * 12 / sale_ppm2 DESC)  AS yield_rank
FROM seg
ORDER BY yield_rank;


-- name: listing_yield
-- Оценка доходности КАЖДОЙ квартиры на продажу: аренда за м² берётся медианой
-- её сегмента «район × комнаты» (аренда и продажа — разные квартиры).
-- Эта таблица — основа для гипотез H1 и H2 и для этапа 5.
WITH rent_ranked AS (
    SELECT district, rooms_grp, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY district, rooms_grp ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY district, rooms_grp)                       AS cnt
    FROM v_flats
    WHERE deal = 'rent' AND district <> 'Не указан'
),
rent_med AS (
    SELECT district, rooms_grp, MAX(cnt) AS n_rent, AVG(price_per_m2) AS rent_ppm2
    FROM rent_ranked
    WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
    GROUP BY district, rooms_grp
    HAVING MAX(cnt) >= 10
)
SELECT f.listing_id,
       f.district,
       f.bank,
       f.rooms,
       f.rooms_grp,
       f.area_m2,
       f.floor,
       f.floors_total,
       f.floor_type,
       f.building_height,
       f.price_kzt,
       f.price_per_m2,
       ROUND(r.rent_ppm2 * f.area_m2, -3)                    AS est_rent_month,
       ROUND(100.0 * r.rent_ppm2 * f.area_m2 * 12 / f.price_kzt, 2) AS gross_yield_pct,
       ROUND(f.price_kzt / (r.rent_ppm2 * f.area_m2 * 12), 1)       AS payback_years
FROM v_flats f
JOIN rent_med r ON r.district = f.district AND r.rooms_grp = f.rooms_grp
WHERE f.deal = 'sale';


-- name: h1_rooms_yield
-- К гипотезе H1: доходность по числу комнат (медиана и квартили).
WITH ly AS (
    SELECT f.rooms_grp, f.district,
           100.0 * r.rent_ppm2 * 12 / f.price_per_m2 AS yield_pct
    FROM v_flats f
    JOIN (
        SELECT district, rooms_grp, AVG(price_per_m2) AS rent_ppm2
        FROM (
            SELECT district, rooms_grp, price_per_m2,
                   ROW_NUMBER() OVER (PARTITION BY district, rooms_grp ORDER BY price_per_m2) AS rn,
                   COUNT(*)     OVER (PARTITION BY district, rooms_grp)                       AS cnt
            FROM v_flats WHERE deal = 'rent' AND district <> 'Не указан'
        )
        WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2) AND cnt >= 10
        GROUP BY district, rooms_grp
    ) r ON r.district = f.district AND r.rooms_grp = f.rooms_grp
    WHERE f.deal = 'sale'
),
ranked AS (
    SELECT rooms_grp, yield_pct,
           ROW_NUMBER() OVER (PARTITION BY rooms_grp ORDER BY yield_pct) AS rn,
           COUNT(*)     OVER (PARTITION BY rooms_grp)                    AS cnt
    FROM ly
)
SELECT rooms_grp,
       MAX(cnt)                                                            AS n,
       ROUND(AVG(CASE WHEN rn = CAST(cnt * 0.25 AS INT) + 1 THEN yield_pct END), 2) AS q1_yield,
       ROUND(AVG(CASE WHEN rn IN ((cnt + 1) / 2, (cnt + 2) / 2) THEN yield_pct END), 2) AS median_yield,
       ROUND(AVG(CASE WHEN rn = CAST(cnt * 0.75 AS INT) + 1 THEN yield_pct END), 2) AS q3_yield
FROM ranked
GROUP BY rooms_grp
ORDER BY rooms_grp;


-- name: h2_bank_comparison
-- К гипотезе H2: левый и правый берег — цена за м² продажи и аренды
-- и итоговая валовая доходность по медианам.
WITH ranked AS (
    SELECT deal, bank, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY deal, bank ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY deal, bank)                       AS cnt
    FROM v_flats
    WHERE bank <> 'Не указан'
),
med AS (
    SELECT deal, bank, MAX(cnt) AS n, AVG(price_per_m2) AS med_ppm2
    FROM ranked
    WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
    GROUP BY deal, bank
)
SELECT s.bank,
       s.n                                          AS n_sale,
       r.n                                          AS n_rent,
       ROUND(s.med_ppm2, 0)                         AS sale_price_per_m2,
       ROUND(r.med_ppm2, 0)                         AS rent_per_m2_month,
       ROUND(100.0 * r.med_ppm2 * 12 / s.med_ppm2, 2) AS gross_yield_pct,
       ROUND(s.med_ppm2 / (r.med_ppm2 * 12), 1)     AS payback_years
FROM med s
JOIN med r ON r.bank = s.bank AND r.deal = 'rent'
WHERE s.deal = 'sale'
ORDER BY gross_yield_pct DESC;


-- name: h3_floor_discount
-- К гипотезе H3: медианная цена за м² по типу этажа и отклонение от средних этажей.
-- Сравниваем внутри одного района и числа комнат, а потом усредняем,
-- чтобы разница не объяснялась тем, что на первых этажах чаще старые дома.
WITH ranked AS (
    SELECT district, rooms_grp, floor_type, price_per_m2,
           ROW_NUMBER() OVER (PARTITION BY district, rooms_grp, floor_type ORDER BY price_per_m2) AS rn,
           COUNT(*)     OVER (PARTITION BY district, rooms_grp, floor_type)                       AS cnt
    FROM v_flats
    WHERE deal = 'sale' AND floor_type <> 'Не указан' AND district <> 'Не указан'
),
med AS (
    SELECT district, rooms_grp, floor_type, MAX(cnt) AS n, AVG(price_per_m2) AS med_ppm2
    FROM ranked
    WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
    GROUP BY district, rooms_grp, floor_type
),
vs_middle AS (
    SELECT m.floor_type, m.n,
           100.0 * (m.med_ppm2 - mid.med_ppm2) / mid.med_ppm2 AS diff_pct
    FROM med m
    JOIN med mid
      ON mid.district = m.district AND mid.rooms_grp = m.rooms_grp AND mid.floor_type = 'Средний'
    WHERE m.floor_type <> 'Средний' AND m.n >= 5
)
SELECT floor_type,
       COUNT(*)                                AS segments,
       SUM(n)                                  AS listings,
       ROUND(SUM(diff_pct * n) / SUM(n), 1)    AS weighted_diff_vs_middle_pct
FROM vs_middle
GROUP BY floor_type;


-- name: budget_segments
-- Что можно купить с бюджетом клиентов агентства (20–50 млн ₸):
-- распределение по ценовым корзинам и доля объявлений в каждом районе.
SELECT CASE
           WHEN price_kzt < 20000000 THEN '1) до 20 млн'
           WHEN price_kzt < 35000000 THEN '2) 20–35 млн'
           WHEN price_kzt < 50000000 THEN '3) 35–50 млн'
           ELSE                           '4) 50 млн и выше'
       END                                                   AS budget,
       district,
       COUNT(*)                                              AS listings,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY
           CASE WHEN price_kzt < 20000000 THEN 1 WHEN price_kzt < 35000000 THEN 2
                WHEN price_kzt < 50000000 THEN 3 ELSE 4 END), 1) AS share_in_budget_pct
FROM v_flats
WHERE deal = 'sale'
GROUP BY budget, district
ORDER BY budget, listings DESC;


-- name: cheap_vs_segment
-- Предварительный поиск «недооценённых»: объявления, у которых цена за м²
-- в нижних 10% своего сегмента «район × комнаты» (оконная функция PERCENT_RANK).
-- Полноценная модель справедливой цены — на этапе 6.
WITH pr AS (
    SELECT listing_id, district, rooms, area_m2, floor, floors_total, price_kzt, price_per_m2,
           PERCENT_RANK() OVER (PARTITION BY district, rooms_grp ORDER BY price_per_m2) AS pct_rank,
           COUNT(*)       OVER (PARTITION BY district, rooms_grp)                       AS seg_size
    FROM v_flats
    WHERE deal = 'sale' AND district <> 'Не указан'
)
SELECT *
FROM pr
WHERE pct_rank <= 0.10 AND seg_size >= 30
ORDER BY district, pct_rank
LIMIT 50;
