#!/usr/bin/env python3
"""Independent reference implementation of the Frame2D engine (SPEC section 4), for validating
fixtures and goldens. Not a bake-off stack: dense numpy, no skyline solve, no performance goals.

  ref.py solve <model.json> [-o results.json]
  ref.py gen <B> <S> [-o model.json]

Exit codes follow SPEC 5.3 (0 ok, 2 model error with JSON on stdout, 1 other).
Profile convention (SPEC 4.4 leaves it open; fixed here, see SPEC 4.4 note): height of column j =
j - (lowest row index i <= j coupled to j by any member), summed over free DOFs, diagonal excluded.
"""
import argparse
import json
import math
import sys
from collections import defaultdict, deque

import numpy as np

DOFS = ("ux", "uy", "rz")


class ModelError(Exception):
    def __init__(self, code, detail=""):
        self.code, self.detail = code, detail


# ---------------------------------------------------------------- generator
def gen(B, S):
    nodes, members = [], []
    for s in range(S + 1):
        for b in range(B + 1):
            nodes.append({"id": s * (B + 1) + b + 1, "x": 6.0 * b, "y": 3.5 * s})
    nid = lambda b, s: s * (B + 1) + b + 1
    mid = 1
    for b in range(B + 1):
        for s in range(S):
            members.append({"id": mid, "i": nid(b, s), "j": nid(b, s + 1), "material": "steel", "section": "COL"})
            mid += 1
    beams = []
    for s in range(1, S + 1):
        for b in range(B):
            members.append({"id": mid, "i": nid(b, s), "j": nid(b + 1, s), "material": "steel", "section": "BM"})
            beams.append(mid)
            mid += 1
    return {
        "materials": [{"id": "steel", "E": 200e9}],
        "sections": [{"id": "COL", "A": 0.015, "I": 1.2e-4}, {"id": "BM", "A": 0.010, "I": 8.0e-5}],
        "nodes": nodes,
        "supports": [{"node": nid(b, 0), "ux": True, "uy": True, "rz": True} for b in range(B + 1)],
        "members": members,
        "load_cases": [
            {"id": "D", "nodal": [], "member_udl": [{"member": m, "w": -20000.0} for m in beams]},
            {"id": "L", "nodal": [], "member_udl": [{"member": m, "w": -10000.0} for m in beams]},
            {"id": "W", "nodal": [{"node": nid(0, s), "fx": 15000.0, "fy": 0.0, "mz": 0.0} for s in range(1, S + 1)],
             "member_udl": []},
        ],
    }


# ---------------------------------------------------------------- RCM and profile
def rcm(node_ids, edges):
    adj = defaultdict(set)
    for a, b in edges:
        if a != b:
            adj[a].add(b)
            adj[b].add(a)
    deg = {n: len(adj[n]) for n in node_ids}
    key = lambda n: (deg[n], n)

    def levels(root):
        seen, lv, frontier = {root}, [[root]], [root]
        while frontier:
            nxt = []
            for u in frontier:
                for v in adj[u]:
                    if v not in seen:
                        seen.add(v)
                        nxt.append(v)
            if nxt:
                lv.append(nxt)
            frontier = nxt
        return lv

    # components in ascending order of min node id
    comps, seen = [], set()
    for n in sorted(node_ids):
        if n in seen:
            continue
        comp, dq = set(), deque([n])
        while dq:
            u = dq.popleft()
            if u in comp:
                continue
            comp.add(u)
            dq.extend(adj[u] - comp)
        seen |= comp
        comps.append(comp)

    order = []
    for comp in comps:
        start = min(comp, key=key)
        lv = levels(start)
        ecc = len(lv)
        while True:
            cand = min(lv[-1], key=key)
            lv2 = levels(cand)
            if len(lv2) > ecc:
                start, lv, ecc = cand, lv2, len(lv2)
            else:
                break
        visited, out, dq = {start}, [], deque([start])
        while dq:
            u = dq.popleft()
            out.append(u)
            for v in sorted(adj[u] - visited, key=key):
                visited.add(v)
                dq.append(v)
        order.extend(out)
    return order[::-1]


def number_dofs(node_order, restrained):
    idx = {}
    for n in node_order:
        for d in DOFS:
            if (n, d) not in restrained:
                idx[(n, d)] = len(idx)
    return idx


