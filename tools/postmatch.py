"""Post-match frugal review: scorecard + this session's fix signatures in ONE command.

Usage: python tools/postmatch.py <matchid> [...]

Prints a compact report (no raw log dump) per the frugal-forensics rule: scorecard
verdict, then the specific signatures the current fixes are validated against, then
a jitter-key breakdown (which handler dominates) and an archetype contrast row.
Keep this the default post-match tool so a review costs ~20 lines, not a log dump.
"""
import collections
import re
import sys

import scorecard as sc  # tools/ is on sys.path when run as python tools/postmatch.py


def diag_max(text, side, key):
    """Max value of a cumulative 'key=N' diag counter for one side."""
    return sc.side_counter_max(text, side, key)


def occ(text, side, pat):
    """Count of AIB[side] lines matching a raw substring pattern."""
    return len(re.findall(r"AIB\[%s\][^']*%s" % (side, pat), text))


def last_stat(text, side, key):
    vals = re.findall(r"AIB\[%s\][^']*\b%s=(-?\d+)" % (side, re.escape(key)), text)
    return vals[-1] if vals else "?"


def last_time(text, side):
    vals = re.findall(r"AIB\[%s\] t=(\d+)s" % side, text)
    return vals[-1] if vals else "?"


def recovery_owner_counts(text, side):
    lines = re.findall(r"AIB\[%s\][^']*intent=recovery-owner[^']*" % side, text)
    counts = {
        "total": len(lines),
        "critical": 0,
        "soft": 0,
        "caution": 0,
        "threat": 0,
    }
    for line in lines:
        for band in ("critical", "soft", "caution"):
            if "band=%s" % band in line:
                counts[band] += 1
        if "threat=true" in line:
            counts["threat"] += 1
    return counts


