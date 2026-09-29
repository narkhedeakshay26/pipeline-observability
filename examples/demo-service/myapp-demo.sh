#!/usr/bin/env bash
# A fake pipeline worker that logs like a real one, so the dashboard has data.
# "<N>" at the start of a line sets the journald priority (7=debug, 6=info, 3=err).
worker="${1:-demo}"
i=0
while true; do
  i=$((i + 1))
  echo "<7>DEBUG message received id=$i worker=$worker"        # noisy: dropped by the agent
  if (( i % 10 == 0 )); then
    echo "<6>Progress report | worker=$worker records=$(( RANDOM % 400 + 100 ))"
  fi
  if (( RANDOM % 60 == 0 )); then
    echo "<3>ERROR upstream timeout, retrying | worker=$worker"
  fi
  sleep 1
done