def profile(idx, member_dofs):
    low = {j: j for j in idx.values()}
    for dofs in member_dofs:
        dofs = [idx[d] for d in dofs if d in idx]
        if dofs:
            lo = min(dofs)
            for j in dofs:
                low[j] = min(low[j], lo)
    return sum(j - low[j] for j in low)


# ---------------------------------------------------------------- element
def local_k(E, A, I, L):
    a, b = E * A / L, E * I / L**3
    return np.array([
        [a, 0, 0, -a, 0, 0],
        [0, 12 * b, 6 * b * L, 0, -12 * b, 6 * b * L],
        [0, 6 * b * L, 4 * b * L**2, 0, -6 * b * L, 2 * b * L**2],
        [-a, 0, 0, a, 0, 0],
        [0, -12 * b, -6 * b * L, 0, 12 * b, -6 * b * L],
        [0, 6 * b * L, 2 * b * L**2, 0, -6 * b * L, 4 * b * L**2],
    ])


def fixed_end(w, L):
    return np.array([0, -w * L / 2, -w * L**2 / 12, 0, -w * L / 2, w * L**2 / 12])


def rot(c, s):
    r = np.array([[c, s, 0], [-s, c, 0], [0, 0, 1]])
    T = np.zeros((6, 6))
    T[:3, :3], T[3:, 3:] = r, r
    return T


def condense(k, f, released):
    if not released:
        return k, f
    r = sorted(released)
    fr = [i for i in range(6) if i not in r]
    krr, kfr = k[np.ix_(r, r)], k[np.ix_(fr, r)]
    inv = np.linalg.inv(krr)
    kc = np.zeros((6, 6))
    kc[np.ix_(fr, fr)] = k[np.ix_(fr, fr)] - kfr @ inv @ kfr.T
    fc = np.zeros(6)
    fc[fr] = f[fr] - kfr @ inv @ f[r]
    return kc, fc


