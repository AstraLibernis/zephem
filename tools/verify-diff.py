#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
"""verify-diff.py — an INDEPENDENT re-computation of everything `zephem diff <old> <new>` reports,
from the raw TSV files, in a different language, with the arithmetic identities that must hold.

    tools/verify-diff.py 0.16.0 0.17.0            # exit 0 only if every quantity and identity agrees

Why this exists: the diff is the evidence a model reads instead of recalling std. Evidence needs
a second witness. This script shares no code with src/diff.zig: it re-reads nodes.tsv,
attrs.tsv, builtins.tsv and resolved.tsv, derives every set with its own logic (including the
move-support rules, re-implemented from the prose in docs/release-diff.md), runs the binary's
`--tsv` output, and demands SET EQUALITY per finding type — not just equal counts. Then it checks
the identities below, which are true by construction of the definitions and would catch a row
that is counted in two places or in none:

  I1  |pub(old)|            = |removed| + |both, pub in old|
  I2  |pub(new)|            = |added|   + |both, pub in new|
  I3  removed listed        = |removed| − |removed tags| − |moves|            (each move.from ∈ removed, non-tag)
  I4  added listed          = |added|   − |added tags|   − |moves|            (each move.to   ∈ added,   non-tag)
  I5  moves are a bijection: |{from}| = |{to}| = |moves|, from ⊆ removed, to ⊆ added
  I6  Σ per-module tallies  = (|removed|, |changed|, |added|)
  I7  Σ signature classes   = |changed with a signature on both sides that differ (normalised)|,
      sig_dropped = |changed, old sig only|, blank detail = |changed, same normalised sig|
  I8  Σ over enums of (tags removed + tags added) = |removed tags| + |added tags|
  I9  newly-deprecated ∩ un-deprecated = ∅ ; deprecated-then-removed ⊆ removed
  I10 every manifest-listed file in both version folders has the digest its manifest states

Everything printed is recomputed here; the only thing taken from the tool is its own output.
"""
import csv, hashlib, re, subprocess, sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
csv.field_size_limit(1 << 30)


def tsv(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE))
    head, body = rows[0], rows[1:]
    return [dict(zip(head, r)) for r in body]


class Side:
    def __init__(self, d: Path):
        self.dir = d
        self.decl = {}  # path -> dict(kind, name, vis, sig, doc)
        for r in tsv(d / "extracted/nodes.tsv"):
            self.decl[r["path"]] = dict(kind=r["kind"], name=r["name"], vis=r["vis"], sig=None, doc=None)
        for r in tsv(d / "extracted/attrs.tsv"):
            if r["attr"] in ("sig", "doc") and r["path"] in self.decl:
                self.decl[r["path"]][r["attr"]] = r["value"]
        self.builtins = {r["name"]: (r["sig"], r["doc"]) for r in tsv(d / "extracted/builtins.tsv")}
        self.resolved = {}
        p = d / "extracted/resolved.tsv"
        if p.exists():
            for r in tsv(p):
                self.resolved.setdefault(r["path"], (r["kind"], r["detail"]))  # first row wins

    def pub(self):
        return {p for p, d in self.decl.items() if d["vis"] == "pub"}


# ------------------------------------------------------------------ signatures ------

def normalize(sig):
    """Collapse whitespace runs; no space after ([{ or before )]},; drop a trailing comma before )."""
    s = re.sub(r"\s+", " ", sig).strip()
    s = re.sub(r"([(\[{]) ", r"\1", s)
    s = re.sub(r" ([)\]},])", r"\1", s)
    s = re.sub(r",\)", ")", s)
    return s


def strip_prose(sig):
    """Remove `/// …` parameter prose inside the list (sig.zig's job); crude but only used to parse."""
    if "///" not in sig:
        return sig
    out, i, depth = [], 0, 0
    while i < len(sig):
        if sig.startswith("///", i):
            # skip to the next parameter name: the identifier before the next ':' at this depth
            j = sig.find(":", i)
            if j < 0:
                break
            k = j
            while k > 0 and (sig[k - 1].isalnum() or sig[k - 1] in "_@\""):
                k -= 1
            # also back over qualifiers
            seg = sig[k:j]
            i = k
            continue
        out.append(sig[i])
        i += 1
    return "".join(out)


