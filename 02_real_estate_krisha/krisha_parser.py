"""
Парсер объявлений krisha.kz для пет-проекта «Окупаемость квартир под аренду».

Собирает объявления о ПРОДАЖЕ и АРЕНДЕ квартир по выбранным городам.
Этап 1 (быстро): карточки из списка — цена, комнаты, площадь, этаж, адрес, ссылка.
Этап 2 (--details, дольше): страница объявления — год постройки, тип дома,
          состояние, санузел, координаты и т.п.

Запуск:
    pip install -r requirements.txt
    python krisha_parser.py --cities astana --pages 2            # пробный запуск
    python krisha_parser.py --cities astana --pages 150          # все списки
    python krisha_parser.py --details-only                       # детали (можно прерывать)

Результат: папка data/raw/ с файлами listings_YYYYMMDD.csv и details.jsonl

Этика: личный некоммерческий проект, пауза между запросами,
телефоны и имена продавцов НЕ собираются.
"""
import argparse
import functools
import csv
import json
import random
import re
import time
from datetime import datetime
from pathlib import Path

import requests
from bs4 import BeautifulSoup

BASE = "https://krisha.kz"
DEALS = {"sale": "prodazha", "rent": "arenda"}
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
    "Accept-Language": "ru-RU,ru;q=0.9",
}
OUT_DIR = Path("data/raw")
DEBUG_DIR = Path("data/debug")

# вывод сразу, без буферизации — чтобы в Jupyter прогресс был виден по ходу работы
print = functools.partial(print, flush=True)


