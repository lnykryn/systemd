#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Test CatchUp= directive for timers.
#
# When a timer is stopped and restarted, if it would have elapsed while stopped,
# CatchUp=true (default) fires immediately ("catch-up" behavior).
# CatchUp=false skips any elapsed events and schedules the next elapse time in the future instead.
#
set -eux
set -o pipefail

# shellcheck source=test/units/util.sh
. "$(dirname "$0")"/util.sh

UNIT_NAME="timer-catchup-$RANDOM"
TEST_MESSAGE="Hello from timer $RANDOM"
LOG_FILE="/tmp/timer-catchup-test-$RANDOM.log"

# Cleanup function
cleanup() {
    systemctl stop "$UNIT_NAME".{timer,service} || :
    rm -f "/run/systemd/system/$UNIT_NAME".{timer,service}
    rm -rf "/run/systemd/system/$UNIT_NAME.timer.d/"
    rm -f "$LOG_FILE"
    systemctl daemon-reload
    date --set="$(cat /tmp/original-time)" || :
    rm -f /tmp/original-time
}

trap cleanup EXIT

# Save current time for restoration
date "+%Y-%m-%d %H:%M:%S" > /tmp/original-time

#
# Test 1: CatchUp=true (default) - timer fires immediately when restarted after scheduled time
#
echo "Test 1: CatchUp=true (default) - should fire immediately when restarted after scheduled time"

cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=$(date --date="+1 hour" "+%Y-%m-%d %H:%M:%S")
AccuracySec=1s
# CatchUp=true is the default
EOF

cat >"/run/systemd/system/$UNIT_NAME.service" <<EOF
[Service]
Type=oneshot
ExecStart=bash -c 'echo "$(date +%%s)" >> $LOG_FILE'
EOF

systemctl daemon-reload

# Start the timer
systemctl start "$UNIT_NAME.timer"
systemctl status "$UNIT_NAME.timer"

# Verify it's scheduled in the future
NEXT_ELAPSE=$(systemctl show -P NextElapseUSecRealtime "$UNIT_NAME.timer")
CURRENT_TIME_US=$(date +%s)000000
assert_ge "$NEXT_ELAPSE" "$CURRENT_TIME_US"

# Move time forward by 2 hours to pass the scheduled time
date --set='+2 hours'
sleep 1

# Wait for the timer to fire
timeout 10 bash -c "until [[ -e '$LOG_FILE' ]]; do sleep 0.5; done"
assert_eq "$(wc -l < "$LOG_FILE")" "1"

# Stop the timer
systemctl stop "$UNIT_NAME.timer"

# Delete the log file
rm -f "$LOG_FILE"

# Restart the timer - with CatchUp=true (default), it should fire immediately
# because the scheduled time has already passed
systemctl start "$UNIT_NAME.timer"

# The timer should trigger immediately (within 10 seconds)
timeout 10 bash -c "until [[ -e '$LOG_FILE' ]]; do sleep 0.5; done"
assert_eq "$(wc -l < "$LOG_FILE")" "1"

echo "Test 1 PASSED"

# Cleanup for next test
systemctl stop "$UNIT_NAME".{timer,service}
rm -f "$LOG_FILE"
date --set="-2 hours"

#
# Test 2: CatchUp=false - timer does NOT fire immediately when restarted after scheduled time
#
echo "Test 2: CatchUp=false - should NOT fire immediately when restarted after scheduled time"

# Create timer with CatchUp=false
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=$(date --date="+1 hour" "+%Y-%m-%d %H:%M:%S")
AccuracySec=1s
CatchUp=false
EOF

systemctl daemon-reload

# Start the timer
systemctl start "$UNIT_NAME.timer"
systemctl status "$UNIT_NAME.timer"

# Move time forward by 2 hours to pass the scheduled time
date --set='+2 hours'
sleep 1

# Wait for the timer to fire
timeout 10 bash -c "until [[ -e '$LOG_FILE' ]]; do sleep 0.5; done"
assert_eq "$(wc -l < "$LOG_FILE")" "1"

# Record the service invocation ID
SERVICE_INV_ID="$(systemctl show -P InvocationID "$UNIT_NAME.service")"
TIMER_LAST_TRIGGER="$(systemctl show -P LastTriggerUSec "$UNIT_NAME.timer")"

# Stop the timer
systemctl stop "$UNIT_NAME.timer"

# Restart the timer - with CatchUp=false, it should NOT fire immediately
# even though the scheduled time has already passed
systemctl start "$UNIT_NAME.timer"

# Wait a bit and verify the service was NOT triggered again
sleep 5
assert_eq "$(wc -l < "$LOG_FILE")" "1"
assert_eq "$SERVICE_INV_ID" "$(systemctl show -P InvocationID "$UNIT_NAME.service")"
assert_eq "$TIMER_LAST_TRIGGER" "$(systemctl show -P LastTriggerUSec "$UNIT_NAME.timer")"

