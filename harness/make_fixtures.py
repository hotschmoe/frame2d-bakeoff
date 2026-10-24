#!/usr/bin/env python3
"""Regenerates fixtures/p1 and fixtures/p2 from the closed-form values in SPEC section 6.

Expected values are computed here from beam theory at full float precision rather
than copied from the rounded numbers in the spec table.

Result-array conventions (see fixtures/README.md):
  displacements: every node, sorted by id
  reactions:     one entry per node with at least one restrained DOF, sorted by id
  members:       sorted by id; stations[0..10] at x = 0..L
"""
import json
import pathlib

E, A, I = 200e9, 0.01, 8e-5
EI = E * I
L, P, W = 5.0, 10_000.0, -5_000.0

ROOT = pathlib.Path(__file__).resolve().parent.parent / "fixtures"


def model(nodes, members, supports, load_cases, springs=None):
    m = {
        "materials": [{"id": "steel", "E": E}],
        "sections": [{"id": "BM", "A": A, "I": I}],
        "nodes": [{"id": i + 1, "x": x, "y": y} for i, (x, y) in enumerate(nodes)],
        "supports": supports,
        "members": [],
        "load_cases": load_cases,
    }
    for k, mem in enumerate(members):
        d = {"id": k + 1, "i": mem[0], "j": mem[1], "material": "steel", "section": "BM"}
        if len(mem) > 2:
            d["release"] = mem[2]
        m["members"].append(d)
    if springs:
        m["springs"] = springs
    return m


def fixed(n):
    return {"node": n, "ux": True, "uy": True, "rz": True}


def case(cid="D", nodal=None, udl=None):
    return {"id": cid, "nodal": nodal or [], "member_udl": udl or []}


def at(lc, kind, idx, key, value):
    return {"path": f"/load_cases/{lc}/{kind}/{idx}/{key}", "value": value}


def disp(lc, node_idx, key, value):
    return at(lc, "displacements", node_idx, key, value)


def react(lc, react_idx, key, value):
    return at(lc, "reactions", react_idx, key, value)


def station(lc, mem_idx, st_idx, key, value):
    return {"path": f"/load_cases/{lc}/members/{mem_idx}/stations/{st_idx}/{key}", "value": value}


def err(code):
    return {"error": code}


F = {}

# ---- P1 -------------------------------------------------------------------
tip_pl = -P * L**3 / (3 * EI)
tip_pl_rz = -P * L**2 / (2 * EI)
F["F01"] = ("p1", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1)], [case(nodal=[{"node": 2, "fx": 0, "fy": -P, "mz": 0}])]),
            [disp(0, 1, "uy", tip_pl), disp(0, 1, "rz", tip_pl_rz), react(0, 0, "fy", P), react(0, 0, "mz", P * L)])

F["F02"] = ("p1", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1)], [case(udl=[{"member": 1, "w": W}])]),
            [disp(0, 1, "uy", W * L**4 / (8 * EI)), disp(0, 1, "rz", W * L**3 / (6 * EI)),
             react(0, 0, "fy", -W * L), react(0, 0, "mz", -W * L**2 / 2)])

ss_sup = [{"node": 1, "ux": True, "uy": True, "rz": False}, {"node": 3, "ux": False, "uy": True, "rz": False}]
ss_nodes = [(0, 0), (L / 2, 0), (L, 0)]
F["F03"] = ("p1", model(ss_nodes, [(1, 2), (2, 3)], ss_sup, [case(nodal=[{"node": 2, "fx": 0, "fy": -P, "mz": 0}])]),
            [disp(0, 1, "uy", -P * L**3 / (48 * EI)), station(0, 0, 10, "M", P * L / 4),
             react(0, 0, "fy", P / 2), react(0, 1, "fy", P / 2)])

udl2 = [{"member": 1, "w": W}, {"member": 2, "w": W}]
F["F04"] = ("p1", model(ss_nodes, [(1, 2), (2, 3)], ss_sup, [case(udl=udl2)]),
            [disp(0, 1, "uy", 5 * W * L**4 / (384 * EI)), station(0, 0, 10, "M", -W * L**2 / 8),
             react(0, 0, "fy", -W * L / 2), react(0, 1, "fy", -W * L / 2)])

ff_sup = [fixed(1), fixed(3)]
f05 = [disp(0, 1, "uy", W * L**4 / (384 * EI)), react(0, 0, "mz", -W * L**2 / 12), react(0, 1, "mz", W * L**2 / 12),
       station(0, 0, 0, "M", W * L**2 / 12), station(0, 0, 10, "M", -W * L**2 / 24)]
F["F05"] = ("p1", model(ss_nodes, [(1, 2), (2, 3)], ff_sup, [case(udl=udl2)]), f05)

pmid = [{"node": 2, "fx": 0, "fy": -P, "mz": 0}]
f06 = [disp(0, 1, "uy", -P * L**3 / (192 * EI)), react(0, 0, "mz", P * L / 8), station(0, 0, 10, "M", P * L / 8)]
F["F06"] = ("p1", model(ss_nodes, [(1, 2), (2, 3)], ff_sup, [case(nodal=pmid)]), f06)

F["F07"] = ("p1", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1), {"node": 2, "ux": False, "uy": True, "rz": False}],
                        [case(udl=[{"member": 1, "w": W}])]),
            [react(0, 0, "fy", -5 * W * L / 8), react(0, 0, "mz", -W * L**2 / 8), react(0, 1, "fy", -3 * W * L / 8)])

F["F08"] = ("p1", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1)], [case(nodal=[{"node": 2, "fx": P, "fy": 0, "mz": 0}])]),
            [disp(0, 1, "ux", P * L / (E * A))] + [station(0, 0, k, "N", P) for k in range(11)])