def fmt_time(sec):
    sec = int(sec)
    h, m = divmod(sec // 60, 60)
    return f"{h} ч {m:02d} мин" if h else f"{m} мин {sec % 60:02d} с"


def progress(done, total, started, extra=""):
    """[████░░░░░░] 40% | 60/150 | прошло 5 мин | осталось ~7 мин"""
    share = done / total if total else 0
    bar = "█" * int(share * 20) + "░" * (20 - int(share * 20))
    elapsed = time.time() - started
    eta = elapsed / done * (total - done) if done else 0
    return (f"[{bar}] {share:4.0%} | {done}/{total} | прошло {fmt_time(elapsed)} | "
            f"осталось ~{fmt_time(eta)}{(' | ' + extra) if extra else ''}")



# ---------- утилиты ----------
def polite_sleep(a=1.0, b=2.5):
    time.sleep(random.uniform(a, b))


class Blocked(Exception):
    """Сайт включил защиту от ботов — дальше запрашивать бессмысленно."""


def get(session, url, params=None, retries=3):
    for attempt in range(1, retries + 1):
        try:
            r = session.get(url, params=params, headers=HEADERS, timeout=20)
            if r.status_code == 200:
                return r.text
            if r.status_code == 404:
                return None
            if r.status_code in (403, 429, 468):
                raise Blocked(f"HTTP {r.status_code}: krisha ограничила доступ. Остановка, "
                              "чтобы не продлевать блокировку. Попробуй снова через несколько часов.")
            print(f"  ! HTTP {r.status_code} на {r.url}, попытка {attempt}")
        except requests.RequestException as e:
            print(f"  ! {e.__class__.__name__}, попытка {attempt}")
        time.sleep(5 * attempt)
    return None


def to_int(text):
    if not text:
        return None
    digits = re.sub(r"[^\d]", "", text)
    return int(digits) if digits else None


def parse_title(title):
    """'2-комнатная квартира · 60 м² · 5/9 этаж' -> rooms, area, floor, floors_total"""
    rooms = area = floor = floors_total = None
    m = re.search(r"(\d+)-комнатн", title)
    if m:
        rooms = int(m.group(1))
    m = re.search(r"([\d.,]+)\s*м²", title)
    if m:
        area = float(m.group(1).replace(",", "."))
    m = re.search(r"(\d+)\s*/\s*(\d+)\s*этаж", title)
    if m:
        floor, floors_total = int(m.group(1)), int(m.group(2))
    else:
        m = re.search(r"(\d+)\s*этаж", title)
        if m:
            floor = int(m.group(1))
    return rooms, area, floor, floors_total


# ---------- этап 1: карточки ----------
def parse_list_page(html, city, deal):
    soup = BeautifulSoup(html, "lxml")
    rows = []
    for card in soup.select("div.a-card[data-id]"):
        title_el = card.select_one(".a-card__title")
        price_el = card.select_one(".a-card__price")
        addr_el = card.select_one(".a-card__subtitle")
        if not title_el:
            continue
        title = title_el.get_text(" ", strip=True)
        rooms, area, floor, floors_total = parse_title(title)
        href = title_el.get("href") or ""
        rows.append({
            "id": card.get("data-id"),
            "deal": deal,
            "city": city,
            "title": title,
            "price_kzt": to_int(price_el.get_text() if price_el else None),
            "rooms": rooms,
            "area_m2": area,
            "floor": floor,
            "floors_total": floors_total,
            "address": addr_el.get_text(" ", strip=True) if addr_el else None,
            "url": BASE + href if href.startswith("/") else href,
            "scraped_at": datetime.now().isoformat(timespec="seconds"),
        })
    return rows


def scrape_lists(session, cities, deals, max_pages):
    all_rows, seen = [], set()
    for city in cities:
        for deal in deals:
            url = f"{BASE}/{DEALS[deal]}/kvartiry/{city}/"
            print(f"\n== {'продажа' if deal == 'sale' else 'аренда'} / {city} "
                  f"(до {max_pages} страниц, ~20 объявлений на странице) ==")
            started = time.time()
            for page in range(1, max_pages + 1):
                params = {"page": page} if page > 1 else {}
                if deal == "rent":
                    params["das[rent.period]"] = 2  # только помесячная аренда, без посуточной
                try:
                    html = get(session, url, params=params or None)
                except Blocked as e:
                    print(f"  ⛔ {e}")
                    return all_rows
                if not html:
                    print(f"  страница {page}: нет ответа, стоп")
                    break
                rows = parse_list_page(html, city, deal)
                if page == 1 and not rows:
                    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
                    dbg = DEBUG_DIR / f"{deal}_{city}_page1.html"
                    dbg.write_text(html, encoding="utf-8")
                    print(f"  ! карточки не найдены — HTML сохранён в {dbg}. "
                          "Пришли этот файл, поправлю селекторы.")
                    break
                new = [r for r in rows if r["id"] not in seen]
                if not new:
                    print(f"  страница {page}: новых объявлений нет, стоп")
                    break
                seen.update(r["id"] for r in new)
                all_rows.extend(new)
                print("  " + progress(page, max_pages, started,
                                      f"страница {page}: +{len(new)}, всего собрано {len(all_rows)}"))
                polite_sleep()
    return all_rows


# ---------- этап 2: страница объявления ----------
def parse_detail(html):
    soup = BeautifulSoup(html, "lxml")
    info = {}
    # характеристики: блоки с data-name (flat.building, house.year, flat.renovation ...)
    for item in soup.select("[data-name]"):
        key = item.get("data-name")
        val_el = item.select_one(".offer__advert-short-info") or item.select_one("dd")
        if key and val_el:
            info[key] = val_el.get_text(" ", strip=True)
    # координаты и прочее из встроенного JSON window.data
    m = re.search(r"window\.data\s*=\s*(\{.*?\});\s*</script>", html, re.S)
    if m:
        try:
            data = json.loads(m.group(1))
            adv = data.get("advert", {}) or {}
            mp = adv.get("map", {}) or {}
            info["lat"] = mp.get("lat")
            info["lon"] = mp.get("lon")
            info["district_json"] = adv.get("addressTitle")
            info["photos_count"] = len(adv.get("photos", []) or [])
        except json.JSONDecodeError:
            pass
    # дата публикации/просмотры, если есть
    views = soup.select_one(".offer__views, #a-nb-views")
    if views:
        info["views"] = to_int(views.get_text())
    return info


DETAILS_PATH = OUT_DIR / "details.jsonl"


def scrape_details(session, rows, limit):
    """Заходит в каждое объявление. Пишет результат построчно в details.jsonl,
    поэтому при перезапуске уже скачанные объявления пропускаются."""
    DETAILS_PATH.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if DETAILS_PATH.exists():
        with open(DETAILS_PATH, encoding="utf-8") as f:
            done = {json.loads(line)["id"] for line in f if line.strip()}
    todo = [r for r in rows if r["id"] not in done]
    if limit:
        todo = todo[:limit]
    print(f"  уже скачано: {len(done)}, осталось: {len(todo)}")
    started = time.time()

    with open(DETAILS_PATH, "a", encoding="utf-8") as f:
        for i, r in enumerate(todo, 1):
            try:
                html = get(session, r["url"])
            except Blocked as e:
                print(f"\n  ⛔ {e}\n  Скачано в этот раз: {i - 1}. При следующем запуске продолжим с этого места.")
                return
            if html:
                d = parse_detail(html)
                d["id"] = r["id"]
                if not done and i == 1 and len(d) <= 1:
                    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
                    (DEBUG_DIR / "detail_example.html").write_text(html, encoding="utf-8")
                    print("  ! характеристики не распознаны — пример сохранён в "
                          "data/debug/detail_example.html, пришли его.")
                f.write(json.dumps(d, ensure_ascii=False) + "\n")
                f.flush()
            if i % 10 == 0 or i == len(todo):
                print("  " + progress(i, len(todo), started, f"всего в файле {len(done) + i}"))
            polite_sleep(1.5, 3.0)
    print(f"Детали сохранены -> {DETAILS_PATH}")


def save_csv(rows, path, fields=None):
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = fields or list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"Сохранено {len(rows)} строк -> {path}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--cities", nargs="+", default=["astana"])
    p.add_argument("--deals", nargs="+", default=["sale", "rent"], choices=list(DEALS))
    p.add_argument("--pages", type=int, default=100, help="макс. страниц на город/тип (≈20 объявлений на странице)")
    p.add_argument("--details", action="store_true", help="заходить в каждое объявление")
    p.add_argument("--details-only", action="store_true",
                   help="не собирать списки заново, а докачать детали по последнему listings_*.csv")
    p.add_argument("--details-limit", type=int, default=0, help="0 = все")
    a = p.parse_args()

    s = requests.Session()
    if a.details_only:
        files = sorted(OUT_DIR.glob("listings_*.csv"))
        if not files:
            print("Нет файла listings_*.csv — сначала запусти сбор списков.")
            return
        with open(files[-1], encoding="utf-8-sig") as f:
            rows = list(csv.DictReader(f))
        print(f"Беру объявления из {files[-1]} ({len(rows)} шт.)")
    else:
        stamp = datetime.now().strftime("%Y%m%d")
        rows = scrape_lists(s, a.cities, a.deals, a.pages)
        save_csv(rows, OUT_DIR / f"listings_{stamp}.csv")

    if (a.details or a.details_only) and rows:
        print("\n== детали объявлений ==")
        scrape_details(s, rows, a.details_limit)


if __name__ == "__main__":
    main()