# The next elapse should be scheduled in the future
NEXT_ELAPSE=$(systemctl show -P NextElapseUSecRealtime "$UNIT_NAME.timer")
CURRENT_TIME_US=$(date +%s)000000
assert_ge "$NEXT_ELAPSE" "$CURRENT_TIME_US"

echo "Test 2 PASSED"

# Cleanup for next test
systemctl stop "$UNIT_NAME".{timer,service}
rm -f "$LOG_FILE"
date --set="-2 hours"

#
# Test 3: CatchUp=false with recurring calendar timer
#
echo "Test 3: CatchUp=false with recurring calendar timer (every 5 minutes)"

# Create timer that fires every 5 minutes with CatchUp=false
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=*:0/5:0
AccuracySec=1s
CatchUp=false
EOF

systemctl daemon-reload

# Start the timer
systemctl start "$UNIT_NAME.timer"
systemctl status "$UNIT_NAME.timer"

# Wait for it to fire at least once
timeout 360 bash -c "until [[ -e '$LOG_FILE' ]]; do sleep 1; done"
assert_eq "$(wc -l < "$LOG_FILE")" "1"

# Stop the timer and move time forward by 20 minutes (would skip 4 events)
systemctl stop "$UNIT_NAME.timer"
date --set='+20 minutes'
sleep 1

# Restart the timer - with CatchUp=false, it should skip the 4 elapsed events
# and wait for the next 5-minute boundary
SERVICE_INV_ID="$(systemctl show -P InvocationID "$UNIT_NAME.service")"
systemctl start "$UNIT_NAME.timer"

# Wait a bit and verify it didn't fire immediately for any of the 4 missed events
sleep 5
assert_eq "$(wc -l < "$LOG_FILE")" "1"
assert_eq "$SERVICE_INV_ID" "$(systemctl show -P InvocationID "$UNIT_NAME.service")"

echo "Test 3 PASSED"

# Cleanup for next test
systemctl stop "$UNIT_NAME".{timer,service}
rm -f "$LOG_FILE"
date --set="-20 minutes"

#
# Test 4: CatchUp=false with monotonic timer (OnActiveSec)
#
echo "Test 4: CatchUp=false with monotonic timer (OnActiveSec)"

# Create a timer with OnActiveSec and CatchUp=false
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnActiveSec=10s
AccuracySec=1s
CatchUp=false
EOF

systemctl daemon-reload

# Start the timer
systemctl start "$UNIT_NAME.timer"
systemctl status "$UNIT_NAME.timer"

# Move time forward by 20 seconds (past the OnActiveSec=10s)
date --set='+20 seconds'
sleep 1

# The timer should have fired (because time has passed)
timeout 10 bash -c "until [[ -e '$LOG_FILE' ]]; do sleep 0.5; done"
assert_eq "$(wc -l < "$LOG_FILE")" "1"

SERVICE_INV_ID="$(systemctl show -P InvocationID "$UNIT_NAME.service")"

# Stop and restart the timer - with CatchUp=false, the elapsed monotonic timer
# should not fire again since it already elapsed while we were in the future
systemctl stop "$UNIT_NAME.timer"
systemctl start "$UNIT_NAME.timer"

# Wait and verify the timer doesn't fire (the monotonic timer already elapsed)
sleep 5
assert_eq "$(wc -l < "$LOG_FILE")" "1"
assert_eq "$SERVICE_INV_ID" "$(systemctl show -P InvocationID "$UNIT_NAME.service")"

echo "Test 4 PASSED"

# Cleanup for next test
systemctl stop "$UNIT_NAME".{timer,service}
rm -f "$LOG_FILE"
date --set="-20 seconds"

#
# Test 5: Verify CatchUp property is exposed via D-Bus
#
echo "Test 5: Verify CatchUp property is exposed via D-Bus"

# Test with CatchUp=true
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=daily
CatchUp=true
EOF

systemctl daemon-reload
systemctl start "$UNIT_NAME.timer"
CATCHUP_VALUE=$(systemctl show -P CatchUp "$UNIT_NAME.timer")
assert_eq "$CATCHUP_VALUE" "yes"
systemctl stop "$UNIT_NAME.timer"

# Test with CatchUp=false
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=daily
CatchUp=false
EOF

systemctl daemon-reload
systemctl start "$UNIT_NAME.timer"
CATCHUP_VALUE=$(systemctl show -P CatchUp "$UNIT_NAME.timer")
assert_eq "$CATCHUP_VALUE" "no"
systemctl stop "$UNIT_NAME.timer"

# Test default value (should be true)
cat >"/run/systemd/system/$UNIT_NAME.timer" <<EOF
[Timer]
OnCalendar=daily
EOF

systemctl daemon-reload
systemctl start "$UNIT_NAME.timer"
CATCHUP_VALUE=$(systemctl show -P CatchUp "$UNIT_NAME.timer")
assert_eq "$CATCHUP_VALUE" "yes"

echo "Test 5 PASSED"

echo "All CatchUp tests PASSED"
