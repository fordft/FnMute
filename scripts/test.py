#!/usr/bin/env python3
"""Run the Fn-state regression tests without touching keyboard or audio devices."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / ".build"
build.mkdir(exist_ok=True)
binary = build / "PhysicalFnStateTests"
subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O",
    str(root / "Sources/FnMute/PhysicalFnState.swift"), str(root / "Tests/main.swift"),
    "-o", str(binary)], check=True)
subprocess.run([str(binary)], check=True)
