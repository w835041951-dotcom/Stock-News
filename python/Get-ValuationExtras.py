import json
import math
import sys
import time
from datetime import datetime, timedelta

import akshare as ak
import pandas as pd


def retry(fn, retries=3, delay=1.0):
    """Retry a callable up to `retries` times with exponential backoff."""
    last_err = None
    for i in range(retries):
        try:
            return fn()
        except Exception as e:
            last_err = e
            if i < retries - 1:
                time.sleep(delay * (i + 1))
    raise last_err


CERTIFICATES = [
    "证监会行业分类标准（2012）",
    "证监会行业分类标准",
]


def safe_float(value):
    try:
        if value is None:
            return None
        if isinstance(value, str) and not value.strip():
            return None
        num = float(value)
        if math.isnan(num) or math.isinf(num):
            return None
        return num
    except Exception:
        return None



def get_eps_series(code: str, years: int):
    df = retry(lambda: ak.stock_financial_abstract_ths(symbol=code, indicator="按年度"))
    year_col = "报告期"
    eps_col = "基本每股收益"
    if year_col not in df.columns or eps_col not in df.columns:
        return []

    work = df[[year_col, eps_col]].copy()
    work["Year"] = pd.to_numeric(work[year_col], errors="coerce")
    work["EPS"] = pd.to_numeric(work[eps_col], errors="coerce")
    work = work.dropna(subset=["Year", "EPS"])
    work["Year"] = work["Year"].astype(int)
    work = work.sort_values("Year", ascending=False)
    work = work.drop_duplicates(subset=["Year"], keep="first")
    work = work.head(max(3, years))
    return [
        {"Year": int(row.Year), "EPS": round(float(row.EPS), 4)}
        for row in work.itertuples(index=False)
    ]



def get_dividend_info(code: str, price: float):
    try:
        df = retry(lambda: ak.stock_dividend_cninfo(symbol=code))
    except Exception:
        return {
            "DividendPerShareTTM": None,
            "DividendYieldTTM": None,
            "DividendYears": 0,
            "DividendRecords": [],
        }

    if df is None or df.empty:
        return {
            "DividendPerShareTTM": None,
            "DividendYieldTTM": None,
            "DividendYears": 0,
            "DividendRecords": [],
        }

    date_candidates = [c for c in ["派息日", "实施方案公告日期", "除权日", "股权登记日"] if c in df.columns]
    work = df.copy()
    work["EventDate"] = pd.NaT
    for col in date_candidates:
        parsed = pd.to_datetime(work[col], errors="coerce")
        work["EventDate"] = work["EventDate"].fillna(parsed)

    if "派息比例" not in work.columns:
        return {
            "DividendPerShareTTM": None,
            "DividendYieldTTM": None,
            "DividendYears": 0,
            "DividendRecords": [],
        }

    work["CashPer10"] = pd.to_numeric(work["派息比例"], errors="coerce")
    work = work.dropna(subset=["CashPer10", "EventDate"])
    if work.empty:
        return {
            "DividendPerShareTTM": None,
            "DividendYieldTTM": None,
            "DividendYears": 0,
            "DividendRecords": [],
        }

    cutoff = pd.Timestamp(datetime.now() - timedelta(days=365))
    ttm = work[work["EventDate"] >= cutoff].copy()
    ttm["DividendPerShare"] = ttm["CashPer10"] / 10.0
    dividend_per_share = round(float(ttm["DividendPerShare"].sum()), 4) if not ttm.empty else None
    dividend_yield = round(dividend_per_share / price * 100.0, 2) if dividend_per_share and price > 0 else None

    records = []
    for row in ttm.sort_values("EventDate", ascending=False).head(5).itertuples(index=False):
        records.append(
            {
                "Date": row.EventDate.strftime("%Y-%m-%d"),
                "CashPer10": round(float(row.CashPer10), 4),
                "DividendPerShare": round(float(row.DividendPerShare), 4),
                "Report": str(getattr(row, "报告时间", "")) if hasattr(row, "报告时间") else "",
            }
        )

    years = sorted({d[:4] for d in [r["Date"] for r in records]})
    return {
        "DividendPerShareTTM": dividend_per_share,
        "DividendYieldTTM": dividend_yield,
        "DividendYears": len(years),
        "DividendRecords": records,
    }