def parse_sig(sig):
    s = strip_prose(sig)
    o = s.find("(")
    if o < 0:
        return None
    depth, close = 0, None
    for i in range(o, len(s)):
        if s[i] in "([{":
            depth += 1
        elif s[i] in ")]}":
            depth -= 1
            if depth == 0:
                close = i
                break
    if close is None:
        return None
    params, depth, start = [], 0, o + 1
    for i in range(o + 1, close + 1):
        c = s[i]
        if i < close and c in "([{":
            depth += 1
            continue
        if i < close and c in ")]}":
            depth -= 1
            continue
        if i == close or (c == "," and depth == 0):
            seg = s[start:i].strip()
            start = i + 1
            if not seg:
                continue
            d2, colon = 0, None
            for j, ch in enumerate(seg):
                if ch in "([{":
                    d2 += 1
                elif ch in ")]}":
                    d2 -= 1
                elif ch == ":" and d2 == 0:
                    colon = j
                    break
            if colon is None:
                params.append(("", seg))
            else:
                name = seg[:colon].strip().split(" ")[-1]
                params.append((name, seg[colon + 1:].strip()))
    return params, s[close + 1:].strip()


def split_ret(ret):
    depth = 0
    for i, ch in enumerate(ret):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "!" and depth == 0:
            return ret[:i], ret[i + 1:]
    return "", ret


def classify(old, new):
    po, pn = parse_sig(old), parse_sig(new)
    if po is None or pn is None:
        return "other"
    (op, oret), (np_, nret) = po, pn
    if len(op) != len(np_):
        return "arity"
    ot, nt = [t for _, t in op], [t for _, t in np_]
    if ot == nt:
        if oret == nret:
            return "names" if [n for n, _ in op] != [n for n, _ in np_] else "format"
        eo, po_ = split_ret(oret)
        en, pn_ = split_ret(nret)
        return "error_set" if po_ == pn_ else "return_type"
    return "order" if sorted(ot) == sorted(nt) else "types"


# ------------------------------------------------------------------ the diff --------

def parent(p):
    return p.rsplit(".", 1)[0] if "." in p else p


