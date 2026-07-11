def player_key(steam_id: int | None, name: str | None) -> str:
    """Stable identity key. SteamID when present (non-zero), else name-based
    fallback for bots/LAN players that have no SteamID yet."""
    if steam_id:
        return f"steam:{steam_id}"
    if name:
        return f"name:{name}"
    raise ValueError("player must have a steam_id or a name")