def get_industry_info(code: str):
    try:
        df = retry(lambda: ak.stock_industry_change_cninfo(symbol=code))
    except Exception:
        return {
            "IndustryName": None,
            "IndustryLevel": None,
            "IndustryStandard": None,
            "IndustryDate": None,
            "IndustryStaticPEWeighted": None,
            "IndustryStaticPEMedian": None,
            "IndustryStaticPEAverage": None,
            "IndustrySampleCount": None,
        }

    if df is None or df.empty:
        return {
            "IndustryName": None,
            "IndustryLevel": None,
            "IndustryStandard": None,
            "IndustryDate": None,
            "IndustryStaticPEWeighted": None,
            "IndustryStaticPEMedian": None,
            "IndustryStaticPEAverage": None,
            "IndustrySampleCount": None,
        }

    work = df.copy()
    if "变更日期" in work.columns:
        work["变更日期"] = pd.to_datetime(work["变更日期"], errors="coerce")
        work = work.sort_values("变更日期", ascending=False)

    selected = None
    for cert in CERTIFICATES:
        subset = work[work["分类标准"] == cert] if "分类标准" in work.columns else pd.DataFrame()
        if not subset.empty:
            selected = subset.iloc[0]
            break
    if selected is None:
        selected = work.iloc[0]

    industry_name = None
    industry_level = None
    for col, level in [("行业中类", 2), ("行业大类", 1), ("行业门类", 0)]:
        if col in work.columns:
            value = selected.get(col)
            if pd.notna(value) and str(value).strip():
                industry_name = str(value).strip()
                industry_level = level
                break

    info = {
        "IndustryName": industry_name,
        "IndustryLevel": industry_level,
        "IndustryStandard": str(selected.get("分类标准", "")) if selected is not None else None,
        "IndustryDate": selected.get("变更日期").strftime("%Y-%m-%d") if selected is not None and pd.notna(selected.get("变更日期")) else None,
        "IndustryStaticPEWeighted": None,
        "IndustryStaticPEMedian": None,
        "IndustryStaticPEAverage": None,
        "IndustrySampleCount": None,
    }

    if not industry_name:
        return info

    today = datetime.now().date()
    last_error = None
    for offset in range(0, 10):
        qdate = (today - timedelta(days=offset)).strftime("%Y%m%d")
        try:
            pe_df = retry(lambda qd=qdate: ak.stock_industry_pe_ratio_cninfo(symbol="证监会行业分类", date=qd))
            if pe_df is None or pe_df.empty:
                continue
            match = pe_df[pe_df["行业名称"] == industry_name]
            if match.empty and industry_level is not None:
                match = pe_df[(pe_df["行业名称"] == industry_name) & (pd.to_numeric(pe_df["行业层级"], errors="coerce") == industry_level + 1)]
            if match.empty:
                continue
            row = match.iloc[0]
            info.update(
                {
                    "IndustryDate": str(row.get("变动日期", info["IndustryDate"]))[:10],
                    "IndustryStaticPEWeighted": safe_float(row.get("静态市盈率-加权平均")),
                    "IndustryStaticPEMedian": safe_float(row.get("静态市盈率-中位数")),
                    "IndustryStaticPEAverage": safe_float(row.get("静态市盈率-算术平均")),
                    "IndustrySampleCount": int(float(row.get("纳入计算公司数量", 0))) if safe_float(row.get("纳入计算公司数量")) is not None else None,
                }
            )
            return info
        except Exception as exc:
            last_error = exc
            continue

    return info



def get_historical_cape_info(code: str, eps_series, current_cape: float, years: int):
    try:
        df = retry(lambda: ak.stock_zh_a_hist(symbol=code, period="daily", start_date="19900101", end_date="20500101", adjust=""))
    except Exception:
        return {
            "HistoricalCapePercentile": None,
            "HistoricalCapeMedian": None,
            "HistoricalCapeMin": None,
            "HistoricalCapeMax": None,
            "HistoricalCapeSamples": [],
        }

    if df is None or df.empty or not eps_series:
        return {
            "HistoricalCapePercentile": None,
            "HistoricalCapeMedian": None,
            "HistoricalCapeMin": None,
            "HistoricalCapeMax": None,
            "HistoricalCapeSamples": [],
        }

    work = df[["日期", "收盘"]].copy()
    work["日期"] = pd.to_datetime(work["日期"], errors="coerce")
    work["收盘"] = pd.to_numeric(work["收盘"], errors="coerce")
    work = work.dropna(subset=["日期", "收盘"])
    if work.empty:
        return {
            "HistoricalCapePercentile": None,
            "HistoricalCapeMedian": None,
            "HistoricalCapeMin": None,
            "HistoricalCapeMax": None,
            "HistoricalCapeSamples": [],
        }

    work["Year"] = work["日期"].dt.year
    year_close = work.sort_values("日期").groupby("Year", as_index=False).tail(1)

    eps_map = {int(item["Year"]): float(item["EPS"]) for item in eps_series}
    samples = []
    available_years = sorted(eps_map)
    if not available_years:
        return {
            "HistoricalCapePercentile": None,
            "HistoricalCapeMedian": None,
            "HistoricalCapeMin": None,
            "HistoricalCapeMax": None,
            "HistoricalCapeSamples": [],
        }

    for row in year_close.itertuples(index=False):
        year = int(row.Year)
        usable = [eps_map[y] for y in available_years if y <= year]
        usable = usable[-years:]
        if len(usable) < 3:
            continue
        avg_eps = sum(usable) / len(usable)
        if avg_eps <= 0:
            continue
        cape = float(row.收盘) / avg_eps
        samples.append({
            "Year": year,
            "Close": round(float(row.收盘), 2),
            "AvgEPS": round(avg_eps, 4),
            "CAPE": round(cape, 2),
            "YearsUsed": len(usable),
        })

    if not samples:
        return {
            "HistoricalCapePercentile": None,
            "HistoricalCapeMedian": None,
            "HistoricalCapeMin": None,
            "HistoricalCapeMax": None,
            "HistoricalCapeSamples": [],
        }

    cape_values = sorted(float(item["CAPE"]) for item in samples)
    percentile = round(sum(1 for value in cape_values if value <= current_cape) / len(cape_values) * 100.0, 1)

    return {
        "HistoricalCapePercentile": percentile,
        "HistoricalCapeMedian": round(float(pd.Series(cape_values).median()), 2),
        "HistoricalCapeMin": round(float(min(cape_values)), 2),
        "HistoricalCapeMax": round(float(max(cape_values)), 2),
        "HistoricalCapeSamples": samples[-10:],
    }



def main():
    code = sys.argv[1].strip()
    years = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    price = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    current_cape = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    eps_series = get_eps_series(code, years)
    payload = {}
    payload.update(get_dividend_info(code, price))
    payload.update(get_industry_info(code))
    payload.update(get_historical_cape_info(code, eps_series, current_cape, years))
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
