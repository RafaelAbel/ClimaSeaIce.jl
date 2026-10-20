"""Export the audited regional NetCDF as simple column-major arrays for Julia."""
from pathlib import Path
import argparse
import numpy as np
from netCDF4 import Dataset

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description="Export prepared 2006 regional forcing for the PR165 Julia driver")
parser.add_argument("source", type=Path, help="prepared jra55_glorys_1deg_20060101_365day_cell_centers_v6.nc")
source = parser.parse_args().source.resolve()
out = root / "input"
out.mkdir(exist_ok=True)

def write(name, value):
    array = np.asarray(value, dtype="<f4", order="F")
    array.ravel(order="F").tofile(out / f"{name}.f32")
    print(name, array.shape, float(np.nanmin(array)), float(np.nanmax(array)), flush=True)

with Dataset(source) as ds:
    for name in ("longitude", "latitude", "wet", "h", "concentration", "ocean_temperature"):
        write(name, ds[name][:].T)
    for name in ("tas", "huss", "psl", "uas", "vas", "rlds", "rsds"):
        times = np.asarray(ds[f"t_{name}"][:], dtype="<f8")
        if len(times) != 2921 or times[0] > 0 or times[-1] < 365 * 86400:
            raise ValueError(f"Bad forcing coverage: {name}")
        times.tofile(out / f"t_{name}.f64")
        # NetCDF order is time, y, x; Julia reads x, y, time.
        write(name, np.transpose(ds[name][:], (2, 1, 0)))
