# Usage: python3 summarize.py <file.tsv>...  Prints median [p10, p90] per label for every numeric column.
import csv, statistics, sys
from collections import defaultdict

rows = defaultdict(list)
for path in sys.argv[1:]:
    with open(path) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            rows[row["label"]].append(row)

columns = ["cmd_ms", "shown_ms", "hidden_ms", "settled_ms", "app_cpu_ms", "server_cpu_ms", "leaked_windows", "leaked_px"]
def q(values, p):
    return statistics.quantiles(values, n=10)[p] if len(values) > 1 else values[0]
for label, rs in rows.items():
    print(f"{label}: n={len(rs)} timed_out={sum(r['timed_out'] == '1' for r in rs)}")
    for c in columns:
        values = [float(r[c]) for r in rs if r[c] != "NA"]
        if values:
            print(f"  {c:15} median {statistics.median(values):9.2f}  p10 {q(values, 0):9.2f}  p90 {q(values, 8):9.2f}")
