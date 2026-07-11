from app.identity import player_key


def test_steam_id_takes_precedence():
    assert player_key(steam_id=76561198000000000, name="Whatever") == "steam:76561198000000000"


def test_falls_back_to_name_when_no_steam_id():
    assert player_key(steam_id=None, name="Bot_A") == "name:Bot_A"


def test_zero_steam_id_is_treated_as_absent():
    assert player_key(steam_id=0, name="Bot_A") == "name:Bot_A"


def test_missing_both_raises():
    import pytest
    with pytest.raises(ValueError):
        player_key(steam_id=None, name="")
