extends RefCounted
## Table-driven registry of the client's `--*-test` visual/audio QA flags (deep-review §D3).
## ONE row per flag replaces the old ~6 copy-paste touch points (configure parse line, renderer
## forward, per-frame `_ensure_*` call). Referenced via preload (no class_name — avoids --import).
##
## Row shape:
##   "flag":     CLI arg name without the leading `--` (bootstrap parses `--x` into args["x"])
##   "member":   client_main.gd bool member set true when the flag is present
##   "renderer": (optional) WorldRenderer property mirrored from the member at scene build
##   "demo":     (optional) WorldRenderer `_ensure_*_demo` method driven each frame by
##               WorldRenderer._run_demos(now); every demo self-gates on its own flag
##
## Method/property names are strings (a const table can't hold instance-bound Callables);
## tests/qa_flag_registry_test.gd asserts every name resolves on the owning script.
## Flags with client_main-local behavior (e.g. --flash-test, --capture-test, --build-test) have
## no "renderer"/"demo" — their demo logic stays inline where it reads HUD/audio/net context.

const FLAGS: Array = [
	{"flag": "flash-test", "member": "_flash_test"},                # force the flashbang white-out
	{"flag": "suppress-test", "member": "_suppress_test"},          # force the suppression screen FX
	{"flag": "armor-demo", "member": "_armor_demo",                 # pin LIGHT/MEDIUM/HEAVY dummies in view
		"renderer": "armor_demo", "demo": "_ensure_armor_demo"},
	{"flag": "boom-test", "member": "_boom_test",                   # pump frag explosions in front of camera
		"renderer": "boom_demo", "demo": "_ensure_boom_demo"},
	{"flag": "vehicle-test", "member": "_vehicle_test",             # blow up a transport in front of camera
		"renderer": "wreck_demo", "demo": "_ensure_wreck_demo"},
	{"flag": "turret-test", "member": "_turret_test",               # turret traversed off the hull axis
		"renderer": "turret_demo", "demo": "_ensure_turret_demo"},
	{"flag": "held-weapon-test", "member": "_heldweapon_test",      # per-weapon held-gun silhouettes
		"renderer": "heldweapon_demo", "demo": "_ensure_heldweapon_demo"},
	{"flag": "seat-pose-test", "member": "_seat_pose_test",         # standing-vs-seated occupant pose
		"renderer": "seat_pose_demo", "demo": "_ensure_seat_pose_demo"},
	{"flag": "impact-test", "member": "_impact_test",               # pump bullet impacts in front of camera
		"renderer": "impact_demo", "demo": "_ensure_impact_demo"},
	{"flag": "corpse-test", "member": "_corpse_test",               # lay corpses in front of camera
		"renderer": "corpse_demo", "demo": "_ensure_corpse_demo"},
	{"flag": "footstep-test", "member": "_footstep_test",           # pump footstep dust in front of camera
		"renderer": "footstep_demo", "demo": "_ensure_footstep_demo"},
	{"flag": "swing-test", "member": "_swing_test",                 # hold the viewmodel mid-swing
		"renderer": "vm_swing_test"},
	{"flag": "recoil-test", "member": "_recoil_test",               # hold the viewmodel mid-recoil-kick
		"renderer": "vm_recoil_test"},
	{"flag": "crosshair-test", "member": "_crosshair_test"},        # force a bloomed crosshair
	{"flag": "ads-test", "member": "_ads_test"},                    # force aim-down-sights on
	{"flag": "scope-test", "member": "_scope_test"},                # force ADS + the sniper scope overlay
	{"flag": "casing-test", "member": "_casing_test",               # pump ejected shell casings
		"renderer": "casing_demo", "demo": "_ensure_casing_demo"},
	{"flag": "climb-test", "member": "_climb_test",                 # climbing pose vs upright dummy
		"renderer": "climb_demo", "demo": "_ensure_climb_demo"},
	{"flag": "jump-test", "member": "_jump_test",                   # airborne pose vs upright dummy
		"renderer": "jump_demo", "demo": "_ensure_jump_demo"},
	{"flag": "land-test", "member": "_land_test",                   # landing dust + viewmodel dip
		"renderer": "land_demo", "demo": "_ensure_land_demo"},
	{"flag": "downed-test", "member": "_downed_test"},              # force the DBNO bandage overlay
	{"flag": "firepose-test", "member": "_firepose_test",           # fire-recoil pose vs upright dummy
		"renderer": "firepose_demo", "demo": "_ensure_firepose_demo"},
	{"flag": "flinch-test", "member": "_flinch_test",               # hit-flinch pose vs upright dummy
		"renderer": "flinch_demo", "demo": "_ensure_flinch_demo"},
	{"flag": "remote-reload-test", "member": "_reloadpose_test",    # reload pose vs upright dummy
		"renderer": "reloadpose_demo", "demo": "_ensure_reloadpose_demo"},
	{"flag": "remote-melee-test", "member": "_meleepose_test",      # melee lunge pose vs upright dummy
		"renderer": "meleepose_demo", "demo": "_ensure_meleepose_demo"},
	{"flag": "remote-vault-test", "member": "_vaultpose_test",      # mantle pose vs upright dummy
		"renderer": "vaultpose_demo", "demo": "_ensure_vaultpose_demo"},
	{"flag": "glbshoot-test", "member": "_glbshoot_test",           # GLB hold vs holding-both-shoot clip
		"renderer": "glbshoot_demo", "demo": "_ensure_glbshoot_demo"},
	{"flag": "engine-test", "member": "_engine_test"},              # force the vehicle engine loop on (audio)
	{"flag": "sprint-test", "member": "_sprint_test",               # freeze the viewmodel sprint-lowered
		"renderer": "vm_sprint_test"},
	{"flag": "vm-climb-test", "member": "_vm_climb_test",           # freeze the viewmodel climb/vault-lowered
		"renderer": "vm_climb_test"},
	{"flag": "repair-heat-test", "member": "_repair_heat_test"},    # cycle the repair-tool heat gauge
	{"flag": "reload-test", "member": "_reload_test",               # freeze the viewmodel mid-reload
		"renderer": "vm_reload_test"},
	{"flag": "whiz-test", "member": "_whiz_test"},                  # synthetic near-miss crack/whiz rounds
	{"flag": "smoke-test", "member": "_smoke_test",                 # pop a smoke cloud in front of the camera
		"renderer": "smoke_demo", "demo": "_ensure_smoke_demo"},
	{"flag": "grenade-test", "member": "_grenade_test",             # lob cosmetic grenades across the view
		"renderer": "grenade_demo", "demo": "_ensure_grenade_demo"},
	{"flag": "gadget-test", "member": "_gadget_test",               # place sample deployed gadgets in view
		"renderer": "gadget_demo", "demo": "_ensure_gadget_demo"},
	{"flag": "revive-marker-test", "member": "_revive_marker_test", # downed friendly + revive marker
		"renderer": "revive_demo", "demo": "_ensure_revive_demo"},
	{"flag": "downed-urgency-test", "member": "_downed_urgency_test",  # downed dummies at varying bleed urgency
		"renderer": "downed_urgency_demo", "demo": "_ensure_downed_urgency_demo"},
	{"flag": "support-test", "member": "_support_test",             # support beam + aura between two soldiers
		"renderer": "support_demo", "demo": "_ensure_support_demo"},
	{"flag": "buildsite-test", "member": "_buildsite_test",         # ghost build site (shovel construction)
		"renderer": "buildsite_demo", "demo": "_ensure_buildsite_demo"},
	{"flag": "fob-menu-test", "member": "_fob_menu_test"},          # deploy screen with a Squad FOB option
	{"flag": "build-test", "member": "_build_test"},                # auto-enter build mode (placement ghost)
	{"flag": "grenade-danger-test", "member": "_grenade_danger_test"},  # pin a live grenade near the player
	{"flag": "capture-test", "member": "_capture_test"},            # pump capture-announcement banners
	{"flag": "killfeed-test", "member": "_killfeed_test"},          # pump named killfeed entries
	{"flag": "destroy-test", "member": "_destroy_test",             # pump piece destruction debris/dust
		"renderer": "destroy_demo", "demo": "_ensure_destroy_demo"},
	{"flag": "collapse-test", "member": "_collapse_test",           # play a building collapse cinematic
		"renderer": "collapse_demo", "demo": "_ensure_collapse_demo"},
]