def compute(old: Side, new: Side):
    O, N = old.pub(), new.pub()
    both = set(old.decl) & set(new.decl)
    removed = {p for p in O if p not in new.decl}
    added = {p for p in N if p not in old.decl}
    changed, sigclass = {}, {}
    for p in both:
        o, n = old.decl[p], new.decl[p]
        if o["vis"] != "pub" and n["vis"] != "pub":
            continue
        same_sig = (o["sig"] is None and n["sig"] is None) or (
            o["sig"] is not None and n["sig"] is not None and normalize(o["sig"]) == normalize(n["sig"]))
        if o["kind"] != n["kind"] or o["vis"] != n["vis"] or not same_sig:
            changed[p] = (o, n)
            if same_sig:
                sigclass[p] = ""
            elif o["sig"] is not None and n["sig"] is not None:
                sigclass[p] = classify(o["sig"], n["sig"])
            else:
                sigclass[p] = "sig_dropped" if o["sig"] is not None else "sig_gained"

    def key(d):
        return (d["name"], d["kind"], d["sig"] or "")

    rem_nontag = [p for p in removed if old.decl[p]["kind"] != "tag"]
    add_nontag = [p for p in added if new.decl[p]["kind"] != "tag"]
    rc = Counter(key(old.decl[p]) for p in rem_nontag)
    ac = Counter(key(new.decl[p]) for p in add_nontag)
    add_by_key = {key(new.decl[p]): p for p in add_nontag if ac[key(new.decl[p])] == 1}
    cands = []
    for p in sorted(rem_nontag):
        k = key(old.decl[p])
        if rc[k] == 1 and k in add_by_key:
            cands.append((p, add_by_key[k], old.decl[p]["sig"] is not None))
    pair_count = Counter((parent(f), parent(t)) for f, t, _ in cands)
    lost = defaultdict(list)
    gained = set()
    for p in rem_nontag:
        lost[parent(p)].append((old.decl[p]["name"], old.decl[p]["kind"]))
    for p in add_nontag:
        gained.add((parent(p), new.decl[p]["name"], new.decl[p]["kind"]))

    def shared(f, t):
        own = (old.decl[f]["name"], old.decl[f]["kind"])
        return sum(1 for nk in lost[parent(f)] if nk != own and (parent(t),) + nk in gained)

    accepted = {i for i, (_, _, has_sig) in enumerate(cands) if has_sig}
    acc_pairs = {(cands[i][0], cands[i][1]) for i in accepted}
    child = Counter((parent(cands[i][0]), parent(cands[i][1])) for i in accepted)
    progress = True
    while progress:
        progress = False
        for i, (f, t, has_sig) in enumerate(cands):
            if i in accepted:
                continue
            pp = (parent(f), parent(t))
            if pair_count[pp] >= 2 or pp in acc_pairs or child[(f, t)] >= 2 or shared(f, t) >= 2:
                accepted.add(i)
                acc_pairs.add((f, t))
                child[pp] += 1
                progress = True
    moves = {(cands[i][0], cands[i][1], "signature" if cands[i][2] else "parents") for i in accepted}

    def dep(d):
        return (d["doc"] or "").startswith("Deprecated")

    newly = {p for p in both if (old.decl[p]["vis"] == "pub" or new.decl[p]["vis"] == "pub") and not dep(old.decl[p]) and dep(new.decl[p])}
    lifted = {p for p in both if (old.decl[p]["vis"] == "pub" or new.decl[p]["vis"] == "pub") and dep(old.decl[p]) and not dep(new.decl[p])}
    dep_removed = {p for p in removed if dep(old.decl[p])}

    tags_r = {p for p in removed if old.decl[p]["kind"] == "tag"}
    tags_a = {p for p in added if new.decl[p]["kind"] == "tag"}
    enums = {parent(p) for p in tags_r | tags_a}

    b_added = set(new.builtins) - set(old.builtins)
    b_removed = set(old.builtins) - set(new.builtins)
    b_changed = {n for n in set(old.builtins) & set(new.builtins) if old.builtins[n][0] != new.builtins[n][0]}
    b_doc = {n for n in set(old.builtins) & set(new.builtins) if old.builtins[n][0] == new.builtins[n][0] and old.builtins[n][1] != new.builtins[n][1]}

    values = set()
    for p, (k, v) in old.resolved.items():
        if k not in ("const_int", "const_bool") or p not in new.resolved:
            continue
        k2, v2 = new.resolved[p]
        if k != k2 or v == v2:
            continue
        if p in new.decl and new.decl[p]["vis"] != "pub":
            continue
        values.add((p, v, v2))

    docs = {}
    for p in both:
        o, n = old.decl[p], new.decl[p]
        if o["vis"] != "pub" and n["vis"] != "pub":
            continue
        if p in changed or dep(o) != dep(n):
            continue
        od, nd = o["doc"] or "", n["doc"] or ""
        if od == nd:
            continue
        hint = any(re.search(ph, nd, re.I) and not re.search(ph, od, re.I) for ph in (r"no longer", r"now "))
        docs[p] = hint

    return dict(O=O, N=N, both=both, removed=removed, added=added, changed=changed, sigclass=sigclass, moves=moves,
                newly=newly, lifted=lifted, dep_removed=dep_removed, tags_r=tags_r, tags_a=tags_a, enums=enums,
                b_added=b_added, b_removed=b_removed, b_changed=b_changed, b_doc=b_doc, values=values, docs=docs)


# ------------------------------------------------------------------ the tool --------

def run_tool(zephem, old, new):
    out = subprocess.run([zephem, "diff", old, new, "--tsv", "--limit", "0"], capture_output=True, text=True, check=True).stdout
    rows = [r for r in csv.reader(out.splitlines(), delimiter="\t", quoting=csv.QUOTE_NONE)]
    assert rows[0] == ["change", "provenance", "path", "kind_old", "kind_new", "old", "new", "detail"], rows[0]
    bad = [r for r in rows[1:] if len(r) != 8]
    assert not bad, f"{len(bad)} TSV rows without 8 fields"
    by = defaultdict(list)
    for r in rows[1:]:
        by[r[0]].append(r)
    human = subprocess.run([zephem, "diff", old, new, "--limit", "0"], capture_output=True, text=True, check=True).stdout
    return by, human


def section_count(human, title_prefix):
    m = re.search(r"^## " + re.escape(title_prefix) + r".*\((\d+)\)", human, re.M)
    return int(m.group(1)) if m else None


