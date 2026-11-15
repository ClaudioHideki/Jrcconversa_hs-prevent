#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
image="$1"
out="$GITHUB_WORKSPACE/tmp/ci-evidence"
mkdir -p "$out"
suffix="smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${RANDOM}"
network="jrc-$suffix"
pg="jrc-pg-$suffix"
redis="jrc-redis-$suffix"
cleanup() {
  docker rm -f -v "$pg" "$redis" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create --internal "$network" >/dev/null
docker run -d --name "$pg" --network "$network" --network-alias postgres -e POSTGRES_PASSWORD=ci-local-only -e POSTGRES_DB=jrc_release_test pgvector/pgvector:pg16 >/dev/null
docker run -d --name "$redis" --network "$network" --network-alias redis redis:7-alpine >/dev/null
for attempt in {1..40}; do
  if docker exec "$pg" pg_isready -U postgres -d jrc_release_test >/dev/null; then break; fi
  sleep 0.5
done
args=(--rm --network "$network" --mount "type=bind,source=$GITHUB_WORKSPACE/.github/scripts,target=/support,readonly"
  -e POSTGRES_HOST=postgres -e POSTGRES_DATABASE=jrc_release_test -e POSTGRES_USERNAME=postgres
  -e POSTGRES_PASSWORD=ci-local-only -e REDIS_URL=redis://redis:6379/0
  -e SECRET_KEY_BASE=ci-isolated-no-send-secret -e FRONTEND_URL=http://localhost
  -e RAILS_LOG_TO_STDOUT=true -e SENTRY_DSN= -e NEW_RELIC_LICENSE_KEY=)
docker run "${args[@]}" -e RAILS_ENV=test "$image" bundle exec rails db:schema:load > "$out/smoke-schema.log" 2>&1
docker run "${args[@]}" -e RAILS_ENV=production -e RACK_ENV=production "$image" bundle exec rails runner /support/smoke.rb > "$out/smoke.log" 2>&1
docker run --rm --read-only --network none --entrypoint sh "$image" -c 'ruby --version; node --version; bundle --version' > "$out/runtime-versions.log"
tail -n 8 "$out/smoke.log"
