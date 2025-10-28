#!/bin/bash
# =====================================================================
# FIO IOPS + THROUGHPUT REPORT (with charts → PDF/HTML)
# Runs: randread, randwrite, randrw (4k), read, write (1M)
# Outputs: per-test JSON/TXT, PNG charts, and a polished PDF/HTML report
# Robust jq (jq-1.5 compatible), correct latency parsing, safe resource-path
# Headless charts + ASCII-safe system info for perfect PDF alignment
# =====================================================================
set -euo pipefail

# ---------------- CONFIG (tune as needed) ----------------
TEST_DIR="/tmp/IOPS_Results"   # Results root directory
RUNTIME=120                    # seconds per test
BS_RAND="4k"                   # block size for random tests
BS_SEQ="1M"                    # block size for sequential tests
JOBS=4                         # parallel jobs
IODEPTH=32                     # queue depth for random tests (seq uses 1)
SIZE="2G"                      # testfile size
LOG_AVG_MS=1000                # fio log sample interval (ms)
# ---------------------------------------------------------

DATESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="$TEST_DIR/results_$DATESTAMP"
TEST_FILE="$LOG_DIR/fio_testfile"
SUMMARY_MD="$LOG_DIR/summary_report.md"
PDF="$LOG_DIR/fio_iops_report.pdf"

mkdir -p "$LOG_DIR"

# ---------------- Dependency checks ----------------
need() { command -v "$1" >/dev/null 2>&1; }
for c in fio jq pandoc python3; do
  if ! need "$c"; then
    echo "❌ Missing dependency: $c"
    echo "   Install prerequisites shown at the top of this message."
    exit 1
  fi
done

# Optional: chart libs
PY_OK=1
python3 - <<'PYCHK' || PY_OK=0
import importlib
for m in ("pandas","matplotlib"):
    importlib.import_module(m)
PYCHK

# ---------------- System info (for report) ----------------
SYSINFO_TXT="$LOG_DIR/system_info.txt"
{
  echo "Hostname: $(hostname)"
  echo "Date: $(date -Is)"
  echo "Kernel: $(uname -r)"
  echo "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
  echo "fio: $(fio --version 2>/dev/null || echo unknown)"
  echo
  echo "=== CPU (lscpu) ==="
  (command -v lscpu >/dev/null && lscpu) || echo "lscpu not available"
  echo
  echo "=== Memory (free -h) ==="
  (command -v free >/dev/null && free -h) || echo "free not available"
  echo
  echo "=== Block Devices (ASCII list) ==="
  if command -v lsblk >/dev/null; then
    # ASCII-safe (no box-drawing glyphs)
    lsblk -l -o NAME,MODEL,SIZE,ROTA,TYPE,MOUNTPOINTS
  else
    echo "lsblk not available"
  fi
} > "$SYSINFO_TXT"

echo "============================================================"
echo "  FIO IOPS + THROUGHPUT PERFORMANCE (with charts)"
echo "============================================================"
echo "Random: BS=$BS_RAND | Jobs=$JOBS | I/O Depth=$IODEPTH | Runtime=$RUNTIME s"
echo "Sequential: BS=$BS_SEQ | Jobs=$JOBS | I/O Depth=1 | Runtime=$RUNTIME s"
echo "Output folder: $LOG_DIR"
echo "------------------------------------------------------------"

# ---------------- Warm-up pass ----------------
echo "🟡 Warm-up (10s sequential write)…"
fio --name=warmup --ioengine=libaio --rw=write --bs=1M --size="$SIZE" \
    --filename="$TEST_FILE" --runtime=10 --direct=1 --numjobs=1 --iodepth=1 \
    --group_reporting --output-format=normal > /dev/null
echo "✅ Warm-up complete."
echo "------------------------------------------------------------"

