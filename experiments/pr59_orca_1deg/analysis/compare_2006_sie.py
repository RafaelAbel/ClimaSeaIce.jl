#!/usr/bin/env python3
"""Compare 2006 model Arctic sea-ice extent with NSIDC Sea Ice Index v4."""

from __future__ import annotations

import argparse
import csv
import os
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import gettempdir

os.environ.setdefault("MPLCONFIGDIR", str(Path(gettempdir()) / "mplconfig-pr59-orca-sie"))
os.environ.setdefault("XDG_CACHE_HOME", str(Path(gettempdir()) / "xdg-cache-pr59-orca-sie"))
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nsidc-dir", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--reicing", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--figure", type=Path, required=True)
    return parser.parse_args()


def model_monthly_means(path: Path) -> dict[int, float]:
    groups: dict[int, list[float]] = defaultdict(list)
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            day = float(row["day"])
            if day >= 365:
                continue
            month = (datetime(2006, 1, 1) + timedelta(days=day)).month
            groups[month].append(float(row["arctic_extent_million_km2"]))
    return {month: sum(values) / len(values) for month, values in groups.items()}


def nsidc_monthly_means(directory: Path) -> dict[int, float]:
    values: dict[int, float] = {}
    for month in range(1, 13):
        path = directory / f"N_{month:02d}_extent_v4.0.csv"
        with path.open(newline="") as handle:
            rows = csv.DictReader(handle)
            row = next(row for row in rows if row["year"].strip() == "2006")
        values[month] = float(row[" extent"])
    return values


def write_summary(path: Path, series: dict[str, dict[int, float]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["month", "nsidc", "current_rerun", "previous_baseline", "previous_reicing"])
        for month in range(1, 13):
            writer.writerow([month, *(series[name][month] for name in series)])


def plot(path: Path, series: dict[str, dict[int, float]]) -> None:
    labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    styles = {
        "nsidc": dict(label="NSIDC 2006", color="#1f2937", linestyle="--", marker="o"),
        "current_rerun": dict(label="PR59 rerun (Aug 10)", color="#dc2626", marker="o"),
        "previous_baseline": dict(label="PR59 baseline (Jun 8)", color="#2563eb", marker="o"),
        "previous_reicing": dict(label="PR59 re-icing (Jun 9)", color="#7c3aed", marker="o"),
    }
    figure, axis = plt.subplots(figsize=(11, 6), dpi=180)
    for name, values in series.items():
        axis.plot(range(1, 13), [values[month] for month in range(1, 13)], linewidth=2.2, **styles[name])
    axis.set(xlim=(1, 12), xticks=range(1, 13), xticklabels=labels,
             ylabel="Arctic sea-ice extent (million km²)", xlabel="2006 month",
             title="ORCA 1° ECCO/JRA55 Arctic sea-ice extent")
    axis.grid(alpha=0.25)
    axis.legend(loc="best")
    figure.text(0.02, 0.01, "Monthly means. Model: Northern Hemisphere cells with SIC ≥ 15%; NSIDC regional mask differs.", fontsize=9)
    figure.tight_layout(rect=(0, 0.035, 1, 1))
    path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(path, bbox_inches="tight")


def main() -> None:
    args = parse_args()
    series = {
        "nsidc": nsidc_monthly_means(args.nsidc_dir),
        "current_rerun": model_monthly_means(args.current),
        "previous_baseline": model_monthly_means(args.baseline),
        "previous_reicing": model_monthly_means(args.reicing),
    }
    write_summary(args.summary, series)
    plot(args.figure, series)


if __name__ == "__main__":
    main()