F["F09"] = ("p1", model([(0, 0), (0, L)], [(1, 2)], [fixed(1)], [case(nodal=[{"node": 2, "fx": P, "fy": 0, "mz": 0}])]),
            [disp(0, 1, "ux", P * L**3 / (3 * EI)), disp(0, 1, "rz", -P * L**2 / (2 * EI)),
             react(0, 0, "fx", -P), react(0, 0, "mz", P * L)])

# Inclined: L=5, cos=0.8, sin=0.6; fy=-P resolved into member axes.
c, s = 0.8, 0.6
ax, tr = -P * s, -P * c
u_l, v_l, th = ax * L / (E * A), tr * L**3 / (3 * EI), tr * L**2 / (2 * EI)
F["F10"] = ("p1", model([(0, 0), (4, 3)], [(1, 2)], [fixed(1)], [case(nodal=[{"node": 2, "fx": 0, "fy": -P, "mz": 0}])]),
            [disp(0, 1, "ux", c * u_l - s * v_l), disp(0, 1, "uy", s * u_l + c * v_l), disp(0, 1, "rz", th),
             react(0, 0, "fy", P), react(0, 0, "mz", 4 * P)])

F["F11"] = ("p1", model(ss_nodes, [(1, 2), (2, 3)], ff_sup,
                        [case("D", udl=udl2), case("P", nodal=pmid), case("Z")]),
            f05
            + [{"path": x["path"].replace("/load_cases/0/", "/load_cases/1/"), "value": x["value"]} for x in f06]
            + [{"path": f"/load_cases/2/displacements/{n}/{k}", "value": 0.0} for n in range(3) for k in ("ux", "uy", "rz")]
            + [{"path": f"/load_cases/2/reactions/{n}/{k}", "value": 0.0} for n in range(2) for k in ("fx", "fy", "mz")])

tip = {"node": 2, "fx": 0, "fy": -P, "mz": 0}
F["F12"] = ("p1", model([(0, 0), (L, 0), (0, 10), (L, 10)], [(1, 2), (3, 4)], [fixed(1), fixed(3)],
                        [case(nodal=[tip, {**tip, "node": 4}])]),
            [disp(0, 1, "uy", tip_pl), disp(0, 1, "rz", tip_pl_rz), react(0, 0, "fy", P), react(0, 0, "mz", P * L),
             disp(0, 3, "uy", tip_pl), disp(0, 3, "rz", tip_pl_rz), react(0, 1, "fy", P), react(0, 1, "mz", P * L)])

F["F13"] = ("p1", model([(0, 0), (L, 0)], [(1, 2)], [], [case(nodal=[tip])]), [err("unstable")])

bad = model([(0, 0), (L, 0)], [(1, 99)], [fixed(1)], [case(nodal=[tip])])
F["F14"] = ("p1", bad, [err("invalid_ref")])

F["F15"] = ("p1", model([(0, 0), (0, 0)], [(1, 2)], [fixed(1)], [case(nodal=[tip])]), [err("zero_length")])

# ---- P2 -------------------------------------------------------------------
F["F21"] = ("p2", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1)], [case(nodal=[tip])],
                        springs=[{"node": 2, "ky": 3 * EI / L**3}]),
            [disp(0, 1, "uy", tip_pl / 2)])

# SPEC 6.2 originally said "both ends fixed", which leaves no free DOFs (no_free_dofs). Node 2 is the F07 roller
# (uy only); the released rz is then auto-restrained (4.7), so the result equals F07.
F["F22"] = ("p2", model([(0, 0), (L, 0)], [(1, 2, {"j": ["mz"]})],
                        [fixed(1), {"node": 2, "ux": False, "uy": True, "rz": False}],
                        [case(udl=[{"member": 1, "w": W}])]),
            [{"path": "/warnings", "len": 1}, {"path": "/warnings/0/warning", "value": "auto_restrained"},
             react(0, 0, "fy", -5 * W * L / 8), react(0, 0, "mz", -W * L**2 / 8), react(0, 1, "fy", -3 * W * L / 8),
             react(0, 1, "mz", 0.0)])

F["F23"] = ("p2", model(ss_nodes, [(1, 2, {"j": ["mz"]}), (2, 3)], ff_sup, [case(nodal=pmid)]),
            [disp(0, 1, "uy", -(P / 2) * (L / 2) ** 3 / (3 * EI)),
             react(0, 0, "mz", P / 2 * L / 2), react(0, 1, "mz", -P / 2 * L / 2)])

F["F24"] = ("p2", model(ss_nodes, [(1, 2, {"j": ["mz"]}), (2, 3, {"i": ["mz"]})], ff_sup, [case(nodal=pmid)]),
            [{"path": "/warnings", "len": 1}, {"path": "/warnings/0/warning", "value": "auto_restrained"},
             {"path": "/warnings/0/node", "value": 2}, {"path": "/warnings/0/dof", "value": "rz"},
             disp(0, 1, "uy", -(P / 2) * (L / 2) ** 3 / (3 * EI)), disp(0, 1, "rz", 0.0)])

F["F25"] = ("p2", model([(0, 0), (L, 0)], [(1, 2)], [fixed(1), {"node": 2, "ux": False, "uy": True, "rz": False}],
                        [case(nodal=[tip])], springs=[{"node": 2, "ky": 384000.0}]),
            [err("support_conflict")])

# ---- write ----------------------------------------------------------------
for fid, (phase, mdl, expect) in F.items():
    out = ROOT / phase / f"{fid}.json"
    out.write_text(json.dumps({**mdl, "expect": expect}, indent=1) + "\n")
print(f"wrote {len(F)} fixtures")
