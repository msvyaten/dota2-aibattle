"""Contract tests for the shared telemetry parser and betting lead curve."""

import betting as b
from aibattle_log import extract_telemetry, find_log
from aibattle_log import blocked_reason_counts, field_counts, rune_bottle_summary


def _text(*rows):
    return "\n".join(f"x 'AIB[{side}] {body}'" for side, body in rows)


def test_shared_parser_keeps_engineering_fields_and_earned_gold():
    telemetry = extract_telemetry(_text(
        ("R", "t=5s hp=90% gold=300 loc=1,2 lh=1 dn=0 dg=+40 dlh=+1 bottle=0"),
        ("R", "t=10s hp=80% gold=250 loc=3,4 lh=1 dn=0 dg=-50 dlh=+0 bottle=0"),
    ))
    assert telemetry["R"][0]["loc"] == (1.0, 2.0)
    assert telemetry["R"][0]["bottle"] == 0
    assert [sample["earned"] for sample in telemetry["R"]] == [40, 40]


def test_shared_parser_counts_intent_fields_and_blocked_reasons():
    text = "\n".join([
        "x 'AIB[R] intent=rune-transaction source=bottle-rune phase=stage_follow ttl=4 dist=300'",
        "x 'AIB[R] intent=rune-result source=bottle-rune result=filled age=2'",
        "x 'AIB[R] blocked=bottle-rune reason=no_close_rune max=1900 water=4300'",
        "x 'AIB[D] blocked=bottle-rune reason=stage_cooldown eta=18'",
    ])
    assert field_counts(text, "rune-transaction", "R", "phase")["stage_follow"] == 1
    assert field_counts(text, "rune-result", "R", "result")["filled"] == 1
    assert blocked_reason_counts(text, "bottle-rune", "R")["no_close_rune"] == 1


def test_rune_bottle_summary_keeps_transactions_and_blocks_together():
    text = "\n".join([
        "x 'AIB[R] intent=rune-transaction source=bottle-rune phase=stage_commit ttl=30 dist=700'",
        "x 'AIB[R] intent=rune-transaction source=recovery-rune-bottle phase=stage_follow ttl=8 dist=120'",
        "x 'AIB[R] intent=rune-result source=bottle-rune result=gone age=4'",
        "x 'AIB[R] blocked=recovery-rune-bottle reason=spot_race_lost stage=1'",
    ])
    summary = rune_bottle_summary(text, "R")
    assert summary["phase"]["stage_commit"] == 1
    assert summary["phase"]["stage_follow"] == 1
    assert summary["result"]["gone"] == 1
    assert summary["blocked"]["recovery-rune-bottle:spot_race_lost"] == 1


def test_betting_pairs_the_same_shared_stream():
    telemetry = extract_telemetry(_text(
        ("R", "t=5s hp=90% gold=300 loc=0,0 lh=2 dg=+80"),
        ("D", "t=6s hp=80% gold=400 loc=0,0 lh=1 dg=+40"),
    ))
    pairs = b.pair_streams(telemetry)
    assert len(pairs) == 1
    assert pairs[0]["gold_lead"] == 40
    assert pairs[0]["lh_lead"] == 1


def test_betting_pairs_state_market_fields_and_normalizes_lane_front():
    telemetry = extract_telemetry(_text(
        ("R", "t=5s hp=90% gold=300 loc=0,0 enemy-dist=700 lh=2 dg=+80 lvl=2 front=7000 ehp=80"),
        ("D", "t=6s hp=80% gold=400 loc=0,0 enemy-dist=710 lh=1 dg=+40 lvl=1 front=8500 ehp=90"),
        ("R", "t=10s hp=70% gold=320 loc=0,0 enemy-dist=500 lh=3 dg=+20 lvl=3 front=7300 ehp=30"),
        ("D", "t=11s hp=30% gold=420 loc=0,0 enemy-dist=510 lh=1 dg=+20 lvl=2 front=8400 ehp=70"),
    ))
    pairs = b.pair_streams(telemetry)
    assert pairs[0]["hp_lead"] == 10
    assert pairs[0]["level_lead"] == 1
    assert pairs[0]["lane_pressure"] == 0
    assert pairs[1]["lane_pressure"] == 400
    assert pairs[1]["contact_dist"] == 500


def test_state_markets_count_low_hp_and_actionable_kill_pressure():
    pairs = [
        {"t": 0.0, "hp_r": 80.0, "hp_d": 70.0, "hp_lead": 10.0,
         "level_lead": 0, "lane_pressure": 0, "contact_dist": 500.0},
        {"t": 5.0, "hp_r": 70.0, "hp_d": 30.0, "hp_lead": 40.0,
         "level_lead": 1, "lane_pressure": 200, "contact_dist": 600.0},
        {"t": 10.0, "hp_r": 60.0, "hp_d": 25.0, "hp_lead": 35.0,
         "level_lead": 1, "lane_pressure": 300, "contact_dist": 1200.0},
    ]
    state = b.state_markets(pairs)
    assert state["low_hp"]["D"]["seconds"] == 5.0
    assert state["kill_pressure"]["R"]["seconds"] == 5.0
    assert state["kill_pressure"]["R"]["episodes"] == 1
    assert state["level"]["final"] == 1


def test_strategy_fingerprint_and_series_require_side_swap():
    def announce(r_harass, d_harass):
        return _text(
            ("R", f"harass={r_harass} farm=0.5"),
            ("R", "defend=0.5 dive=finish_only"),
            ("R", "hero=default deny=default"),
            ("D", f"harass={d_harass} farm=0.5"),
            ("D", "defend=0.5 dive=finish_only"),
            ("D", "hero=default deny=default"),
        )

    first = b.strategy_fingerprints(announce("0.2", "0.8"))
    swapped = b.strategy_fingerprints(announce("0.8", "0.2"))
    fixed = [("a", {"strategies": first}), ("b", {"strategies": first})]
    proper = [("a", {"strategies": first}), ("b", {"strategies": swapped})]
    assert b.series_config_status(fixed)["ok"] is False
    assert b.series_config_status(proper)["swapped"] is True


def test_betting_deaths_use_shared_hp_samples():
    telemetry = extract_telemetry(_text(
        ("D", "t=5s hp=10% gold=1 loc=0,0"),
        ("D", "t=10s hp=0% gold=1 loc=0,0"),
    ))
    assert b.deaths_from_hp(telemetry)["D"] == [10.0]


def test_find_log_accepts_direct_path(tmp_path):
    path = tmp_path / "console.123.log"
    path.write_text("test", encoding="utf-8")
    assert find_log(path) == path
