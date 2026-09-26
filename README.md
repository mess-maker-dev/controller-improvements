# Controller Improvements

WoW addon for controller/gamepad tweaks in WoW Forever.

## Status: parked (beta restriction)

The combined bank/vendor panel is implemented and functional in structure, but
**disabled by default**. On the WoW Forever beta (client 1.60.1.70009, interface
16001), any addon modification of the native bank/vendor windows taints the
gamepad interact-update chain; the client then shows the "blocked from an
action only available to the Blizzard UI" popup (whose dismissal also freezes
the client on this beta) for the rest of the session. This persisted across
every input approach tried:

- prompted-binding footer / override binding groups (Blizzard's GamepadSharedUtility)
- plain `SetBindingClick`/`SetBinding`
- direct `C_GamePad.GetDeviceMappedState` polling (current implementation)
- hiding/suppressing/parenting the native windows every which way

The blocked function is always Blizzard's `SetPreferredGamepadInteractTarget`
via the gamepad action bar — chains that contain zero addon code still get
blocked, which points at beta-side restriction/taint interplay rather than
anything in the addon. Known beta context: ABXY bindings are locked in the
beta, and the beta has a SavedVariables-writing bug.

The beta hotfixes nightly — revisit when it stabilizes. Enable with `/ci enable`
(or set `EnableTakeover = true`), disable with `/ci disable`.

## What's built

- `ControllerImprovements.lua` — combined bank/vendor panel: bags left,
  bank/vendor right, D-pad navigation via Blizzard SmartNavigation, A
  pick-up/place, X deposit/withdraw/sell/buy (polled directly from the
  controller state — no binding calls), B close via a Blizzard-scripted close
  button with the native window closing through child-hide propagation.
- `CIItemButton.lua` — item button mixin (bag/bank/merchant/buyback).
- `/ci probe` / `/ci blocktest` — runtime diagnostics (SavedVariables).

## Install

Copy this repo into WoW Forever's `Interface/AddOns/ControllerImprovements`
(folder name must match the `.toc`). Symlinks/junctions do NOT work — the beta
client's addon scanner skips reparse points. Use `sync-to-game.sh` after edits.

Built against the WoW Forever interface (16001) — the retail 12.x addon API, vanilla content.
