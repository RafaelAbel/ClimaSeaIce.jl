#!/usr/bin/env bash
set -euo pipefail
root=/opt/dlami/nvme/pr165-corrected-year-20261011
cd "$root"
test -s prepare_status.txt
test ! -e outputs/preflight
test ! -e outputs/year
systemd-run --unit=pr165-corrected-regional-year --property=Restart=no /bin/bash "$root/run_corrected_year.sh"
systemctl show pr165-corrected-regional-year.service -p ActiveState -p SubState -p MainPID
