# Controller Improvements

WoW addon for controller/gamepad tweaks in WoW Forever (interface 16001).

## What it does (overlay mode)

While a bank or vendor window is open with a gamepad, pressing **X** performs
a one-press move on the focused slot:

- bag item + bank open → **Deposit**
- bank slot → **Withdraw**
- bag item + vendor open → **Sell**
- merchant item → **Buy** (buyback tab → **Buy Back**)

A prompt line under the windows shows what X will do. Navigation (D-pad/A/B)
is the client's native gamepad UI, untouched.

## Why overlay mode

The original design replaced the native windows with a combined panel. On the
Forever beta, any addon modification of the native bank/vendor windows taints
the gamepad interact-update chain, and the client then shows the "blocked from
an action only available to the Blizzard UI" popup (dismissing it freezes the
client) for the rest of the session. This persisted across every input approach
(footer bindings, override bindings, plain bindings, direct controller polling)
and with zero addon code in the triggering chain.

The working pattern was found in the [Inked](https://www.curseforge.com/wow/addons/inked)
addon: enhance the native windows from the outside — display-only overlay,
read-only SmartNavigation access, engine item-move calls, no window management.
This build follows that architecture exactly.

Next step (from Inked's playbook): D-pad bridges across the bag/bank gap so
navigation moves side-to-side without LT/RT window cycling.

## Install

Copy this repo into WoW Forever's `Interface/AddOns/ControllerImprovements`
(folder name must match the `.toc`). Symlinks/junctions do NOT work — the beta
client's addon scanner skips reparse points. Use `sync-to-game.sh` after edits.

## Debug

- `/ci probe` — runtime API dump (SavedVariables; `/reload` to flush)
- `/ci blocktest` — fire binding calls one at a time to see which get blocked
