"""Génère les fixtures de parité du moteur Dart à partir du moteur Python de référence.

Usage (depuis la racine du dépôt Flutter) :

    REF=../textile-line-balancer   # dépôt Python (lecture seule)
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$REF python tool/parity/gen_fixtures.py $REF

Chaque cas écrit `test/fixtures/engine/<cas>.json` :
    {"name", "description", "solver": "rpw", "kind": "balance"|"min_cycle",
     "problem": <ProblemIn JSON, comme POST /v1/balance>,
     "expected": <ResultOut JSON (api.conversion.result_out)>,
     "precheck": <PrecheckOut JSON (api.conversion.run_precheck)>}

et `test/fixtures/csv/<fichier>.json` = résultat des parseurs Python sur les CSV d'exemple.
Le moteur Python n'est jamais modifié : on importe ses modules tels quels.
"""
from __future__ import annotations

import copy
import json
import shutil
import sys
from pathlib import Path

REF = Path(sys.argv[1] if len(sys.argv) > 1 else "../textile-line-balancer").resolve()
sys.path.insert(0, str(REF))

from engine.models import LineBalancingProblem, Operation, Worker, Workstation  # noqa: E402
from engine.parsers import parse_sam_file, parse_workers_file, parse_workstations_file  # noqa: E402
from engine.solvers import find_min_cycle, solve  # noqa: E402
from api.conversion import (  # noqa: E402
    operations_out, result_out, run_precheck, workers_out, workstations_out,
)
from api.schemas import ProblemIn  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "test" / "fixtures"
SAMPLES = REF / "data" / "samples"


def problem_in(p: LineBalancingProblem) -> ProblemIn:
    return ProblemIn(
        name=p.name, target_cycle_time=p.target_cycle_time,
        operations=operations_out(p.operations), workstations=workstations_out(p.workstations),
        workers=workers_out(p.workers), max_stations=p.max_stations,
        max_machines_per_station=p.max_machines_per_station, machine_change_time=p.machine_change_time,
        section_policy=p.section_policy, split_mode=p.split_mode,
    )


def from_samples(name, sam, cycle, ws=None, wk=None, **opts) -> LineBalancingProblem:
    ops = parse_sam_file(SAMPLES / sam)
    wss = parse_workstations_file(SAMPLES / ws) if ws else []
    wks = parse_workers_file(SAMPLES / wk) if wk else []
    p = LineBalancingProblem(name=name, target_cycle_time=cycle, operations=ops, workstations=wss, workers=wks)
    for k, v in opts.items():
        setattr(p, k, v)
    return p


# Gamme « dos de pantalon » de tests/test_engine_multi.py (copie des données, pas du code de test)
DOS_OPS = [
    ("OP010", "Thermofixer ceintures / renforts dos", 2.1, [], "Thermo-presse", "oper_tissu", "Finissage"),
    ("OP020", "Marquer pinces dos", 1.8, ["OP010"], "Marqueur auto", "oper_precis", "Traçage"),
    ("OP030", "Piquer pinces dos", 3.5, ["OP020"], "Piqueuse plate", "piquer", "Couture"),
    ("OP040", "Assemblage milieu dos (fourche)", 4.2, ["OP030"], "Surjeteuse 4-fils", "surjeter", "Couture"),
    ("OP050", "Surpiquer milieu dos", 2.7, ["OP040"], "Piqueuse double aiguille", "piquer_surpiquer", "Couture"),
    ("OP060", "Poser et plaquer poches dos", 3.1, ["OP050"], "Piqueuse plate", "piquer", "Couture"),
    ("OP070", "Fixer passants ceintures dos", 0.9, ["OP060"], "Machine à passants", "machine_passant", "Montage"),
]
DOS_WS = [("WS01", "Thermo-presse", "Finissage"), ("WS02", "Marqueur auto", "Traçage"),
          ("WS03", "Piqueuse plate", "Couture"), ("WS04", "Surjeteuse 4-fils", "Couture"),
          ("WS05", "Piqueuse double aiguille", "Couture"), ("WS06", "Piqueuse plate", "Couture"),
          ("WS07", "Machine à passants", "Montage")]
DOS_REAL = [("W001", "Operateur Thermo", ["oper_tissu"]), ("W002", "Operateur Tracage", ["oper_precis"]),
            ("W003", "Piqueuse 01", ["piquer", "surjeter"]), ("W004", "Surjeteuse 01", ["surjeter", "piquer"]),
            ("W005", "Piqueuse Double", ["piquer_surpiquer"]), ("W006", "Operateur Passants", ["machine_passant"])]