# ---------------------------------------------------------------- solve
def solve(m):
    nodes = {}
    for n in m["nodes"]:
        if n["id"] in nodes:
            raise ModelError("duplicate_id", f"node {n['id']}")
        nodes[n["id"]] = n
    mats = {x["id"]: x for x in m["materials"]}
    secs = {x["id"]: x for x in m["sections"]}
    members = {}
    for mem in m["members"]:
        if mem["id"] in members:
            raise ModelError("duplicate_id", f"member {mem['id']}")
        members[mem["id"]] = mem
    for mem in members.values():
        if mem["i"] not in nodes or mem["j"] not in nodes:
            raise ModelError("invalid_ref", f"member {mem['id']} node")
        if mem["material"] not in mats or mem["section"] not in secs:
            raise ModelError("invalid_ref", f"member {mem['id']} material/section")
    restrained = set()
    for s in m.get("supports", []):
        if s["node"] not in nodes:
            raise ModelError("invalid_ref", f"support node {s['node']}")
        restrained |= {(s["node"], d) for d in DOFS if s.get(d)}
    springs = defaultdict(dict)
    for sp in m.get("springs", []):
        if sp["node"] not in nodes:
            raise ModelError("invalid_ref", f"spring node {sp['node']}")
        for d, key in zip(DOFS, ("kx", "ky", "kr")):
            if key in sp:
                if (sp["node"], d) in restrained:
                    raise ModelError("support_conflict", f"node {sp['node']} {d}")
                springs[sp["node"]][d] = sp[key]
    for lc in m["load_cases"]:
        for l in lc.get("nodal", []):
            if l["node"] not in nodes:
                raise ModelError("invalid_ref", f"load node {l['node']}")
        for l in lc.get("member_udl", []):
            if l["member"] not in members:
                raise ModelError("invalid_ref", f"load member {l['member']}")

    geo = {}
    for mem in members.values():
        a, b = nodes[mem["i"]], nodes[mem["j"]]
        dx, dy = b["x"] - a["x"], b["y"] - a["y"]
        L = math.hypot(dx, dy)
        if L < 1e-9:
            raise ModelError("zero_length", f"member {mem['id']}")
        geo[mem["id"]] = (L, dx / L, dy / L)

    if all((n, d) in restrained for n in nodes for d in DOFS):
        raise ModelError("no_free_dofs")

    def dofs_of(mem):
        return [(mem["i"], d) for d in DOFS] + [(mem["j"], d) for d in DOFS]

    edges = {(mem["i"], mem["j"]) for mem in members.values()}
    order = rcm(list(nodes), edges)
    ident = sorted(nodes)

    def free_idx(ordering, extra=()):
        return number_dofs(ordering, restrained | set(extra))

    mdofs = [dofs_of(mem) for mem in members.values()]
    prof_before = profile(free_idx(ident), mdofs)
    prof_after = profile(free_idx(order), mdofs)

    # element matrices (global)
    elem = {}
    for mem in members.values():
        L, c, s = geo[mem["id"]]
        E, A, I = mats[mem["material"]]["E"], secs[mem["section"]]["A"], secs[mem["section"]]["I"]
        rel = set()
        for end, off in (("i", 0), ("j", 3)):
            for d in mem.get("release", {}).get(end, []):
                if d != "mz":
                    raise ModelError("invalid_ref", f"unsupported release {d}")
                rel.add(off + 2)
        k = local_k(E, A, I, L)
        elem[mem["id"]] = (k, rot(c, s), L, rel)

    def assemble(idx):
        n = len(idx)
        K = np.zeros((n, n))
        for mem in members.values():
            k, T, L, rel = elem[mem["id"]]
            kc, _ = condense(k, np.zeros(6), rel)
            kg = T.T @ kc @ T
            ds = [idx.get(d) for d in dofs_of(mem)]
            for a, ia in enumerate(ds):
                if ia is None:
                    continue
                for b, ib in enumerate(ds):
                    if ib is not None:
                        K[ia, ib] += kg[a, b]
        for node, sp in springs.items():
            for d, kv in sp.items():
                if (node, d) in idx:
                    K[idx[(node, d)], idx[(node, d)]] += kv
        return K

    warnings, extra = [], []
    idx = free_idx(order)
    K = assemble(idx)
    scale = np.max(np.diag(K)) if len(idx) else 1.0
    for (node, d), i in sorted(idx.items(), key=lambda kv: kv[1]):
        if d == "rz" and K[i, i] <= 1e-12 * scale:
            extra.append((node, d))
    if extra:
        for node, d in sorted(extra):
            warnings.append({"warning": "auto_restrained", "node": node, "dof": d})
        idx = free_idx(order, extra)
        K = assemble(idx)
        if not idx:
            raise ModelError("no_free_dofs")
    rinv = {i: key for key, i in idx.items()}
    n = len(idx)

    # LDL^T with pivot check
    A_ = K.copy()
    maxdiag = np.max(np.diag(K))
    D = np.zeros(n)
    Lm = np.eye(n)
    for j in range(n):
        v = A_[j, j] - np.sum(Lm[j, :j] ** 2 * D[:j])
        if v <= 1e-12 * maxdiag:
            node, d = rinv[j]
            raise ModelError("unstable", f"node {node} {d}")
        D[j] = v
        for i in range(j + 1, n):
            Lm[i, j] = (A_[i, j] - np.sum(Lm[i, :j] * Lm[j, :j] * D[:j])) / v

    def ldl_solve(b):
        y = np.linalg.solve(Lm, b)
        return np.linalg.solve(Lm.T, y / D)

    results = []
    for lc in m["load_cases"]:
        F = np.zeros(n)
        applied = defaultdict(lambda: np.zeros(3))
        for l in lc.get("nodal", []):
            v = np.array([l.get("fx", 0.0), l.get("fy", 0.0), l.get("mz", 0.0)])
            applied[l["node"]] += v
        w_of = defaultdict(float)
        for l in lc.get("member_udl", []):
            w_of[l["member"]] += l["w"]
        ffix = {}
        for mem in members.values():
            k, T, L, rel = elem[mem["id"]]
            f = fixed_end(w_of[mem["id"]], L)
            _, fc = condense(k, f, rel)
            ffix[mem["id"]] = (f, fc)
            fg = T.T @ fc  # fixed-end forces acting on member, global; equivalent nodal load is -fg
            for d, val in zip(dofs_of(mem), fg):
                if d in idx:
                    F[idx[d]] -= val
        for node, v in applied.items():
            for d, val in zip(DOFS, v):
                if (node, d) in idx:
                    F[idx[(node, d)]] += val
        u = ldl_solve(F) if n else np.zeros(0)
        get = lambda nd, d: float(u[idx[(nd, d)]]) if (nd, d) in idx else 0.0

        react = defaultdict(lambda: np.zeros(3))
        member_out = []
        for mem in sorted(members.values(), key=lambda x: x["id"]):
            k, T, L, rel = elem[mem["id"]]
            f_full, _ = ffix[mem["id"]]
            ug = np.array([get(nd, d) for nd, d in dofs_of(mem)])
            ul = T @ ug
            if rel:
                r = sorted(rel)
                fr = [i for i in range(6) if i not in r]
                ul[r] = -np.linalg.solve(k[np.ix_(r, r)], k[np.ix_(r, fr)] @ ul[fr] + f_full[r])
            ef = k @ ul + f_full
            if rel:
                ef[sorted(rel)] = 0.0
            gl = T.T @ ef
            for (nd, d), val in zip(dofs_of(mem), gl):
                if (nd, d) in restrained:
                    react[nd][DOFS.index(d)] += val
            w = w_of[mem["id"]]
            sts = []
            for kx in range(11):
                x = L * kx / 10
                sts.append({"x": x, "N": -ef[0], "V": ef[1] + w * x, "M": -ef[2] + ef[1] * x + w * x * x / 2})
            member_out.append({"id": mem["id"], "end_forces": [float(v) for v in ef], "stations": sts})
        rx = []
        for nd in sorted({nd for nd, _ in restrained}):
            v = react[nd] - applied.get(nd, np.zeros(3))
            rx.append({"node": nd, "fx": float(v[0]), "fy": float(v[1]), "mz": float(v[2])})

        # equilibrium: reactions + applied loads + UDL resultants, moments about the origin
        sx = sy = sm = 0.0
        mag = 1.0
        for r in rx:
            p = nodes[r["node"]]
            sx += r["fx"]; sy += r["fy"]; sm += r["mz"] + p["x"] * r["fy"] - p["y"] * r["fx"]
            mag += abs(r["fx"]) + abs(r["fy"])
        for nd, v in applied.items():
            p = nodes[nd]
            sx += v[0]; sy += v[1]; sm += v[2] + p["x"] * v[1] - p["y"] * v[0]
            mag += abs(v[0]) + abs(v[1])
        for mid_, w in w_of.items():
            mem = members[mid_]
            L, c, s = geo[mid_]
            a = nodes[mem["i"]]
            fxg, fyg = -s * w * L, c * w * L
            cx, cy = a["x"] + c * L / 2, a["y"] + s * L / 2
            sx += fxg; sy += fyg; sm += cx * fyg - cy * fxg
            mag += abs(fxg) + abs(fyg)
        resid = max(abs(sx), abs(sy)) / mag
        results.append({
            "id": lc["id"],
            "displacements": [{"node": nd, **{d: get(nd, d) for d in DOFS}} for nd in sorted(nodes)],
            "reactions": rx,
            "members": member_out,
            "equilibrium_residual": float(resid),
        })
    return {
        "load_cases": results,
        "warnings": warnings,
        "stats": {"nodes": len(nodes), "members": len(members), "free_dofs": n,
                  "profile_before": prof_before, "profile_after": prof_after,
                  "assemble_ms": 0, "factor_ms": 0, "solve_ms": 0,
                  "alloc_count": None, "alloc_bytes": None, "peak_heap_bytes": None},
    }


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("solve"); s.add_argument("model"); s.add_argument("-o")
    g = sub.add_parser("gen"); g.add_argument("B", type=int); g.add_argument("S", type=int); g.add_argument("-o")
    a = ap.parse_args()
    try:
        if a.cmd == "gen":
            out = gen(a.B, a.S)
        else:
            out = solve(json.load(open(a.model)))
    except ModelError as e:
        print(json.dumps({"error": e.code, "detail": e.detail}))
        sys.exit(2)
    except Exception as e:  # noqa: BLE001
        print(f"error: {e!r}", file=sys.stderr)
        sys.exit(1)
    text = json.dumps(out)
    if a.o:
        open(a.o, "w").write(text)
    else:
        print(text)


if __name__ == "__main__":
    main()
