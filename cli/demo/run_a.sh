#!/usr/bin/env bash
# 终端 1：以设备 A（你）身份启动 TUI（方案 A 分栏界面 + WS 实时）。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec dart run bin/einz_tui.dart --store demo/store-a.json --server http://127.0.0.1:3901
