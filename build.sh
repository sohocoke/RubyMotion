#!/bin/sh

# EX)
#   ./build.sh clean:vm
#   ./build.sh
rake $*
SDK_BETA=1 PLATFORMS_DIR=/Applications/Xcode5-DP6.app/Contents/Developer/Platforms rake $*