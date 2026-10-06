"""Summarize every finding, including unfixed findings, without hiding blockers."""
import json
import sys
from collections import Counter

with open(sys.argv[1]) as report:
    data = json.load(report)
findings = [finding for result in data.get("Results", []) for finding in result.get("Vulnerabilities") or []]
counts = Counter(finding["Severity"] for finding in findings)
blockers = [finding for finding in findings if finding["Severity"] in {"CRITICAL", "HIGH"} and finding.get("FixedVersion")]
print("### Trivy image scan\n")
print("| Critical | High | Medium | Low | Unknown | Fixable High/Critical |")
print("| --- | --- | --- | --- | --- | --- |")
print("| " + " | ".join(str(counts[level]) for level in ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]) + f" | {len(blockers)} |")
print("\nFixable High/Critical findings block publication. Unfixed findings remain visible in the attached full report.")