# ------------------------------------------------------------------ main ------------

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    old_v, new_v = args
    zephem = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--zephem=")), str(ROOT / "zig-out/bin/zephem"))
    vd = lambda v: ROOT / "data/std" if v == "live" else ROOT / "data/versions" / v
    old, new = Side(vd(old_v)), Side(vd(new_v))
    me = compute(old, new)
    by, human = run_tool(zephem, old_v, new_v)

    fails = []
    rows = []

    def check(name, mine, tool, equal=None):
        ok = (mine == tool) if equal is None else equal
        rows.append((name, mine if not isinstance(mine, (set, dict, frozenset)) else len(mine),
                     tool if not isinstance(tool, (set, dict, frozenset)) else len(tool), ok))
        if not ok:
            fails.append(name)

    # Set equality per finding type (counts are shown, equality is on the sets).
    t_removed = {r[2] for r in by["removed"]}
    t_added = {r[2] for r in by["added"]}
    t_changed = {r[2] for r in by["changed"]}
    check("removed (set)", me["removed"], t_removed)
    check("added (set)", me["added"], t_added)
    check("changed (set)", set(me["changed"]), t_changed)
    t_detail = {r[2]: r[7] for r in by["changed"]}
    check("changed: detail per row", me["sigclass"], t_detail)
    t_moves = {(r[2], r[6], r[7]) for r in by["moved"]}
    check("moves (set of from,to,support)", me["moves"], t_moves)
    check("newly deprecated (set)", me["newly"], {r[2] for r in by["deprecated"]})
    check("un-deprecated (set)", me["lifted"], {r[2] for r in by["undeprecated"]})
    check("deprecated then removed (set)", me["dep_removed"], {r[2] for r in by["deprecated_removed"]})
    check("builtins added (set)", me["b_added"], {r[2] for r in by["builtin_added"]})
    check("builtins removed (set)", me["b_removed"], {r[2] for r in by["builtin_removed"]})
    check("builtins re-signed (set)", me["b_changed"], {r[2] for r in by["builtin_changed"]})
    check("builtins doc-only (set)", me["b_doc"], {r[2] for r in by["builtin_doc_changed"]})
    check("resolved values changed (set)", me["values"], {(r[2], r[5], r[6]) for r in by["value_changed"]})
    check("doc-only changes (path→hint)", me["docs"], {r[2]: (r[7] == "hint") for r in by["doc_changed"]})

    # Human report agrees with the TSV.
    m = re.search(r"^(\d+) removed · (\d+) changed · (\d+) added", human, re.M)
    check("human header: removed", len(me["removed"]), int(m.group(1)))
    check("human header: changed", len(me["changed"]), int(m.group(2)))
    check("human header: added", len(me["added"]), int(m.group(3)))
    mm = re.search(r"(\d+) moves inferred", human)
    check("human header: moves", len(me["moves"]), int(mm.group(1)) if mm else 0)
    mt = re.search(r"(\d+) of them enum tags", human)
    check("human header: enum tags", len(me["tags_r"]) + len(me["tags_a"]), int(mt.group(1)) if mt else 0)
    check("human: moved section", len(me["moves"]), section_count(human, "moved"))
    check("human: enum tag sets", len(me["enums"]), int(re.search(r"^## enum tag sets \((\d+) enums\)", human, re.M).group(1)))
    check("human: deprecations", len(me["newly"]) + len(me["lifted"]) + len(me["dep_removed"]), section_count(human, "deprecations"))
    check("human: builtins", len(me["b_added"]) + len(me["b_removed"]) + len(me["b_changed"]) + len(me["b_doc"]), section_count(human, "builtins"))
    check("human: resolved values", len(me["values"]), section_count(human, "resolved values"))
    md = re.search(r"^## docs changed, declaration unchanged \((\d+); (\d+) say", human, re.M)
    check("human: doc changes", len(me["docs"]), int(md.group(1)) if md else 0)
    check("human: doc changes flagged", sum(me["docs"].values()), int(md.group(2)) if md else 0)
    mv_from = {f for f, _, _ in me["moves"]}
    check("human: removed listed = removed − tags − moves", len(me["removed"]) - len(me["tags_r"]) - len(mv_from & me["removed"]), section_count(human, "removed"))
    mv_to = {t for _, t, _ in me["moves"]}
    check("human: added listed = added − tags − moves", len(me["added"]) - len(me["tags_a"]) - len(mv_to & me["added"]), section_count(human, "added"))

    # Identities.
    ident = []
    both_pub_old = {p for p in me["both"] if old.decl[p]["vis"] == "pub"}
    both_pub_new = {p for p in me["both"] if new.decl[p]["vis"] == "pub"}
    ident.append(("I1 |pub(old)| = |removed| + |both, pub in old|", len(me["O"]), len(me["removed"]) + len(both_pub_old)))
    ident.append(("I2 |pub(new)| = |added| + |both, pub in new|", len(me["N"]), len(me["added"]) + len(both_pub_new)))
    ident.append(("I5 moves bijective, from ⊆ removed, to ⊆ added",
                  (len(mv_from), len(mv_to), mv_from <= me["removed"], mv_to <= me["added"]), (len(me["moves"]), len(me["moves"]), True, True)))
    mod = lambda p: ".".join(p.split(".")[:2])
    tal = Counter()
    for p in me["removed"]:
        tal[(mod(p), "r")] += 1
    for p in me["added"]:
        tal[(mod(p), "a")] += 1
    for p in me["changed"]:
        tal[(mod(p), "c")] += 1
    ident.append(("I6 Σ module tallies = totals", (sum(v for (m_, k), v in tal.items() if k == "r"), sum(v for (m_, k), v in tal.items() if k == "c"), sum(v for (m_, k), v in tal.items() if k == "a")),
                  (len(me["removed"]), len(me["changed"]), len(me["added"]))))
    classes = Counter(me["sigclass"].values())
    both_sig_differ = sum(1 for p, (o, n) in me["changed"].items() if o["sig"] and n["sig"] and normalize(o["sig"]) != normalize(n["sig"]))
    ident.append(("I7 Σ sig classes = changed with two differing sigs", sum(v for k, v in classes.items() if k not in ("", "sig_dropped", "sig_gained")), both_sig_differ))
    ident.append(("I7 sig_dropped = changed with old sig only", classes["sig_dropped"], sum(1 for o, n in me["changed"].values() if o["sig"] and not n["sig"])))
    ident.append(("I7 blank detail = changed with same sig", classes[""], sum(1 for o, n in me["changed"].values() if (o["sig"] is None and n["sig"] is None) or (o["sig"] and n["sig"] and normalize(o["sig"]) == normalize(n["sig"])))))
    per_enum = Counter(parent(p) for p in me["tags_r"] | me["tags_a"])
    ident.append(("I8 Σ enum tag rows = removed tags + added tags", sum(per_enum.values()), len(me["tags_r"]) + len(me["tags_a"])))
    ident.append(("I9 newly ∩ lifted = ∅; dep_removed ⊆ removed", (len(me["newly"] & me["lifted"]), me["dep_removed"] <= me["removed"]), (0, True)))
    # I10 manifests
    man_ok, man_n = True, 0
    for v in (old_v, new_v):
        d = vd(v)
        for man in sorted(d.glob("SHA256SUMS*")):
            for line in man.read_text().splitlines():
                hexd, rel = line.split("  ", 1)
                man_n += 1
                if hashlib.sha256((d / rel).read_bytes()).hexdigest() != hexd:
                    man_ok = False
    ident.append((f"I10 all {man_n} manifest entries verify (sha256)", man_ok, True))
    for name, lhs, rhs in ident:
        ok = lhs == rhs
        rows.append((name, lhs, rhs, ok))
        if not ok:
            fails.append(name)

    # Report.
    w = max(len(r[0]) for r in rows)
    print(f"verify-diff {old_v} → {new_v}   (independent Python vs zig-out/bin/zephem; sets compared, counts shown)\n")
    print(f"{'quantity / identity'.ljust(w)}  {'independent':>14}  {'tool / rhs':>14}  ok")
    for name, a, b, ok in rows:
        print(f"{name.ljust(w)}  {str(a):>14}  {str(b):>14}  {'✓' if ok else '✗ MISMATCH'}")
    classes_line = " · ".join(f"{classes[k]} {k}" for k in ("arity", "order", "types", "return_type", "error_set", "names", "sig_dropped", "sig_gained", "format", "other") if classes[k])
    print(f"\nsignature classes (independent): {classes_line}")
    print(f"move support (independent): {Counter(s for _, _, s in me['moves'])}")
    if fails:
        print(f"\n✗ {len(fails)} disagreement(s): {', '.join(fails)}")
        sys.exit(1)
    print(f"\n✓ every set, count and identity agrees ({len(rows)} checks)")


if __name__ == "__main__":
    main()
