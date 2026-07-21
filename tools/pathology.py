"""Find watchability pathologies from position samples alone: stalls and yo-yos.

Usage: python tools/pathology.py [matchid]      (no id = every current-stack log)

The scorecard answers "is the aggregate within limits". This answers the question the
user actually asks, which is "why did it look stupid at 6:19". It reads only the
`t=..s hp=..% loc=..` samples -- the most trustworthy evidence tier -- and flags two
shapes over a ~15s sliding window with no last hit in it:

  STALL  path < 160u   -- alive, in lane, and did not move
  YOYO   path > 900u and net < 300u  -- walked a long way to end up where it started

Both are reported with the HP delta, because that is what separates a legitimate regen
trip (hp climbs, the walk bought something) from a wasted one. Found the anti-idle-lane
bug this way: 8906755360 D t=107-122, path=2012u, net=17u, hp 44->36%, zero last hits --
the idle watchdog walking a damaged bot to the lane front and recovery dragging it back.

Feed a flagged window straight into a narrow grep of the same time range; do NOT dump the
whole log. Episodes that overlap are merged so one pathology is reported once.
"""
import glob
import math
import os
import re
import sys

import scorecard as sc

SAMPLE = re.compile(
    r"AIB\[([RD])\] t=(\d+)s hp=(\d+)% gold=\d+ loc=(-?\d+),(-?\d+)"
    r"(?: enemy-dist=\d+)? lh=(\d+)")

WINDOW = 4          # samples (~15-20s at the ~5s sample cadence)
STALL_PATH = 160    # units walked over the window
YOYO_PATH = 900
YOYO_NET = 300
IN_LANE = 4000      # |lane-axis| beyond this is base/jungle, not a lane pathology


def archetype(text, side):
    h = re.search(r"AIB\[%s\] harass=([0-9.]+)" % side, text)
    return {"0.90": "brawler", "0.55": "farmer", "0.85": "pusher"}.get(h.group(1), "?") if h else "?"


def merge(episodes):
    out = []
    for e in episodes:
        if out and e[0] <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e[1])) + out[-1][2:]
        else:
            out.append(e)
    return out


def scan(path):
    text = open(path, encoding="utf-8", errors="ignore").read()
    pts = {"R": [], "D": []}
    for m in SAMPLE.finditer(text):
        pts[m.group(1)].append(tuple(int(m.group(i)) for i in (2, 3, 4, 5, 6)))
    print("== %s" % os.path.basename(path)[8:-4])
    for side in ("R", "D"):
        alive = [v for v in pts[side] if v[1] > 0]
        if len(alive) < 10:
            continue
        stalls, yoyos = [], []
        for i in range(len(alive) - WINDOW + 1):
            w = alive[i:i + WINDOW]
            span = w[-1][0] - w[0][0]
            if not 12 <= span <= 26:            # a gap here means death or a log break
                continue
            if any(abs((v[2] + v[3]) / math.sqrt(2)) >= IN_LANE for v in w):
                continue
            if w[-1][4] != w[0][4]:             # got a last hit -> the time was not wasted
                continue
            path_len = sum(math.hypot(b[2] - a[2], b[3] - a[3]) for a, b in zip(w, w[1:]))
            net = math.hypot(w[-1][2] - w[0][2], w[-1][3] - w[0][3])
            if path_len < STALL_PATH:
                stalls.append((w[0][0], w[-1][0], int(path_len), w[0][1], w[-1][1]))
            elif path_len > YOYO_PATH and net < YOYO_NET:
                yoyos.append((w[0][0], w[-1][0], int(path_len), int(net), w[0][1], w[-1][1]))
        stalls, yoyos = merge(stalls), merge(yoyos)
        print("  [%s] %-8s stalls=%d yoyo=%d" % (side, archetype(text, side), len(stalls), len(yoyos)))
        for e in stalls:
            print("      STALL t=%d-%ds path=%du hp %d->%d%%" % e)
        for e in yoyos:
            print("      YOYO  t=%d-%ds path=%du net=%du hp %d->%d%%" % e)


def main(match_id=None):
    if match_id:
        scan(str(sc.DOTA_LOG_DIR / ("console.%s.log" % match_id)))
        return
    for p in sorted(glob.glob(str(sc.DOTA_LOG_DIR / "console.89*.log"))):
        scan(p)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