def dos_pantalon(workers="none", cycle=5.0, **kw) -> LineBalancingProblem:
    ops = [Operation(id=i, name=n, duration=d, predecessors=list(p), machine_type=m,
                     required_skills=[s], section=sec) for i, n, d, p, m, s, sec in DOS_OPS]
    wss = [Workstation(id=i, name=i, machine_type=m, section=sec) for i, m, sec in DOS_WS]
    if workers == "real":
        wk = [Worker(id=i, name=n, skills=list(s)) for i, n, s in DOS_REAL]
    elif workers == "real2":  # deux formations de plus (test_real_workers_with_two_trainings)
        wk = [Worker(id=i, name=n, skills=list(s)) for i, n, s in DOS_REAL]
        wk[0].skills.append("piquer")
        wk[5].skills.append("piquer")
    elif workers == "poly":
        allsk = sorted({o.required_skills[0] for o in ops})
        wk = [Worker(id=f"P{i}", name=f"Poly {i}", skills=allsk, efficiency=e)
              for i, e in enumerate([1.0, 0.9, 1.15, 0.95, 1.05, 1.0])]
    elif workers == "levels":
        allsk = sorted({o.required_skills[0] for o in ops})
        wk = [Worker(id=f"L{i}", name=f"Poly {i}", skills=allsk, efficiency=1.0,
                     skill_levels={"piquer": 1.2 - 0.1 * i, "surjeter": 0.8 + 0.05 * i})
              for i in range(8)]
    else:
        wk = []
    p = LineBalancingProblem(name="dos pantalon", target_cycle_time=cycle, operations=ops,
                             workstations=wss, workers=wk)
    for k, v in kw.items():
        setattr(p, k, v)
    return p


def abcd() -> LineBalancingProblem:
    """Exemple RPW du manuel (§3.8) : A, B, C, D à la cadence 1,0."""
    ops = [Operation("A", "A", 0.4), Operation("B", "B", 0.5, ["A"]), Operation("C", "C", 0.6, ["A"]),
           Operation("D", "D", 0.3, ["B", "C"])]
    return LineBalancingProblem(name="manuel A-B-C-D", target_cycle_time=1.0, operations=ops,
                                workstations=[], workers=[])


CASES = [
    ("chemise_c150_full", "Chemise homme 21 op. (SAM 16,50), 14 postes, 19 ouvriers, cadence 1,5",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.5, "workstations_chemise.csv", "workers_chemise.csv")),
    ("chemise_c150_ops_only", "Chemise, opérations seules, cadence 1,5 (N_min 11)",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.5)),
    ("chemise_c120_full", "Chemise complète, cadence 1,2 (exemple du web)",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.2, "workstations_chemise.csv", "workers_chemise.csv")),
    ("chemise_c100_share", "Chemise, cadence 1,0 : opérations > cadence partagées (parts + reliquat)",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.0, "workstations_chemise.csv")),
    ("chemise_c100_parallel", "Chemise, cadence 1,0, mode parallel (postes dédoublés)",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.0, "workstations_chemise.csv", split_mode="parallel")),
    ("chemise_c150_onemachine", "Chemise complète, 1 machine par station (ancien comportement)",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.5, "workstations_chemise.csv", "workers_chemise.csv",
                          max_machines_per_station=1)),
    ("chemise_c150_change_strict", "Chemise, déplacement 0,05 min/machine, sections strictes",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.5, "workstations_chemise.csv", "workers_chemise.csv",
                          machine_change_time=0.05, section_policy="strict")),
    ("pantalon_c120_std", "Pantalon (sam_pantalon) + postes/ouvriers standard, cadence 1,2",
     lambda: from_samples("Pantalon", "sam_pantalon.csv", 1.2, "workstations_standard.csv", "workers_standard.csv")),
    ("pantalon_homme_c100", "Pantalon homme, opérations + postes standard, cadence 1,0",
     lambda: from_samples("Pantalon homme", "sam_pantalon_homme.csv", 1.0, "workstations_standard.csv")),
    ("veste_c200_std", "Veste + postes/ouvriers standard, cadence 2,0",
     lambda: from_samples("Veste", "sam_veste.csv", 2.0, "workstations_standard.csv", "workers_standard.csv")),
    ("veste_homme_c150", "Veste homme 31 op., opérations seules, cadence 1,5",
     lambda: from_samples("Veste homme", "sam_veste_homme.csv", 1.5)),
    ("dos_none", "Dos de pantalon, 7 postes, sans ouvriers, cadence 5",
     lambda: dos_pantalon("none")),
    ("dos_real", "Dos de pantalon, ouvriers réels (SKILL_CAPACITY attendu)",
     lambda: dos_pantalon("real")),
    ("dos_real_c55", "Dos de pantalon, ouvriers réels, cadence 5,5",
     lambda: dos_pantalon("real", cycle=5.5)),
    ("dos_real2", "Dos de pantalon, ouvriers réels + 2 formations",
     lambda: dos_pantalon("real2")),
    ("dos_poly", "Dos de pantalon, 6 polyvalents de rendements différents (méthode hongroise)",
     lambda: dos_pantalon("poly")),
    ("dos_levels", "Dos de pantalon, matrice de polyvalence (skill_levels)",
     lambda: dos_pantalon("levels")),
    ("dos_one_machine", "Dos de pantalon, 1 machine par station",
     lambda: dos_pantalon("none", max_machines_per_station=1)),
    ("dos_change_time", "Dos de pantalon, déplacement 0,3 min par machine",
     lambda: dos_pantalon("poly", machine_change_time=0.3)),
    ("dos_c30_share", "Dos de pantalon, cadence 3,0 : partage d'opérations longues",
     lambda: dos_pantalon("poly", cycle=3.0)),
    ("manuel_abcd", "Exemple RPW du manuel (A,B,C,D ; cadence 1,0)", abcd),
]

