#!/bin/sh
# Builds VOProbe.app for the simulator and installs it on $1 (a simulator UDID).
# Launch with: xcrun simctl launch --console-pty <udid> local.example.voprobe -mode <plain|container|leaf|both|mixed|named-container|vc|textview|scan>
set -eu
cd "$(dirname "$0")"
mkdir -p build/VOProbe.app
cp Info.plist build/VOProbe.app/Info.plist
xcrun --sdk iphonesimulator clang -fobjc-arc -arch arm64 -mios-simulator-version-min=17.0 \
    -framework UIKit -framework CoreGraphics main.m -o build/VOProbe.app/VOProbe
codesign -s - --force build/VOProbe.app
xcrun simctl install "$1" build/VOProbe.app
