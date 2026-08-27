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


def _minutes(text):
    """Match length in minutes, from the last t= sample on either side."""
    vals = [int(v) for v in re.findall(r"AIB\[[RD]\] t=(\d+)s", text)]
    return (max(vals) / 60.0) if vals else 0.0


def buy_loop(text, side):
    """Both ways the buy loop can stop spending, kept apart.

    'saving' = the head component costs more than we have, which is legitimate right up
    until the component is unreachable for the rest of the match. 'stalled' = the component
    queue is empty and the target never assembled. The gold curve cannot tell these apart --
    both read as a flat line with a full wallet -- which is why the loop now says which.
    """
    out = {}
    for reason in ("saving", "stalled"):
        rows = re.findall(
            r"AIB\[%s\] blocked=buy-loop reason=%s ([^']*)" % (side, reason), text)
        out[reason] = (len(rows), rows[-1].strip() if rows else "")
    return out


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
        # The turn-around loop of 8924633108 [D]: the floor committed a trip because an enemy was
        # hitting the bot (a held salve cannot be drunk under fire) and the release fired two
        # seconds later because walking away had stopped the hitting -- five cycles, three of them
        # turning at 6251/6201/6252 units from home. break-contact should absorb those, so
        # heal_in_hand releases go to ~0 while break-contact carries the traffic.
        rel = re.findall(r"AIB\[%s\][^']*?blocked=fountain-floor reason=(\w+)" % side, text)
        by_reason = {r: rel.count(r) for r in sorted(set(rel))}
        # heal_in_flight is a legitimate release -- the cure is paid for and arriving, so the
        # walk home is wasted. What was missing is what happens next: 8925401611 [D] released
        # three times and then idled at 19-36% HP in the contested lane for most of a minute.
        # inflight-back is the owner for that window. It should track heal_in_flight releases.
        print("       inflight-back=%d hold=%d (owner for the courier wait)"
              % (diag_max(text, side, "heal-inflight-back"),
                 diag_max(text, side, "heal-inflight-hold")))
        print("       break-contact=%d (want UP) | trip releases: %s (heal_in_hand wants 0)"
              % (diag_max(text, side, "heal-break-contact"), by_reason or "none"))

    # 21.07 batch. empty_action was the top blocked reason on both sides (105/65 in
    # 8906632392) and the scorecard did NOT flag it -- empty/min read 8.4/5.2 against a
    # limit of 13. Always read the per-winner split, not the aggregate.
    # WHO ACTUALLY RAN THE MATCH. Five matches in I had never looked at this, and kept
    # reconstructing "what happened" from narrow windows around the user's timestamps instead.
    # 8925526609 (first melee match) is why it is here: anti-idle -- the watchdog that exists
    # for when nothing else acted -- was the top tick owner for [R] at 91, ahead of fight and
    # farm. That is the shape of the melee problem in one line, and no other panel showed it.
    print("----- who owned the ticks (arbiter winners, whole match) -----")
    for side in ("R", "D"):
        wins = re.findall(r"AIB\[%s\] intent=top-arbiter family=state winner=([a-z-]+):" % side, text)
        top = collections.Counter(wins).most_common(8)
        print("  [%s] n=%d | %s"
              % (side, len(wins), ", ".join("%s=%d" % (k, v) for k, v in top) or "none"))

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
        # Sustain economy. The bought/drunk pair is the point: 8925573332 read bought 3-4 and
        # drunk 2-3 for a whole 17-minute match spent a third of the time under 45% hp, with
        # the third salve refused at hp=26 gold=1518 by a lifetime count cap. Want bought and
        # drunk UP and budget_cap near 0 while gold is high; regen/walk are the do-nothing
        # answer to low HP and should come DOWN as the consumables come up.
        # recovery-enemy-near is the third gate, now visible: recovery() bails whole when an
        # enemy is inside 900, which is 68% of the match and 50-67% of every low-HP sample.
        # bought=0 with budget_cap=0 used to have no third explanation; this is it. The buy
        # now also runs at that gate, so bought must rise while the gate count stays high --
        # the gate is correct for everything except purchasing.
        # ward-seen is the denominator that tells "never attacked it" apart from "it was never
        # there". The real acceptance is one line down in the betting report: mutual low must
        # become non-zero for the first time in any match on record.
        # seen is scanned at 900, hit only within attack range. If out-of-reach dominates, the
        # ward is up and the melee hero simply cannot touch it -- that calls for an approach
        # leg, not a bigger swing radius.
        print("       heal ward: seen=%d hit=%d out-of-reach=%d (seen=0 means it never happened,"
              " not that the fix failed)"
              % (diag_max(text, side, "ward-seen"), diag_max(text, side, "ward-hit"),
                 diag_max(text, side, "ward-out-of-reach")))
        print("       recovery gate: enemy-near=%d (bails the whole function; buy exempted)"
              % diag_max(text, side, "recovery-enemy-near"))
        # heal-want is the denominator the sustain thread never had: how often the bot stood
        # there wanting to drink WITH a salve in hand. want >> item means something is refusing,
        # and heal-blocked-damage names the only guard left. Before 03.08 the refusal was
        # silent, which is why three sessions chased purchase caps instead of the drink.
        print("       drink gate: want=%d -> drank=%d | blocked: hero damage=%d trip committed=%d"
              % (diag_max(text, side, "heal-want"), diag_max(text, side, "heal-item"),
                 diag_max(text, side, "heal-blocked-damage"),
                 diag_max(text, side, "heal-skip-trip-committed")))
        print("       sustain: bought=%d (+critical %d) drunk flask=%d tango=%d heal-item=%d"
              " | blocked budget_cap=%d flask_in_bag=%d | stand-and-regen=%d walk=%d"
              % (diag_max(text, side, "recovery-buy"), diag_max(text, side, "recovery-buy-critical"),
                 diag_max(text, side, "recovery-flask"), diag_max(text, side, "recovery-tango"),
                 diag_max(text, side, "heal-item"),
                 occ(text, side, "blocked=recovery-buy reason=budget_cap"),
                 occ(text, side, "blocked=recovery-buy reason=flask_in_inventory"),
                 diag_max(text, side, "recovery-regen"), diag_max(text, side, "regen-walk")))
        # Option 3 (03.08): creep-work stops walking a ranged hero into the pack, so spacing
        # no longer has to freeze to prevent it. Read as a pair -- release UP and hold DOWN is
        # the fix working; jitter or lane-line episodes rising means the walk-in returned
        # through another owner, and the RELEASE is what to revert, not the creep-work guard.
        print("       ranged spacing: hold=%d release=%d walk-in refused=%d (want hold DOWN, jitter flat)"
              % (diag_max(text, side, "melee-pack-hold"), diag_max(text, side, "melee-pack-release"),
                 diag_max(text, side, "cs-walk-into-pack")))
        print("       melee-pack(3e64ecb): inside_melee_pack=%d | creep-hit-react atk=%d step=%d back=%d"
              % (occ(text, side, "blocked=creep-hit-react reason=inside_melee_pack"),
                 diag_max(text, side, "creep-hit-react-atk"),
                 diag_max(text, side, "creep-hit-react-step"),
                 diag_max(text, side, "creep-hit-react-back")))
        # The step branches used to park the bot at 475 units from the pack centroid -- inside
        # the ~500 creep acquisition band -- so stepping and not stepping cost the same HP.
        # The number that decides whether this worked is the creep share of damage taken, NOT
        # the step count: 8924633108 [D] already stepped nine times and still ate 24%.
        # BOTH step branches use the widened aggroStep distance -- the aggro-step counter only
        # covers the repeated-damage path, so reading it alone said "never fires" for three
        # matches while creep-hit-react-step was doing the work 7-12 times a game. Print the pair,
        # and remember the verdict is the creep+mixed damage share, not either count.
        print("       steps: aggro-step=%d + edge-step=%d (both use the widened distance)"
              % (diag_max(text, side, "creep-hit-react-aggro-step"),
                 diag_max(text, side, "creep-hit-react-step")))
        # recovery-timeout was structurally 0: the empty-bottle branch reset the latch that
        # feeds its 10s timer on every tick. Non-zero here is the fix landing, not a fault.
        print("       recovery-latch(b4b24af): recovery-timeout=%d (was structurally 0) | wait=%d yield=%d"
              % (diag_max(text, side, "recovery-timeout"),
                 diag_max(text, side, "recovery-wait"), diag_max(text, side, "recovery-yield")))
        # KNOWN RISK of 70999f0, check it here rather than being surprised: below 0.45 the
        # only remaining AntiIdleGlobal legs are assist (needs an ally -- none in 1v1) and
        # creep (gated off for last_hit_only), so the watchdog now declines those ticks
        # entirely. Standing still while regenerating is the intended look, but if `idle` or
        # anti-idle@2 empty-wins spike, the bot is being left with no owner too often.
        # enter and idle are the ONLY two counters in this block that share a rate limit
        # (DiagRL 3s), so they are the only pair that may be divided by each other. lane and
        # lowhp-back are DiagRL 5s, combat is a plain Diag -- reading "lane=70 vs combat=5" as
        # a ratio is the mistake this line used to invite. 8925573332 [R]: 102 of 158
        # activations ended in no action at all, and the melee pair sits at 57-66% against
        # 29-49% on SF, i.e. the watchdog both fires more often and comes back emptier.
        n_enter = diag_max(text, side, "anti-idle-enter")
        n_idle = diag_max(text, side, "idle")
        pct = ("%d%%" % round(100.0 * n_idle / n_enter)) if n_enter else "n/a"
        print("       anti-idle(70999f0): enter=%d -> did nothing %d (%s of them) [same RL, comparable]"
              % (n_enter, n_idle, pct))
        print("         legs (RL5): lane=%d (want DOWN) lowhp-back=%d push=%d | (RL3): lowhp-step=%d"
              " | (plain): combat=%d creep=%d lowhp-cs=%d | empty-wins=%d"
              % (diag_max(text, side, "anti-idle-lane"), diag_max(text, side, "anti-idle-lowhp-back"),
                 diag_max(text, side, "anti-idle-push"),
                 diag_max(text, side, "anti-idle-lowhp-step"),
                 diag_max(text, side, "anti-idle-combat"), diag_max(text, side, "anti-idle-creep"),
                 diag_max(text, side, "anti-idle-lowhp-cs"),
                 occ(text, side, "reason=empty_action winner=anti-idle")))
        print("       no_sustain(183a5f7): no_sustain_floor=%d (was structurally 0) | regen_lane_floor=%d"
              % (occ(text, side, "reason=no_sustain_floor"), occ(text, side, "reason=regen_lane_floor")))
        print("       deny probe(d418d34): deny-act=%d = atk %d + walk %d | skip-backtrack=%d -> dn=%s"
              % (diag_max(text, side, "deny-act"), diag_max(text, side, "deny-act-atk"),
                 diag_max(text, side, "deny-act-walk"), diag_max(text, side, "deny-skip-backtrack"),
                 last_stat(text, side, "dn")))
        # The kill test now runs for BOTH deny policies, so the acceptance has to read both
        # halves: deny-act (effort spent) must fall while dn (denies landed) must not.
        # rejected: doomed = somebody else finishes it first, tanky = our hit never kills it.
        print("       deny kill-test: rejected doomed=%d tanky=%d (want deny-act DOWN, dn same or UP)"
              % (diag_max(text, side, "deny-cand-doomed"), diag_max(text, side, "deny-cand-tanky")))
        # Per-hero kill-window multiplier (Style.AttackDamageMult). Juggernaut declares
        # base=2.0 / burst=3.0; every other hero still answers 3.0, so exec and mutual are the
        # control legs -- they must hold while atk falls. All plain counters, so the legs are
        # comparable to the scan denominator and to each other.
        #
        # `narrowed` is the direct measurement and the one to read first: enemies the old
        # Shadow Fiend 3.0 would have called killable and this hero's own number does not.
        # narrowed=0 means the change did nothing -- no verdict, not a pass.
        scan = diag_max(text, side, "killwin-scan")
        print("       kill window: scan=%d -> atk=%d exec=%d mutual=%d | NARROWED=%d"
              " (0 = the change never bit; not a pass)"
              % (scan, diag_max(text, side, "killwin-atk"), diag_max(text, side, "killwin-exec"),
                 diag_max(text, side, "killwin-mutual"),
                 diag_max(text, side, "killwin-atk-narrowed")))
        bl = buy_loop(text, side)
        print("       buy loop: saving x%d %s" % (bl["saving"][0], bl["saving"][1] or "(silent)"))
        print("                 stalled x%d %s" % (bl["stalled"][0], bl["stalled"][1] or "(silent)"))
        # ead1e05's signature was unobservable until 9e74621 moved it to the mirror in
        # mode_laning_generic, where the decision is actually taken.
        print("       recovery_commit(now observable): %d"
              % occ(text, side, "blocked=creep-hit-react reason=recovery_commit"))
        # 8907379308 batch. The twitch pair is judged PER MINUTE -- raw counts scale with
        # game length and 8907379308 ran 13.7 min. Baseline there: fwd-position 137 (10/min),
        # hero-prio-chase 166 (12/min), both re-issuing every tick.
        mins = _minutes(text)
        rate = lambda k: diag_max(text, side, k) / mins if mins else 0
        print("       twitch(39e3e6b): fwd-position=%.1f/min (was 10.0) hero-prio-chase=%.1f/min"
              " (was 12.1) | holds: motor=%d chase=%d"
              % (rate("fwd-position"), rate("hero-prio-chase"),
                 diag_max(text, side, "fwd-suppressed-motor"),
                 diag_max(text, side, "hero-prio-chase-hold")))
        print("       salve-on-trip(e344e49): fountain_trip_committed=%d | fountain-wait=%d"
              % (occ(text, side, "blocked=heal-item reason=fountain_trip_committed"),
                 diag_max(text, side, "fountain-wait")))

    # Damage attribution (21.07). Cumulative, so take the LAST line per side. creep/tower/hero
    # are lower bounds -- ticks with two live sources land in `mixed` rather than being split.
    # Tower pokes were endemic -- 14 of 16 sides in the era took tower damage, and the siege
    # loop owned the windows where it grew. This line is the acceptance for the backoff: the
    # signature must be non-zero AND the tower share must fall.
    print("----- watch: tower pokes (siege backoff) -----")
    # backoff was 0 in every match on record because both CanAct and Think refused the tick
    # exactly when the tower had picked us -- the escape sat behind the gate that fires when
    # the escape is needed. Acceptance: backoff > 0 AND the tower share of damage taken (see
    # the damage-by-source block) DOWN, with commit/terminal holding. commit/terminal
    # collapsing means the reordering turned sieging off rather than fixing the exit.
    for side in ("R", "D"):
        print("  [%s] backoff=%d (was structurally 0; want UP) parked=%d (yielded, not idle)"
              " aggro-drop=%d no-dive=%d | siege commit=%d terminal=%d (want HELD)"
              % (side, diag_max(text, side, "siege-tower-backoff"),
                 diag_max(text, side, "siege-backoff-parked"),
                 diag_max(text, side, "tower-aggro-drop"), diag_max(text, side, "no-dive"),
                 diag_max(text, side, "siege-commit-tower"),
                 diag_max(text, side, "siege-terminal-tower")))

    print("----- watch: damage by source (lower bounds; mixed = ambiguous) -----")
    for side in ("R", "D"):
        hits = re.findall(
            r"AIB\[%s\] intent=damage-by-source[^']*?creep=(\d+) tower=(\d+) hero=(\d+) mixed=(\d+)"
            r"(?: death=(\d+))? other=(\d+)(?: stale=(\d+) gaps=(\d+))?" % side, text)
        if not hits:
            print("  [%s] (no samples -- probe not in this build)" % side)
            continue
        c, t, h, m, dth, o, st, gaps = (int(x or 0) for x in hits[-1])
        tot = c + t + h + m + dth + o + st
        pct = lambda v: (100 * v // tot) if tot else 0
        # v3 splits the old `other` in two, because they call for opposite responses:
        #   other = damage that arrived with NO flag -> a real gap in what we model
        #   stale = sample gap wider than the flags reach -> our own measurement blind spot
        # Averaging them into one number is what made v1/v2 unreadable. Verdict now names
        # whichever one is actually spoiling the readout.
        note = ""
        if pct(st) > 10:
            note = "  <-- SAMPLING GAPS, stale=%d%% over %d gaps" % (pct(st), gaps)
        elif pct(o) > 15:
            note = "  <-- UNTRUSTED, other>15%"
        print("  [%s] total=%d | creep=%d(%d%%) tower=%d(%d%%) hero=%d(%d%%) mixed=%d(%d%%) "
              "death=%d(%d%%) other=%d(%d%%) stale=%d(%d%%)%s"
              % (side, tot, c, pct(c), t, pct(t), h, pct(h), m, pct(m), dth, pct(dth),
                 o, pct(o), st, pct(st), note))

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

    # Level over time. In a 1v1 mid the level gap decides trades harder than gold, and it was
    # unrecorded until c69c279 -- so "why did he lose that exchange five to one" could never be
    # answered with "he was a level down". Prints as a per-minute pair, and "n/a" for logs from
    # before the field existed rather than pretending the gap was zero.
    # front = distance from that side's own fountain to its wave front. Both sides report the
    # same contested point from opposite ends, so the pair reads as equilibrium: R rising while
    # D falls means Radiant is pushing. Whoever holds the wave decides under whose tower creeps
    # die and who farms safely -- until fd6742b this was only ever inferred from side evidence.
    print("----- level curve and lane equilibrium (per minute) -----")
    lv = {s: dict() for s in ("R", "D")}
    fr = {s: dict() for s in ("R", "D")}
    for s, t, l in re.findall(r"AIB\[([RD])\] t=(\d+)s[^']*? lvl=(-?\d+)", text):
        lv[s].setdefault(int(t) // 60, int(l))
    for s, t, f in re.findall(r"AIB\[([RD])\] t=(\d+)s[^']*? front=(-?\d+)", text):
        fr[s].setdefault(int(t) // 60, int(f))
    if not lv["R"] and not lv["D"]:
        print("  n/a -- log predates the lvl= / front= fields")
    else:
        mins = sorted(set(lv["R"]) | set(lv["D"]))
        print("  min:      " + " ".join("%5d" % m for m in mins))
        for s in ("R", "D"):
            print("  lvl  [%s]: " % s + " ".join("%5s" % lv[s].get(m, "-") for m in mins))
        # The value each side reports at minute 0 -- before creeps exist -- is what
        # GetLaneFrontLocation gives with no wave to measure. It recurs mid-match (8925526609
        # [R] printed 7078 at minutes 0, 4, 11 and 15), and printed bare it reads as a hard
        # push that never happened. Mark it rather than let it pass as data: same defect class
        # as decided_at returning the end of the match when it had no leader to trace.
        for s in ("R", "D"):
            base = fr[s].get(0)
            cells = []
            for m in mins:
                v = fr[s].get(m)
                cells.append("-" if v is None else ("(n/a)" if base is not None and v == base else str(v)))
            print("  front[%s]: " % s + " ".join("%5s" % c for c in cells))
        print("             (n/a = the no-wave default this side reports at minute 0)")

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
