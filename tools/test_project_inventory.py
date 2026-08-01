from project_inventory import STATE_WRITE_RE


def test_state_write_regex_ignores_comparisons():
    assert STATE_WRITE_RE.findall("if bot.aib_owner == nil then") == []
    assert STATE_WRITE_RE.findall("if bot.aib_owner ~= nil then") == []


def test_state_write_regex_finds_assignments():
    assert STATE_WRITE_RE.findall("bot.aib_owner = now") == ["aib_owner"]

