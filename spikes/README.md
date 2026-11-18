# Spikes

Throwaway measurements for the owner's devices, kept so they can be run again. **Not part of the app**: the app's project ignores this
folder (`.gdignore`), and nothing here is loaded by `scenes/main.tscn`.

| Spike | Where | Plan, steps and pass / fail |
|---|---|---|
| P0 voice (TwoVoip Opus over a WebSocket, Quest 3 and phone) | `spikes/voice/`: its own small Godot project, `echo_relay.py`, an export preset example. TwoVoip comes from `tools/install_voip_plugin.sh` (pinned, checked, never committed) | `docs/live-sessions-spikes.md`, "Spike V" |
| P0 Cardboard (phone camera rig and render budget) | In the app's project, because it tests the app's phone export: `scenes/spikes/cardboard_spike.tscn`, `scripts/spikes/`, the `.phone` overrides in `project.godot`, `tools/android/phone_export_preset.cfg.example`, `tools/save_assembly_glb.gd` | `docs/live-sessions-spikes.md`, "Spike C" |