# ---------------- One test runner ----------------
# Args: name rw bs iodepth [extra fio args...]
run_fio_test() {
  local name="$1"; shift
  local rw="$1"; shift
  local bs="$1"; shift
  local iodepth="$1"; shift
  local extra=( "$@" )
  echo "▶️  $name  ($rw, bs=$bs, qd=$iodepth)"

  local out_json="$LOG_DIR/${name}.json"
  local out_txt="$LOG_DIR/${name}.txt"
  local base="$LOG_DIR/${name}"

  fio --name="$name" \
      --ioengine=libaio \
      --rw="$rw" \
      --bs="$bs" \
      --size="$SIZE" \
      --numjobs="$JOBS" \
      --iodepth="$iodepth" \
      --runtime="$RUNTIME" \
      --time_based \
      --group_reporting \
      --direct=1 \
      --filename="$TEST_FILE" \
      --log_avg_msec="$LOG_AVG_MS" \
      --write_iops_log="$base" \
      --write_bw_log="$base" \
      --write_lat_log="$base" \
      "${extra[@]}" \
      --output-format=json --output="$out_json" > /dev/null

  # jq: sum IOPS/BW across jobs; average latency; pull latency from read./write. blocks; jq-1.5 compatible
  jq -r '
    def jobs: (.jobs // []);

    def read_lat_ms:
      if .read.clat_ns.mean then (.read.clat_ns.mean/1e6)
      elif .read.lat_ns.mean then (.read.lat_ns.mean/1e6)
      elif .read.clat_us.mean then (.read.clat_us.mean/1e3)
      elif .read.lat_us.mean then (.read.lat_us.mean/1e3)
      else 0 end;

    def write_lat_ms:
      if .write.clat_ns.mean then (.write.clat_ns.mean/1e6)
      elif .write.lat_ns.mean then (.write.lat_ns.mean/1e6)
      elif .write.clat_us.mean then (.write.clat_us.mean/1e3)
      elif .write.lat_us.mean then (.write.lat_us.mean/1e3)
      else 0 end;

    def read_p95_ms:
      if (.read.clat_ns.percentile["95.000000"]?) then (.read.clat_ns.percentile["95.000000"]/1e6)
      elif (.read.lat_ns.percentile["95.000000"]?) then (.read.lat_ns.percentile["95.000000"]/1e6)
      elif (.read.clat_us.percentile["95.000000"]?) then (.read.clat_us.percentile["95.000000"]/1e3)
      elif (.read.lat_us.percentile["95.000000"]?) then (.read.lat_us.percentile["95.000000"]/1e3)
      else 0 end;

    def write_p95_ms:
      if (.write.clat_ns.percentile["95.000000"]?) then (.write.clat_ns.percentile["95.000000"]/1e6)
      elif (.write.lat_ns.percentile["95.000000"]?) then (.write.lat_ns.percentile["95.000000"]/1e6)
      elif (.write.clat_us.percentile["95.000000"]?) then (.write.clat_us.percentile["95.000000"]/1e3)
      elif (.write.lat_us.percentile["95.000000"]?) then (.write.lat_us.percentile["95.000000"]/1e3)
      else 0 end;

    # Arrays from all jobs
    ( [ jobs[] | (.read.iops       // 0) ] ) as $r_iops
    | ( [ jobs[] | (.write.iops    // 0) ] ) as $w_iops
    | ( [ jobs[] | (.read.bw_bytes // 0) ] ) as $r_bw
    | ( [ jobs[] | (.write.bw_bytes// 0) ] ) as $w_bw
    | ( [ jobs[] | read_lat_ms    ] )       as $r_lat
    | ( [ jobs[] | write_lat_ms   ] )       as $w_lat
    | ( [ jobs[] | read_p95_ms    ] )       as $r_p95
    | ( [ jobs[] | write_p95_ms   ] )       as $w_p95

    # Reducers (jq-1.5 safe)
    | def arr_sum(a): ( a | reduce .[] as $x (0; . + $x) );
      def arr_avg(a): ( a | (length) as $n | (reduce .[] as $x (0; . + $x)) / (if $n>0 then $n else 1 end) );

    {
      "Read IOPS":          arr_sum($r_iops),
      "Write IOPS":         arr_sum($w_iops),
      "Read MB/s":          (arr_sum($r_bw)/1048576),
      "Write MB/s":         (arr_sum($w_bw)/1048576),
      "Read Avg Lat (ms)":  arr_avg($r_lat),
      "Read p95 Lat (ms)":  arr_avg($r_p95),
      "Write Avg Lat (ms)": arr_avg($w_lat),
      "Write p95 Lat (ms)": arr_avg($w_p95)
    }
    | to_entries
    | (["Metric","Value"], (.[] | [ .key, (if (.value|type)=="number" then (.value|tostring) else .value end) ]))
    | @tsv
  ' "$out_json" | column -t > "$out_txt"

  echo "✅ $name done."
  echo "------------------------------------------------------------"
}

# ---------------- Run tests ----------------
# Random (4k)
run_fio_test "random-read"  "randread"  "$BS_RAND" "$IODEPTH"
run_fio_test "random-write" "randwrite" "$BS_RAND" "$IODEPTH"
run_fio_test "mixed-rw"     "randrw"    "$BS_RAND" "$IODEPTH"  --rwmixread=70
# Sequential (1M, qd=1 for clean throughput)
run_fio_test "seq-read"     "read"      "$BS_SEQ"  1
run_fio_test "seq-write"    "write"     "$BS_SEQ"  1

# Test file cleanup (safe)
rm -f "$TEST_FILE"

# ---------------- Chart builder (Python) ----------------
CHART_MD=""
if [[ "$PY_OK" -eq 1 ]]; then
  CHART_PY="$LOG_DIR/make_charts.py"
  cat > "$CHART_PY" << 'PYCODE'
import os
# Force headless (no X11) for perfect server-side rendering
os.environ["MPLBACKEND"] = "Agg"

import glob, pandas as pd, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

outdir = os.path.dirname(__file__)
tests = ["random-read","random-write","mixed-rw","seq-read","seq-write"]

def read_fio_logs(base, kind):
  files = sorted(glob.glob(f"{base}_{kind}.*.log"))
  if not files: return None
  dfs = []
  for f in files:
    try:
      df = pd.read_csv(f, comment="#", header=None, engine="python")
    except Exception:
      df = pd.read_csv(f, comment="#", header=None, engine="python", sep=r"\s+")
    if df.shape[1] >= 2:
      df = df.iloc[:, :2]
      df.columns = ["ms", "val"]
      dfs.append(df)
  if not dfs: return None
  m = dfs[0].copy()
  for d in dfs[1:]:
    m = m.merge(d, on="ms", how="outer", suffixes=("","_x"))
    valcols = [c for c in m.columns if c.startswith("val")]
    m["val_sum"] = m[valcols].sum(axis=1)
    m = m[["ms","val_sum"]].rename(columns={"val_sum":"val"})
  m = m.sort_values("ms")
  m["s"] = m["ms"] / 1000.0
  return m[["s","val"]]

def save_line(x, y, title, ylabel, png):
  plt.figure()
  plt.plot(x, y)
  plt.xlabel("Time (s)")
  plt.ylabel(ylabel)
  plt.title(title)
  plt.tight_layout()
  plt.savefig(png, dpi=140)
  plt.close()

md_lines = ["## Charts"]
for t in tests:
  base = os.path.join(outdir, t)

  iops = read_fio_logs(base, "iops")
  if iops is not None:
    png = os.path.join(outdir, f"{t}_iops.png")
    save_line(iops["s"], iops["val"], f"{t} — IOPS over time", "IOPS", png)
    md_lines.append(f"![{t} IOPS]({os.path.basename(png)}){{ width=95% }}")

  bw = read_fio_logs(base, "bw")
  if bw is not None:
    png = os.path.join(outdir, f"{t}_bw.png")
    # KB/s → MB/s
    save_line(bw["s"], bw["val"]/1024.0, f"{t} — Bandwidth over time", "MB/s", png)
    md_lines.append(f"![{t} Bandwidth]({os.path.basename(png)}){{ width=95% }}")

  lat = read_fio_logs(base, "lat")
  if lat is not None:
    png = os.path.join(outdir, f"{t}_lat.png")
    # usec → ms
    save_line(lat["s"], lat["val"]/1000.0, f"{t} — Latency over time", "Latency (ms)", png)
    md_lines.append(f"![{t} Latency]({os.path.basename(png)}){{ width=95% }}")

charts_md = os.path.join(outdir, "charts_section.md")
with open(charts_md, "w") as f:
  f.write("\n\n".join(md_lines) + "\n")
print(charts_md)
PYCODE

  echo "📈 Building charts…"
  CHART_MD=$(python3 "$CHART_PY" || echo "")
  [[ -f "$CHART_MD" ]] || CHART_MD=""
else
  echo "ℹ️ Charts skipped (pandas/matplotlib not installed)."
fi

# ---------------- Build Markdown report ----------------
{
  echo "# FIO IOPS + Throughput Performance Report"
  echo
  echo "**Date:** $(date)  "
  echo "**Output Folder:** \`$LOG_DIR\`  "
  echo
  echo "## System Information"
  echo '```'
  cat "$SYSINFO_TXT"
  echo '```'
  echo
  echo "## Test Parameters"
  echo "- Random: BS=$BS_RAND, Jobs=$JOBS, I/O Depth=$IODEPTH, Runtime=$RUNTIME s"
  echo "- Sequential: BS=$BS_SEQ, Jobs=$JOBS, I/O Depth=1, Runtime=$RUNTIME s"
  echo "- log_avg_msec: ${LOG_AVG_MS} ms"
  echo "- Test file size: $SIZE"
  echo
  echo "## Results (Key Metrics)"
  for f in "$LOG_DIR/random-read.txt" "$LOG_DIR/random-write.txt" "$LOG_DIR/mixed-rw.txt" "$LOG_DIR/seq-read.txt" "$LOG_DIR/seq-write.txt"; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .txt)
    echo "### $name"
    echo
    echo '```'
    cat "$f"
    echo '```'
    echo
  done

  if [[ -n "$CHART_MD" && -f "$CHART_MD" ]]; then
    cat "$CHART_MD"
  else
    echo "*(Charts not generated — ensure python3, pandas, and matplotlib are installed.)*"
  fi

  echo
  echo "## Notes"
  echo "- Random tests emphasize IOPS & latency; sequential tests emphasize peak MB/s."
  echo "- Keep BS / jobs / iodepth identical when comparing different systems."
} > "$SUMMARY_MD"

# ---------------- Export PDF/HTML ----------------
echo "📄 Generating report…"
PDF_ENGINE="xelatex"; command -v xelatex >/dev/null 2>&1 || PDF_ENGINE="pdflatex"

(
  cd "$LOG_DIR"
  if command -v "$PDF_ENGINE" >/dev/null 2>&1; then
    pandoc "summary_report.md" -o "fio_iops_report.pdf" --standalone --pdf-engine="$PDF_ENGINE" --resource-path="."
    echo "📄 PDF report: $LOG_DIR/fio_iops_report.pdf"
  else
    pandoc "summary_report.md" -o "fio_iops_report.html" -s --resource-path="."
    echo "🌐 LaTeX engine not found; created HTML instead: $LOG_DIR/fio_iops_report.html"
  fi
)

echo "🎯 Done!"
echo "📁 Results folder: $LOG_DIR"
# =====================================================================