def report(match_id):
    ok = sc.scorecard(match_id)
    path = sc.DOTA_LOG_DIR / ("console.%s.log" % match_id)
    if not path.exists():
        return ok
    text = path.read_text(encoding="utf-8", errors="ignore")

    # Winner + config labels. Winner comes from the engine's "Winning team =" line
    # (same source as match_stats). Config guessed from the announce harass dial --
    # deaths must NOT be inferred from dg=-9x gold drops: those conflate ~100g
    # purchases with respawn losses (found 07.07 doing side-vs-config forensics).
    m = re.search(r"Winning team =\s*(\d)", text)
    win = {"0": "Radiant", "2": "Radiant", "1": "Dire", "3": "Dire"}.get(m.group(1), "?") if m else "?"
    def cfg(side):
        h = re.search(r"AIB\[%s\] harass=([0-9.]+)" % side, text)
        return {"0.90": "brawler", "0.55": "farmer", "0.85": "pusher"}.get(h.group(1), h.group(1)) if h else "?"
    print("----- outcome -----")
    print("  winner=%s | R=%s D=%s" % (win, cfg("R"), cfg("D")))

    print("----- watch: recover cap + dive floor + P3 owner episodes -----")
    for side in ("R", "D"):
        cap_veto = occ(text, side, "reason=no_action_capped")
        cap_hit = occ(text, side, "reason=hp_gate_no_action")
        no_dive = diag_max(text, side, "no-dive")
        owner = recovery_owner_counts(text, side)
        print("  [%s] recover_cap_veto=%d hp_gate_no_action=%d no-dive=%d | recovery-owner total=%d critical=%d soft=%d caution=%d threat=%d"
              % (side, cap_veto, cap_hit, no_dive, owner["total"], owner["critical"],
                 owner["soft"], owner["caution"], owner["threat"]))

    # 181b1f2 acceptance: obs4 greedy fountain top-off + obs5 no-sustain floor.
    # A fountain trip is only legitimate when recovery INITIATED it (plan action=
    # walk_fountain/tp_fountain) or the bot respawned into the aura. Any fountain-wait
    # without an initiating plan action = the greedy self-init regression coming back.
    print("----- watch: fountain fixes (181b1f2) -----")
    for side in ("R", "D"):
        init_skip = diag_max(text, side, "fountain-init-skip")
        f_wait = diag_max(text, side, "fountain-wait")
        f_bottle = diag_max(text, side, "fountain-bottle")
        f_tp = diag_max(text, side, "fountain-tp-lane")
        no_sustain = occ(text, side, "reason=no_sustain_floor")
        lane_floor = occ(text, side, "reason=regen_lane_floor")
        # trip_init MUST come from the plain Diag counters, not from recovery-plan Intent
        # lines: Style.Intent is rate-limited/deduped, so action=walk_fountain under-reports
        # badly (8906520389 [R]: recovery-walk=3 but zero intent lines -- which made a
        # legitimate hp<0.22 floor trip look like an uninitiated one and produced a wrong
        # "retreat anchor collapsed to the fountain" diagnosis). Same caveat applies to the
        # *_floor reason columns below: they are "logged", not "fired" -- treat as a lower bound.
        trip_init = (diag_max(text, side, "recovery-walk")
                     + diag_max(text, side, "recovery-tp"))
        print("  [%s] trip_init=%d fountain-wait=%d bottle=%d tp-lane=%d | init_skip=%d "
              "latch_drop=%d | logged-reason: no_sustain=%d regen_lane=%d (lower bound)"
              % (side, trip_init, f_wait, f_bottle, f_tp, init_skip,
                 diag_max(text, side, "fountain-latch-drop"), no_sustain, lane_floor))

    # 21.07 batch. empty_action was the top blocked reason on both sides (105/65 in
    # 8906632392) and the scorecard did NOT flag it -- empty/min read 8.4/5.2 against a
    # limit of 13. Always read the per-winner split, not the aggregate.
    print("----- watch: empty_action by winner (structural: capped/no-contract wins) -----")
    for side in ("R", "D"):
        tot = occ(text, side, "reason=empty_action")
        pairs = re.findall(r"AIB\[%s\][^']*?reason=empty_action winner=([a-z-]+) score=(\d+)" % side, text)
        top = collections.Counter("%s@%s" % (w, s) for w, s in pairs).most_common(4)
        print("  [%s] empty_action=%d | top: %s"
              % (side, tot, ", ".join("%s x%d" % (k, n) for k, n in top) or "none"))

    print("----- watch: 21.07 fix batch (one signature per fix) -----")
    for side in ("R", "D"):
        vetoes = {n: occ(text, side, "blocked=%s-candidate reason=no_action_capped" % n)
                  for n in ("fight", "safety", "siege", "recover", "power-rune")}
        print("  [%s] veto: %s" % (side, " ".join("%s=%d" % (k, v) for k, v in vetoes.items())))
        print("       visual-hold-still=%d (was vibrating) | still/lane=%d/%d | creep-react recovery_commit=%d"
              % (diag_max(text, side, "visual-hold-still"),
                 diag_max(text, side, "visual-hold-still"),
                 diag_max(text, side, "visual-hold-lane"),
                 occ(text, side, "blocked=creep-hit-react reason=recovery_commit")))
        print("       tp: recovery-tp=%d fountain-tp-lane=%d (both were structurally 0 before edd7a44)"
              % (diag_max(text, side, "recovery-tp"), diag_max(text, side, "fountain-tp-lane")))
        print("       archetype: ability-harass=%d execute=%d (farmer save_for_execute -> harass~0)"
              % (diag_max(text, side, "ability-harass"), diag_max(text, side, "execute")))

    # Current pending batch. Read this section FIRST after a match -- the panel above is the
    # previous batch, kept as a regression watch. One row per commit, in the order to debug
    # them if something moves the wrong way (the canAct vetoes are the widest-blast-radius
    # change: they hand ticks to lane work and can shift aggression either way).
    print("----- watch: pending batch (f942b46..9e74621) -----")
    for side in ("R", "D"):
        # Count the CONSUME sites only. The same reason string is also used by 543c0c1's buy
        # guard, which has been live for a while -- summing them would show the new fix
        # landing when only the old one fired.
        consume = (occ(text, side, "blocked=heal-item reason=fountain_floor_free_heal")
                   + occ(text, side, "blocked=recovery-flask reason=fountain_floor_free_heal"))
        print("  [%s] flask-guard(f942b46): consume-blocked=%d (heal-item + recovery-flask) "
              "| buy-blocked=%d (543c0c1, older)"
              % (side, consume, occ(text, side, "blocked=recovery-buy reason=fountain_floor_free_heal")))
        print("       melee-pack(3e64ecb): inside_melee_pack=%d | creep-hit-react atk=%d step=%d back=%d"
              % (occ(text, side, "blocked=creep-hit-react reason=inside_melee_pack"),
                 diag_max(text, side, "creep-hit-react-atk"),
                 diag_max(text, side, "creep-hit-react-step"),
                 diag_max(text, side, "creep-hit-react-back")))
        # recovery-timeout was structurally 0: the empty-bottle branch reset the latch that
        # feeds its 10s timer on every tick. Non-zero here is the fix landing, not a fault.
        print("       recovery-latch(b4b24af): recovery-timeout=%d (was structurally 0) | wait=%d yield=%d"
              % (diag_max(text, side, "recovery-timeout"),
                 diag_max(text, side, "recovery-wait"), diag_max(text, side, "recovery-yield")))
        print("       anti-idle(70999f0): anti-idle-lane=%d (want DOWN) enter=%d creep=%d push=%d"
              % (diag_max(text, side, "anti-idle-lane"), diag_max(text, side, "anti-idle-enter"),
                 diag_max(text, side, "anti-idle-creep"), diag_max(text, side, "anti-idle-push")))
        print("       no_sustain(183a5f7): no_sustain_floor=%d (was structurally 0) | regen_lane_floor=%d"
              % (occ(text, side, "reason=no_sustain_floor"), occ(text, side, "reason=regen_lane_floor")))
        print("       deny probe(d418d34): deny-act=%d = atk %d + walk %d | skip-backtrack=%d -> dn=%s"
              % (diag_max(text, side, "deny-act"), diag_max(text, side, "deny-act-atk"),
                 diag_max(text, side, "deny-act-walk"), diag_max(text, side, "deny-skip-backtrack"),
                 last_stat(text, side, "dn")))
        # ead1e05's signature was unobservable until 9e74621 moved it to the mirror in
        # mode_laning_generic, where the decision is actually taken.
        print("       recovery_commit(now observable): %d"
              % occ(text, side, "blocked=creep-hit-react reason=recovery_commit"))

    # Damage attribution (21.07). Cumulative, so take the LAST line per side. creep/tower/hero
    # are lower bounds -- ticks with two live sources land in `mixed` rather than being split.
    print("----- watch: damage by source (lower bounds; mixed = ambiguous) -----")
    for side in ("R", "D"):
        hits = re.findall(
            r"AIB\[%s\] intent=damage-by-source[^']*?creep=(\d+) tower=(\d+) hero=(\d+) mixed=(\d+)"
            r"(?: death=(\d+))? other=(\d+)" % side, text)
        if not hits:
            print("  [%s] (no samples -- probe not in this build)" % side)
            continue
        c, t, h, m, dth, o = (int(x or 0) for x in hits[-1])
        tot = c + t + h + m + dth + o
        pct = lambda v: (100 * v // tot) if tot else 0
        # other should now be small: probe v2 split deaths out and sized the flag window from
        # the real sample gap. If other is still >15%, the attribution is not to be trusted.
        print("  [%s] total=%d | creep=%d(%d%%) tower=%d(%d%%) hero=%d(%d%%) mixed=%d(%d%%) "
              "death=%d(%d%%) other=%d(%d%%)%s"
              % (side, tot, c, pct(c), t, pct(t), h, pct(h), m, pct(m), dth, pct(dth), o, pct(o),
                 "  <-- UNTRUSTED, other>15%" if pct(o) > 15 else ""))

    # Farm drivers. The cs-walk buckets are kept as ACTIVITY telemetry, not as a farm
    # diagnosis: across 133 side-matches (tools/farm_drivers.py) cs-walk/min correlates
    # +0.35 with lh/min, i.e. a high count means the bot is doing CS, not that it is out
    # of position. The count is side-determined (Radiant 11.7-13.4/min vs Dire 6.3-7.2/min
    # in the 2x2, archetype effect ~0), so R>D here is normal and not a finding. The real
    # predictor is time in the low-HP band (-0.40), which is what costs lane-minutes.
    print("----- watch: farm drivers (hp band = the predictor; cs-walk = activity) -----")
    for side in ("R", "D"):
        hp_samples = [int(v) for v in re.findall(r"AIB\[%s\] t=\d+s hp=(\d+)%%" % side, text)]
        alive = [v for v in hp_samples if v > 0]
        low = 100 * sum(1 for v in alive if v < 45) // len(alive) if alive else 0
        crit = 100 * sum(1 for v in alive if v < 25) // len(alive) if alive else 0
        print("  [%s] time hp<45%%=%d%% hp<25%%=%d%% (corr with lh/min: -0.40) | cs-walk=%d "
              "(inrange=%d gap_small=%d gap_LARGE=%d) last-hit-urgent=%d deny-act=%d"
              % (side, low, crit, diag_max(text, side, "cs-walk"),
                 diag_max(text, side, "cs-walk-inrange"), diag_max(text, side, "cs-walk-gap-small"),
                 diag_max(text, side, "cs-walk-gap-large"),
                 diag_max(text, side, "last-hit-urgent"), diag_max(text, side, "deny-act")))

    print("----- jitter breakdown (which key dominates the sum) -----")
    for side in ("R", "D"):
        parts = " ".join("%s=%d" % (k, diag_max(text, side, k)) for k in sc.JITTER_KEYS)
        # SPECS 3.10 step 1: episode count vs raw re-issues (informational until 2
        # matches of data, then JITTER_KEYS switches to episodes). anti-idle counters
        # surfaced for the "anti-idle as de-facto lane worker" watch (8905429441 R:
        # anti-idle-creep=169 dwarfed every jitter key; P1-C idle-band domain).
        ep = occ(text, side, "lane-line-episode")
        ai = " anti-idle-creep=%d anti-idle-combat=%d wave-watch=%d" % (
            diag_max(text, side, "anti-idle-creep"), diag_max(text, side, "anti-idle-combat"),
            diag_max(text, side, "wave-watch"))
        print("  [%s] %s | lane-line-episodes=%d |%s" % (side, parts, ep, ai))

    print("----- archetype contrast (bind check: R vs D) -----")
    for side in ("R", "D"):
        print("  [%s] lh=%s dn=%s bottle_last=%s last_t=%ss"
              % (side, last_stat(text, side, "lh"), last_stat(text, side, "dn"),
                 last_stat(text, side, "bottle"), last_time(text, side)))
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    results = [report(m) for m in sys.argv[1:]]
    sys.exit(0 if all(results) else 1)
