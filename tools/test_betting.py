"""Contract tests for the shared telemetry parser and betting lead curve."""

import betting as b
from aibattle_log import extract_telemetry, find_log


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


def test_betting_pairs_the_same_shared_stream():
    telemetry = extract_telemetry(_text(
        ("R", "t=5s hp=90% gold=300 loc=0,0 lh=2 dg=+80"),
        ("D", "t=6s hp=80% gold=400 loc=0,0 lh=1 dg=+40"),
    ))
    pairs = b.pair_streams(telemetry)
    assert len(pairs) == 1
    assert pairs[0]["gold_lead"] == 40
    assert pairs[0]["lh_lead"] == 1


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
