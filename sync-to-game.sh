#!/bin/bash
# Copies the addon into the WoW Forever beta AddOns folder.
# A junction/symlink does NOT work: the beta client's addon scanner skips
# reparse points (that's why the addon didn't load until we copied).
set -e
DEST="/mnt/c/Program Files (x86)/World of Warcraft/_classic_beta_/Interface/AddOns/ControllerImprovements"
mkdir -p "$DEST"
cp ControllerImprovements.lua ControllerImprovements.toc "$DEST/"
echo "synced to $DEST"
