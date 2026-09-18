#!/usr/bin/env python3
"""Reproduce Phase 10's raw depth sweep with one command from any directory."""

import json
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs/progress/phase10-measurements.json"
CASES = (
    "classification_invariant",
    "classification_sensitive",
    "classification_partial",
    "classification_opaque",
    "classification_persistent",
)
EXPECTED_CLASSES = (
    "DEPTH-INVARIANT, FULL", "DEPTH-SENSITIVE, FULL", "PARTIAL",
    "OPAQUE", "OPAQUE",
)
DEPTHS = range(4)


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    cases = []
    for name, expected_class in zip(CASES, EXPECTED_CLASSES, strict=True):
        measurements = []
        prior = None
        for depth in DEPTHS:
            command = (
                "opam", "exec", "--", "dune", "exec", "ash", "--",
                "--collapse", f"examples/{name}.ash", "--depth", str(depth), "--json",
            )
            raw = json.loads(run(*command))
            assert raw["classification"]["class"] == expected_class, (name, depth)
            assert raw["classification"]["tower_residual_agree"], (name, depth)
            assert raw["specialization"]["output"] == [], (name, depth)
            assert raw["residual"]["produced"], (name, depth)
            assert raw["residual"]["nodes"] > 0, (name, depth)
            residue = raw["residual"]
            counted_sites = (
                residue["eval_cell_dereferences"]
                + residue["evaluator_calls"]
                + residue["dispatch_sites"]
                + residue["named_var_lookups"]
                + sum(residue["reflection_boundaries"].values())
            )
            assert len(residue["sites"]) == counted_sites, (name, depth)
            assert sum(case["count"] for case in residue["cases_by_origin"]) == residue["nodes"]
            assert sum(case["count"] for case in residue["interpreter_cases"]) == residue["interpreter_nodes"]
            steps = raw["tower"]["run"]["steps"]
            measurements.append({
                "depth": depth,
                "ratio_to_previous_depth": None if prior is None else steps / prior,
                "raw": raw,
            })
            prior = steps
        cores = [point["raw"]["residual"]["core"] for point in measurements]
        if name == "classification_invariant":
            assert len(set(cores)) == 1
        if name == "classification_sensitive":
            assert len(set(cores)) == len(cores)
        if name == "classification_partial":
            assert all("(lit 42)" in core and "(lit 40)" not in core for core in cores)
        cases.append({"name": name, "measurements": measurements})
    result = {
        "schema": 1,
        "command": "python3 scripts/measure_phase10.py",
        "environment": {
            "python": platform.python_version(),
            "ocaml": run("opam", "exec", "--", "ocamlc", "-version"),
            "dune": run("opam", "exec", "--", "dune", "--version"),
            "opam": run("opam", "--version"),
            "platform": platform.platform(),
        },
        "cases": cases,
    }
    OUTPUT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    for case in cases:
        print(case["name"])
        for point in case["measurements"]:
            raw = point["raw"]
            print(
                f"  depth {point['depth']}: class={raw['classification']['class']}, "
                f"tower_steps={raw['tower']['run']['steps']}, "
                f"ratio={point['ratio_to_previous_depth']}, "
                f"residual_nodes={raw['residual'].get('nodes')}"
            )
    print(f"raw data: {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())
