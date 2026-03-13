#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Helper: fetch long-history annual EPS for an A-share via akshare.
Usage: python Get-EpsSeries.py <code_6digit> [years]
Output: JSON array [{"Year":2024,"EPS":0.35}, ...]  sorted descending
"""
import sys, json
sys.stdout.reconfigure(encoding='utf-8')

import akshare as ak
import pandas as pd

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: Get-EpsSeries.py <code> [years]"}))
        sys.exit(1)

    code = sys.argv[1].strip().upper().lstrip("SHZ").zfill(6)
    years = int(sys.argv[2]) if len(sys.argv) >= 3 else 10

    try:
        df = ak.stock_financial_abstract_ths(symbol=code, indicator="按年度")
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

    if "基本每股收益" not in df.columns or "报告期" not in df.columns:
        print(json.dumps({"error": "Unexpected columns: " + str(df.columns.tolist())}))
        sys.exit(1)

    df["Year"] = pd.to_numeric(df["报告期"], errors="coerce")
    df["EPS"] = pd.to_numeric(df["基本每股收益"], errors="coerce")
    df = df.dropna(subset=["Year", "EPS"])
    df = df.sort_values("Year", ascending=False).head(years)

    result = [{"Year": int(r["Year"]), "EPS": round(float(r["EPS"]), 4)}
              for _, r in df.iterrows()]
    print(json.dumps(result))

if __name__ == "__main__":
    main()
