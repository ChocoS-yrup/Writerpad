#!/bin/sh
set -eu

# 단위 테스트를 안전한 조건에서 실행한다.
#
# 왜 스크립트인가: 아래 세 가지를 빠뜨리면 실행이 조용히 망가진다.
#   - 시뮬레이터가 죽어 있으면 xcodebuild가 실패하지 않고 무한히 기다린다.
#   - 테스트 타임아웃이 꺼져 있으면 매달린 테스트 하나가 전체를 세운다.
#   - 측정 harness는 fixture 생성만으로도 오래 걸려 평소 실행에 넣으면 안 된다.
#
# 사용법:
#   Scripts/run_tests.sh                        전체 단위 테스트
#   Scripts/run_tests.sh SyncV2StoreTests       한 클래스만
#   Scripts/run_tests.sh SyncV2StoreTests/testX 한 시험만

# set -- 로 xcodebuild 인자를 조립하기 전에 먼저 붙잡아 둔다.
selected=${1:-}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project="$root/WriterPad.xcodeproj"
scheme=WriterPad
# 측정 harness는 실기기에서도 측정 구간만 52초가 걸린다. 평소에는 건너뛴다.
measurement_target=WriterPadTests/SyncV2PullLoopScalingMeasurementTests
# 시험 하나가 이 시간을 넘으면 매달린 것으로 보고 실패시킨다. 실제 sleep에
# 기대는 시험이 몇 개 있어 넉넉하게 잡는다.
allowance=${WRITERPAD_TEST_ALLOWANCE:-120}

fail() {
    echo "run_tests: $1" >&2
    exit 1
}

[ -d "$project" ] || fail "$project 를 찾을 수 없습니다."

# 어떤 시뮬레이터에서 돌릴지 정한다. 환경 변수로 고정할 수 있다.
device_id=${WRITERPAD_SIMULATOR_ID:-}
if [ -z "$device_id" ]; then
    device_id=$(
        xcrun simctl list devices available |
            grep -E '\(([0-9A-F-]{36})\) \(Booted\)' |
            head -1 |
            sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
    )
fi
if [ -z "$device_id" ]; then
    device_id=$(
        xcrun simctl list devices available |
            grep -i ipad |
            head -1 |
            sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
    )
fi
[ -n "$device_id" ] || fail "쓸 수 있는 iPad 시뮬레이터가 없습니다."

# 부팅돼 있지 않으면 올린다. 죽은 기기를 향해 쏘면 실패가 아니라 무한 대기다.
if ! xcrun simctl list devices booted | grep -q "$device_id"; then
    echo "run_tests: 시뮬레이터를 부팅합니다 ($device_id)"
    xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$device_id" -b >/dev/null 2>&1 || true
fi
xcrun simctl list devices booted | grep -q "$device_id" ||
    fail "시뮬레이터를 부팅하지 못했습니다 ($device_id)."

derived=${WRITERPAD_DERIVED_DATA:-$root/build/TestDerivedData}
log_dir="$root/build"
mkdir -p "$log_dir"
log="$log_dir/run_tests.log"

set -- \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$device_id" \
    -derivedDataPath "$derived" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$allowance"

if [ -n "$selected" ]; then
    set -- "$@" -only-testing:"WriterPadTests/$selected"
else
    set -- "$@" -only-testing:WriterPadTests -skip-testing:"$measurement_target"
fi

echo "run_tests: 기기 $device_id"
echo "run_tests: 로그 $log"
status=0
xcodebuild test "$@" >"$log" 2>&1 || status=$?

passed=$(grep -c "Test case .* passed" "$log" || true)
failed=$(grep -c "Test case .* failed" "$log" || true)
echo "run_tests: 통과 $passed  실패 $failed"
if [ "$failed" -gt 0 ]; then
    grep -E "Test case .* failed" "$log" |
        sed -E "s/.*Test case '([^']+)'.*/  실패: \1/" |
        sort -u
fi
exit "$status"