MIN_CYCLE_CASES = [
    ("mincycle_chemise_full", "Cadence minimale RPW, chemise complète",
     lambda: from_samples("Chemise homme", "sam_chemise_homme.csv", 1.5, "workstations_chemise.csv", "workers_chemise.csv")),
    ("mincycle_dos_poly", "Cadence minimale RPW, dos de pantalon polyvalents",
     lambda: dos_pantalon("poly")),
]


def dump(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def main() -> None:
    (OUT / "engine").mkdir(parents=True, exist_ok=True)
    for name, desc, build in CASES:
        prob = build()
        pin = problem_in(prob)
        r = solve("rpw", copy.deepcopy(prob))
        out = result_out(prob, r).model_dump()
        out["solve_time_seconds"] = 0.0
        pre = run_precheck(pin).model_dump()
        dump(OUT / "engine" / f"{name}.json", {
            "name": name, "description": desc, "solver": "rpw", "kind": "balance",
            "problem": pin.model_dump(), "expected": out, "precheck": pre})
        print(f"{name:28s} stations={out['stations_used']:3d} op={out['operators']:3d} "
              f"eff={out['efficiency']:5.1f} compliant={out['compliant']}")
    for name, desc, build in MIN_CYCLE_CASES:
        prob = build()
        pin = problem_in(prob)
        cycle, r = find_min_cycle(copy.deepcopy(prob), solver="rpw", precision=0.05)
        res = None
        if r is not None:
            res = result_out(r.problem, r).model_dump()
            res["solve_time_seconds"] = 0.0
        dump(OUT / "engine" / f"{name}.json", {
            "name": name, "description": desc, "solver": "rpw", "kind": "min_cycle", "precision": 0.05,
            "problem": pin.model_dump(),
            "expected": {"found": cycle is not None, "min_cycle_time": cycle, "result": res}})
        print(f"{name:28s} min_cycle={cycle}")

    # Parseurs CSV : sorties de référence
    for f in sorted(SAMPLES.glob("*.csv")):
        shutil.copy(f, OUT / "csv" / f.name) if (OUT / "csv").exists() else ((OUT / "csv").mkdir(parents=True), shutil.copy(f, OUT / "csv" / f.name))
        if f.name.startswith("sam_"):
            items = [o.model_dump() for o in operations_out(parse_sam_file(f))]
        elif f.name.startswith("workers_"):
            items = [w.model_dump() for w in workers_out(parse_workers_file(f))]
        else:
            items = [w.model_dump() for w in workstations_out(parse_workstations_file(f))]
        dump(OUT / "csv" / f"{f.stem}.expected.json", items)


if __name__ == "__main__":
    main()
