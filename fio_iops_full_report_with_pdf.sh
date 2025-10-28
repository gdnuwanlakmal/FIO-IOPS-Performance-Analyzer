#!/bin/bash
# ============================================================
# FIO IOPS + THROUGHPUT REPORT (with charts → PDF/HTML)
# Runs: randread, randwrite, randrw (4k), read, write (1M)
# Produces: per-test JSON/TXT, PNG charts, and a PDF report
# Author: ChatGPT
# ============================================================
set -euo pipefail

# ------------------- USER CONFIG -------------------
TEST_DIR="/tmp/IOPS_Results"   # Output root
RUNTIME=120                    # seconds per test
BS_RAND="4k"                   # random tests block size
BS_SEQ="1M"                    # sequential tests block size
JOBS=4                         # parallel jobs per test
IODEPTH=32                     # queue depth for random tests (seq uses 1)
SIZE="2G"                      # testfile size
LOG_AVG_MS=1000                # fio time-series sample interval (ms)
# ---------------------------------------------------

DATESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="$TEST_DIR/results_$DATESTAMP"
TEST_FILE="$LOG_DIR/fio_testfile"
SUMMARY_MD="$LOG_DIR/summary_report.md"
PDF="$LOG_DIR/fio_iops_report.pdf"

mkdir -p "$LOG_DIR"

# ---------- REQUIREMENTS CHECK ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }
for c in fio jq pandoc python3; do need "$c"; done

