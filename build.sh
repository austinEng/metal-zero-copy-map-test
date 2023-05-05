#!/bin/bash
set -x # echo on
mkdir -p bin
clang++ main.mm -mmacosx-version-min=10.15 -std=c++17 -framework Metal -fobjc-arc -framework Metal -framework MetalKit -framework Cocoa  -framework QuartzCore -framework IOSurface -o bin/app
