# FIO-IOPS-Performance-Analyzer
A Complete Automated Storage Benchmarking and Reporting Tool for Ubuntu/Linux Servers

## 🧭 Overview
FIO-IOPS-Performance-Analyzer is a fully automated Linux benchmarking script that measures and compares IOPS, throughput (MB/s), and latency performance for any storage system (SAS, SATA, NVMe, SSD, RAID, or HCI).

It performs five standardized tests using fio
:

1. Random Read (4 K)
2. Random Write (4 K)
3. Mixed Read/Write (70/30)
4. Sequential Read (1 M)
5. Sequential Write (1 M)
### The tool automatically:
- Runs each workload with proper warm-up and direct I/O
- Collects detailed JSON metrics (IOPS, MB/s, latency p95, etc.)
- Generates time-series logs (iops, bw, lat)
- Builds beautiful charts using Python (pandas + matplotlib)
- Produces a polished PDF or HTML report via Pandoc + LaTeX
### Everything is self-contained in one bash script — ideal for labs, performance validation, or vendor comparisons (e.g., Cisco HCI vs Huawei HCI).

## ⚙️ Features

* 🧩 5 standard fio workloads (random/sequential read/write/mixed)
* 🧮 Accurate IOPS / MB/s / latency aggregation across jobs
* 🧾 JSON + text summaries per test
* 📈 Auto-generated charts (IOPS, Bandwidth, Latency vs time)
* 📄 Single PDF/HTML report ready for sharing
* 🧰 Cross-compatible with any Ubuntu / Debian server

## 🧰 Dependencies
Install all required tools once:
```shell
sudo apt update
sudo apt install -y fio jq pandoc texlive-latex-base texlive-fonts-recommended \
  texlive-fonts-extra texlive-latex-extra texlive-xetex python3 python3-pip
python3 -m pip install --break-system-packages pandas matplotlib
```
## 🚀 Usage
Clone the repo and run the benchmark:
```shell
git clone https://github.com/gdnuwanlakmal/fio-iops-performance-analyzer.git
cd fio-iops-performance-analyzer
chmod +x fio_iops_full_report_with_pdf.sh
sudo ./fio_iops_full_report_with_pdf.sh
```
### After execution, results are stored in:
```shell
/tmp/IOPS_Results/results_<timestamp>/
├── random-read.json / .txt
├── random-write.json / .txt
├── mixed-rw.json / .txt
├── seq-read.json / .txt
├── seq-write.json / .txt
├── *_iops.png / *_bw.png / *_lat.png   ← charts
├── summary_report.md
└── fio_iops_report.pdf  ✅ final report
```
## 🧪 Example Output
- Charts: IOPS, Bandwidth, and Latency vs time
- Report: automatically generated PDF showing test configuration, metrics, and charts
- Sample use case: Compare different storage types — SAS vs SATA, SSD cache vs HDD tier, or vendor hardware (e.g., Cisco HyperFlex vs Huawei HCI)

## 🧠 Notes
- Uses --direct=1 for accurate disk-level results (no OS cache).
- Default test file: /tmp/IOPS_Results/.../fio_testfile (safe).
- Adjust parameters (RUNTIME, BS_RAND, BS_SEQ, etc.) in the script header.
- Requires ~4 GB free disk space and ~5–10 minutes per full run.

## 🪪 License
- MIT License — free to use, modify, and distribute.
