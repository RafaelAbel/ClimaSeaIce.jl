#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path
from tempfile import gettempdir

TMP_ROOT = Path(os.environ.get("TMPDIR", gettempdir()))
os.environ.setdefault("MPLCONFIGDIR", str(TMP_ROOT / "mplconfig-arctic-extent-compare"))
os.environ.setdefault("XDG_CACHE_HOME", str(TMP_ROOT / "xdg-cache-arctic-extent-compare"))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot Arctic sea-ice extent comparison for baseline and re-icing runs.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def read_rows(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            rows.append({key: float(value) for key, value in row.items()})
    return rows


def main() -> None:
    args = parse_args()
    rows = read_rows(args.input)

    day = [row["day"] for row in rows]
    baseline = [row["baseline_arctic_extent_million_km2"] for row in rows]
    reicing = [row["reicing_arctic_extent_million_km2"] for row in rows]
    delta = [row["delta_million_km2"] for row in rows]

    fig, axes = plt.subplots(2, 1, figsize=(10.8, 8.0), sharex=True, dpi=180)
    fig.subplots_adjust(hspace=0.12, top=0.88, bottom=0.11)

    axes[0].plot(
        day,
        baseline,
        color="#334155",
        linewidth=2.5,
        linestyle=(0, (6, 3)),
        label="Baseline",
        zorder=3,
    )
    axes[0].plot(
        day,
        reicing,
        color="#dc2626",
        linewidth=1.9,
        alpha=0.9,
        label="Artificial re-icing",
        zorder=4,
    )
    axes[0].set_ylabel("Arctic SIE (million km$^2$)")
    axes[0].grid(True, alpha=0.3, linestyle="--")
    axes[0].legend(loc="best")

    axes[1].axhline(0.0, color="#64748b", linewidth=1.0)
    axes[1].plot(day, delta, color="#b45309", linewidth=2.0)
    axes[1].fill_between(day, delta, 0.0, color="#fdba74", alpha=0.35)
    axes[1].set_xlabel("Simulation day")
    axes[1].set_ylabel("Delta SIE")
    axes[1].grid(True, alpha=0.3, linestyle="--")

    fig.suptitle("Arctic sea-ice extent comparison", fontsize=16, y=0.96)
    axes[0].set_title("Baseline versus artificial re-icing run", fontsize=10.5, pad=8)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    main()
