#!/bin/sh
# 构建 Gloam.app（只需要 Xcode 命令行工具）。
set -e
cd "$(dirname "$0")"
APP=Gloam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -wmo main.swift Settings.swift -o "$APP/Contents/MacOS/Gloam"
strip -x "$APP/Contents/MacOS/Gloam"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "已生成 $PWD/$APP"
