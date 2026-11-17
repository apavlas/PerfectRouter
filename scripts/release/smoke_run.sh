#!/bin/bash
# Release preflight: archive, then the long-route + Highlights smokes on iPad then iPhone
# (one at a time; live smokes share test port 17321), then OKC->Amarillo x5 on iPhone.
# Usage: scripts/release/smoke_run.sh <build_number> [out_dir]   Results: <out>/b<N>-status.txt
N=${1:?build number}; B=${2:-$HOME/Desktop/PerfectRouter-Builds}; T=b$N
IPAD_ID=${IPAD_SIM_ID:-E7CABC96-FFF1-42E4-97A8-DFD11391BBC7}
IPHONE="platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0"
while pgrep -f "xcodebuild test" >/dev/null; do sleep 30; done
cd "$(dirname "$0")/../.."; P=$(ls -d *.xcodeproj | head -1)
xcodebuild -project "$P" -scheme PerfectRouter -configuration Release -destination generic/platform=iOS -archivePath $B/PerfectRouter-$T.xcarchive archive > $B/$T-archive.log 2>&1; echo "archive=$?" > $B/$T-status.txt
for D in "iPad|platform=iOS Simulator,id=$IPAD_ID" "iPhone|$IPHONE"; do
  NAME=${D%%|*}; DEST=${D#*|}; rm -rf $B/$T-$NAME.xcresult
  xcodebuild test -project "$P" -scheme PerfectRouter -destination "$DEST" -derivedDataPath /tmp/dd-$T-$NAME -resultBundlePath $B/$T-$NAME.xcresult \
    -only-testing:PerfectRouterUITests/B11LongRouteSmokeUITests/testAtlantaToDenverLongRouteSmoke \
    -only-testing:PerfectRouterUITests/HighlightsLiveSmokeUITests/testOklahomaCityToAmarilloHighlights > $B/$T-$NAME.log 2>&1
  echo "$NAME=$?" >> $B/$T-status.txt
done
rm -rf $B/$T-okc5.xcresult
xcodebuild test -project "$P" -scheme PerfectRouter -destination "$IPHONE" -derivedDataPath /tmp/dd-$T-iPhone -resultBundlePath $B/$T-okc5.xcresult -test-iterations 5 \
  -only-testing:PerfectRouterUITests/HighlightsLiveSmokeUITests/testOklahomaCityToAmarilloHighlights > $B/$T-okc5.log 2>&1
echo "okc5=$?" >> $B/$T-status.txt; echo done >> $B/$T-status.txt