# Python libs for charts
python3 - <<'PYCHK' || { echo "❌ Missing Python libs: pandas/matplotlib. Install with:
  python3 -m pip install --break-system-packages pandas matplotlib"; exit 1; }
import sys
import importlib
for m in ("pandas","matplotlib"):
    importlib.import_module(m)
PYCHK

echo "============================================================"
echo "  FIO IOPS + THROUGHPUT PERFORMANCE (with charts)"
echo "============================================================"
echo "Random: BS=$BS_RAND | Jobs=$JOBS | I/O Depth=$IODEPTH | Runtime=$RUNTIME s"
echo "Sequential: BS=$BS_SEQ | Jobs=$JOBS | I/O Depth=1 | Runtime=$RUNTIME s"
echo "Output folder: $LOG_DIR"
echo "------------------------------------------------------------"

# ------------------- WARM-UP -------------------
echo "🟡 Warm-up (10s sequential write)…"
fio --name=warmup --ioengine=libaio --rw=write --bs=1M --size="$SIZE" \
    --filename="$TEST_FILE" --runtime=10 --direct=1 --numjobs=1 --iodepth=1 \
    --group_reporting --output-format=normal > /dev/null
echo "✅ Warm-up complete."
echo "------------------------------------------------------------"

# -------------- RUN ONE FIO TEST --------------
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

  # Robust jq: sums IOPS/BW across jobs; averages latency; handles ns/us + nulls
  jq -r '
    def jobs: (.jobs // []);
    def lat_ms(j):
      if j.clat_ns.mean then (j.clat_ns.mean/1000000)
      elif j.lat_ns.mean then (j.lat_ns.mean/1000000)
      elif j.clat_us.mean then (j.clat_us.mean/1000)
      elif j.lat_us.mean then (j.lat_us.mean/1000)
      else 0 end;
    def p95_ms(j):
      if (j.clat_ns.percentile["95.000000"]? ) then (j.clat_ns.percentile["95.000000"]/1000000)
      elif (j.lat_ns.percentile["95.000000"]? ) then (j.lat_ns.percentile["95.000000"]/1000000)
      elif (j.clat_us.percentile["95.000000"]? ) then (j.clat_us.percentile["95.000000"]/1000)
      elif (j.lat_us.percentile["95.000000"]? ) then (j.lat_us.percentile["95.000000"]/1000)
      else 0 end;

    {
      "Read IOPS":  ([jobs[] | (.read.iops // 0)]        | add // 0),
      "Write IOPS": ([jobs[] | (.write.iops // 0)]       | add // 0),
      "Read MB/s":  (([jobs[] | (.read.bw_bytes // 0)]   | add // 0) / 1048576),
      "Write MB/s": (([jobs[] | (.write.bw_bytes // 0)]  | add // 0) / 1048576),
      "Avg Latency (ms)": ( [jobs[] | lat_ms(.)] | if length>0 then (add/length) else 0 end ),
      "p95 Latency (ms)":  ( [jobs[] | p95_ms(.)] | if length>0 then (add/length) else 0 end )
    }
    | to_entries
    | (["Metric","Value"], (.[] | [ .key, (if (.value|type)=="number" then (.value|tostring) else .value end) ]))
    | @tsv
  ' "$out_json" | column -t > "$out_txt"

  echo "✅ $name done."
  echo "------------------------------------------------------------"
}

# ------------------- RUN TESTS -------------------
# Random (4k)
run_fio_test "random-read"  "randread"  "$BS_RAND" "$IODEPTH"
run_fio_test "random-write" "randwrite" "$BS_RAND" "$IODEPTH"
run_fio_test "mixed-rw"     "randrw"    "$BS_RAND" "$IODEPTH"  --rwmixread=70

# Sequential (1M, qd=1 is typical for pure throughput)
run_fio_test "seq-read"     "read"      "$BS_SEQ"  1
run_fio_test "seq-write"    "write"     "$BS_SEQ"  1

# Remove the testfile (we used a file inside LOG_DIR; safe to delete)
rm -f "$TEST_FILE"

# ------------------- CHARTS (Python) -------------------
CHART_PY="$LOG_DIR/make_charts.py"
cat > "$CHART_PY" << 'PYCODE'
import glob, os, pandas as pd, matplotlib.pyplot as plt

outdir = os.path.dirname(__file__)
tests = ["random-read","random-write","mixed-rw","seq-read","seq-write"]

def read_fio_logs(base, kind):
    # fio writes e.g. base_bw.1.log, base_iops.2.log, base_lat.1.log
    files = sorted(glob.glob(f"{base}_{kind}.*.log"))
    if not files:
        return None
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
    if not dfs:
        return None
    # Merge by time and sum values across jobs
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
        md_lines.append(f"![{t} IOPS]({os.path.basename(png)})")

    bw = read_fio_logs(base, "bw")
    if bw is not None:
        png = os.path.join(outdir, f"{t}_bw.png")
        save_line(bw["s"], bw["val"]/1024.0, f"{t} — Bandwidth over time", "MB/s", png)  # KB/s → MB/s
        md_lines.append(f"![{t} Bandwidth]({os.path.basename(png)})")

    lat = read_fio_logs(base, "lat")
    if lat is not None:
        png = os.path.join(outdir, f"{t}_lat.png")
        save_line(lat["s"], lat["val"]/1000.0, f"{t} — Latency over time", "Latency (ms)", png)  # usec → ms
        md_lines.append(f"![{t} Latency]({os.path.basename(png)})")

with open(os.path.join(outdir, "charts_section.md"), "w") as f:
    f.write("\n\n".join(md_lines) + "\n")
print(os.path.join(outdir, "charts_section.md"))
PYCODE

echo "📈 Building charts..."
CHART_MD_PATH=$(python3 "$CHART_PY" || echo "")
[[ -f "$CHART_MD_PATH" ]] || CHART_MD_PATH=""

# ------------------- BUILD REPORT -------------------
{
  echo "# FIO IOPS + Throughput Performance Report"
  echo ""
  echo "**Date:** $(date)  "
  echo "**Output Folder:** \`$LOG_DIR\`  "
  echo ""
  echo "## Test Parameters"
  echo "- Random: BS=$BS_RAND, Jobs=$JOBS, I/O Depth=$IODEPTH, Runtime=$RUNTIME s"
  echo "- Sequential: BS=$BS_SEQ, Jobs=$JOBS, I/O Depth=1, Runtime=$RUNTIME s"
  echo "- log_avg_msec: ${LOG_AVG_MS} ms"
  echo ""
  echo "## Results (Key Metrics)"
  for f in "$LOG_DIR/random-read.txt" "$LOG_DIR/random-write.txt" "$LOG_DIR/mixed-rw.txt" "$LOG_DIR/seq-read.txt" "$LOG_DIR/seq-write.txt"; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .txt)
    echo "### $name"
    echo ""
    echo '```'
    cat "$f"
    echo '```'
    echo ""
  done

  if [[ -n "$CHART_MD_PATH" && -f "$CHART_MD_PATH" ]]; then
    cat "$CHART_MD_PATH"
  else
    echo "*(Charts could not be generated — ensure python3, pandas, and matplotlib are installed.)*"
  fi

  echo ""
  echo "## Notes"
  echo "- Random tests emphasize IOPS & latency; sequential tests emphasize peak MB/s."
  echo "- For apples-to-apples vendor comparisons, keep BS / jobs / iodepth identical."
} > "$SUMMARY_MD"

# ------------------- EXPORT PDF/HTML -------------------
echo "📄 Generating report…"
PDF_ENGINE="xelatex"
if ! command -v xelatex >/dev/null 2>&1; then PDF_ENGINE="pdflatex"; fi

if command -v "$PDF_ENGINE" >/dev/null 2>&1; then
  pandoc "$SUMMARY_MD" -o "$PDF" --standalone --pdf-engine="$PDF_ENGINE"
  echo "📄 PDF report: $PDF"
else
  HTML="${PDF%.pdf}.html"
  pandoc "$SUMMARY_MD" -o "$HTML" -s
  echo "🌐 LaTeX engine not found; created HTML instead: $HTML"
fi

echo "🎯 Done!"
echo "📁 Folder: $LOG_DIR"
# ============================================================
