"""Export the corrected regional JRA55-do precipitation onto Julia's grid order.

The prepared annual file has already aligned the interval-mean precipitation
with the three-hourly atmospheric state timestamps. This exporter verifies
that alignment before writing either precipitation variable.
"""

from pathlib import Path
import argparse
import numpy as np
import xarray as xr

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description="Export aligned snowfall for the PR165 Julia driver")
parser.add_argument("source", type=Path, help="prepared jra55_glorys_1deg_20060101_365day_cell_centers_v6.nc")
source = parser.parse_args().source.resolve()
out = root / "input"
out.mkdir(exist_ok=True)

with xr.open_dataset(source, engine="netcdf4", decode_times=False) as ds:
    atmospheric_times = np.asarray(ds["t_tas"].values, dtype="<f8")
    if len(atmospheric_times) != 2921 or atmospheric_times[0] != 0 or atmospheric_times[-1] != 365 * 86400:
        raise ValueError("Unexpected atmospheric time coverage")
    for name in ("prsn", "prra"):
        times = np.asarray(ds[f"t_{name}"].values, dtype="<f8")
        if not np.array_equal(times, atmospheric_times):
            raise ValueError(f"{name} time axis is not aligned with atmosphere")
        values = np.asarray(ds[name].values, dtype="<f4")
        if values.shape != (2921, 44, 44) or not np.isfinite(values).all() or (values < 0).any():
            raise ValueError(f"Invalid {name} precipitation")
        np.transpose(values, (2, 1, 0)).ravel(order="F").tofile(out / f"{name}.f32")
        times.tofile(out / f"t_{name}.f64")
        print(name, values.shape, float(values.min()), float(values.max()))
