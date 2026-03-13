import argparse
import json
import random
import ssl
import time
import urllib.request
from pathlib import Path

ssl._create_default_https_context = ssl._create_unverified_context

HEADERS = {
    "User-Agent": "Mozilla/5.0",
    "Referer": "https://quote.eastmoney.com/",
    "Accept": "application/json,text/plain,*/*",
}

INDUSTRY_URL = (
    "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=140&po=1&np=1"
    "&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3"
    "&fs=m:90+t:2&fields=f2,f3,f4,f12,f14"
)
CONCEPT_URL = (
    "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=180&po=1&np=1"
    "&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3"
    "&fs=m:90+t:3&fields=f2,f3,f4,f12,f14"
)

THEME_PRESETS = {
    "main12": {
        "industry": {"储能", "风电整机", "风电设备", "煤化工", "动力煤", "煤炭", "其他化学纤维"},
        "concept": {"碳纤维", "绿色电力", "煤化工概念"},
    },
    "energy": {
        "industry": {"储能", "风电整机", "风电设备", "煤化工", "动力煤", "煤炭"},
        "concept": {"绿色电力", "煤化工概念"},
    },
    "fiber": {
        "industry": {"其他化学纤维"},
        "concept": {"碳纤维"},
    },
}


def get_json(url: str, retry: int = 4):
    for idx in range(retry):
        try:
            nonce = f"_={int(time.time()*1000)}{random.randint(100,999)}"
            request_url = f"{url}&{nonce}" if "?" in url else f"{url}?{nonce}"
            req = urllib.request.Request(request_url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=20) as response:
                return json.loads(response.read().decode("utf-8", errors="ignore"))
        except Exception:
            if idx == retry - 1:
                return None
            time.sleep(1.2 * (idx + 1))
    return None


def is_main_board(code: str) -> bool:
    return len(code) == 6 and code.startswith(("600", "601", "603", "605", "000", "001", "002", "300"))


def secid(code: str) -> str:
    return ("1." if code.startswith("6") else "0.") + code


def get_target_sectors(industry_keys: set[str], concept_keys: set[str]):
    results = []
    ind_data = get_json(INDUSTRY_URL) or {}
    con_data = get_json(CONCEPT_URL) or {}

    for item in (ind_data.get("data") or {}).get("diff") or []:
        name = str(item.get("f14", ""))
        if name in industry_keys:
            results.append({
                "code": str(item.get("f12", "")),
                "name": name,
                "type": "行业",
                "change": float(item.get("f3") or 0),
            })

    for item in (con_data.get("data") or {}).get("diff") or []:
        name = str(item.get("f14", ""))
        if name in concept_keys:
            results.append({
                "code": str(item.get("f12", "")),
                "name": name,
                "type": "概念",
                "change": float(item.get("f3") or 0),
            })

    return results


def get_sector_stocks(sector_code: str, limit: int = 120):
    url = (
        "https://push2.eastmoney.com/api/qt/clist/get?pn=1"
        f"&pz={limit}&po=1&np=1"
        "&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3"
        f"&fs=b:{sector_code}&fields=f2,f3,f4,f5,f6,f12,f14"
    )
    data = get_json(url) or {}
    stocks = []

    for item in (data.get("data") or {}).get("diff") or []:
        code = str(item.get("f12", ""))
        if not is_main_board(code):
            continue
        stocks.append({
            "code": code,
            "name": str(item.get("f14", "")),
            "price": float(item.get("f2") or 0),
            "today_chg": float(item.get("f3") or 0),
            "amount": float(item.get("f6") or 0),
        })

    return stocks


def get_kline_metrics(code: str):
    start = time.strftime("%Y") + "0101"
    url = (
        "https://push2his.eastmoney.com/api/qt/stock/kline/get"
        f"?secid={secid(code)}&fields1=f1,f2,f3&fields2=f51,f52,f53"
        f"&klt=101&fqt=0&beg={start}&end=20500101&lmt=90"
    )
    data = get_json(url) or {}
    klines = (data.get("data") or {}).get("klines") or []

    closes = []
    for row in klines:
        parts = row.split(",")
        if len(parts) >= 3:
            try:
                closes.append(float(parts[2]))
            except Exception:
                pass

    if len(closes) < 25:
        return None

    latest = closes[-1]
    high60 = max(closes[-60:]) if len(closes) >= 60 else max(closes)
    low60 = min(closes[-60:]) if len(closes) >= 60 else min(closes)
    week_base = closes[-6] if len(closes) >= 6 else closes[0]
    month_base = closes[-23] if len(closes) >= 23 else closes[0]
    pos60 = (latest - low60) / (high60 - low60) * 100 if high60 > low60 else 50.0

    return {
        "price": round(latest, 2),
        "week_chg": round((latest - week_base) / week_base * 100, 2) if week_base else 0,
        "month_chg": round((latest - month_base) / month_base * 100, 2) if month_base else 0,
        "pos_pct_60": round(pos60, 2),
        "from_high_60": round((latest - high60) / high60 * 100, 2) if high60 else 0,
    }


def screen_hot_low(topn: int, preset: str):
    keys = THEME_PRESETS[preset]
    sectors = get_target_sectors(keys["industry"], keys["concept"])

    pool = {}
    for sector in sectors:
        for stock in get_sector_stocks(sector["code"], limit=120):
            target = pool.setdefault(
                stock["code"],
                {
                    "code": stock["code"],
                    "name": stock["name"],
                    "price": stock["price"],
                    "today_chg": stock["today_chg"],
                    "amount": stock["amount"],
                    "themes": [],
                },
            )
            target["themes"].append(sector["name"])
            target["amount"] = max(target["amount"], stock["amount"])
            target["today_chg"] = stock["today_chg"]
            target["price"] = stock["price"]

    rows = []
    for stock in pool.values():
        metrics = get_kline_metrics(stock["code"])
        if not metrics:
            continue
        rows.append(
            {
                "Code": stock["code"],
                "Name": stock["name"],
                "Price": metrics["price"],
                "TodayChg": stock["today_chg"],
                "WeekChg": metrics["week_chg"],
                "MonthChg": metrics["month_chg"],
                "PosPct60": metrics["pos_pct_60"],
                "FromHigh60": metrics["from_high_60"],
                "AmountYi": round(stock["amount"] / 1e8, 2),
                "Themes": " / ".join(sorted(set(stock["themes"]))),
            }
        )

    rows.sort(key=lambda x: (x["PosPct60"], x["FromHigh60"], -x["AmountYi"]))

    return {
        "Preset": preset,
        "GeneratedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
        "SectorCount": len(sectors),
        "CandidateCount": len(rows),
        "Rows": rows[:topn],
    }


def parse_args():
    parser = argparse.ArgumentParser(description="筛选热点主线中的相对低位A股主板股票")
    parser.add_argument("--topn", type=int, default=20, help="返回数量，默认 20")
    parser.add_argument(
        "--preset",
        choices=sorted(THEME_PRESETS.keys()),
        default="main12",
        help="主题预设：main12/energy/fiber",
    )
    parser.add_argument(
        "--out",
        default="",
        help="可选：把结果写到 JSON 文件，例如 stock-news/temp/hot-low.json",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    result = screen_hot_low(args.topn, args.preset)
    payload = json.dumps(result, ensure_ascii=False, indent=2)

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(payload, encoding="utf-8")
        print(f"DONE: wrote {len(result['Rows'])} rows to {out_path}")

    print(payload)


if __name__ == "__main__":
    main()
