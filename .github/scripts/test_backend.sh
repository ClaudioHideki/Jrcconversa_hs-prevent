#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
out="$GITHUB_WORKSPACE/tmp/ci-evidence"
mkdir -p "$out"
suffix="validation-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
network="jrc-$suffix"
pg="jrc-pg-$suffix"
redis="jrc-redis-$suffix"
cleanup() {
  docker rm -f -v "$pg" "$redis" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker build -f .github/docker/validation.Dockerfile -t jrc-validation-runtime . > "$out/test-runtime-build.log" 2>&1
docker network create --internal "$network" >/dev/null
docker run -d --name "$pg" --network "$network" --network-alias postgres -e POSTGRES_PASSWORD=ci-local-only -e POSTGRES_DB=jrc_release_test pgvector/pgvector:pg16 >/dev/null
docker run -d --name "$redis" --network "$network" --network-alias redis redis:7-alpine >/dev/null
for attempt in {1..40}; do
  if docker exec "$pg" pg_isready -U postgres -d jrc_release_test >/dev/null; then break; fi
  sleep 0.5
done
args=(--rm --network "$network" --mount "type=bind,source=$GITHUB_WORKSPACE,target=/app"
  -e RAILS_ENV=test -e POSTGRES_HOST=postgres -e POSTGRES_DATABASE=jrc_release_test
  -e POSTGRES_USERNAME=postgres -e POSTGRES_PASSWORD=ci-local-only
  -e REDIS_URL=redis://redis:6379/0 -e SECRET_KEY_BASE=ci-isolated-no-send-secret
  -e FRONTEND_URL=http://localhost)
docker run "${args[@]}" jrc-validation-runtime bundle exec rails db:schema:load > "$out/schema.log" 2>&1
mapfile -t specs < .github/scripts/backend-specs.txt
docker run "${args[@]}" jrc-validation-runtime bundle exec rspec "${specs[@]}" --format progress > "$out/rspec.log" 2>&1
python3 .github/scripts/test_ruby_lint_regressions.py
python3 .github/scripts/ruby_lint_regressions.py "$out" "${args[@]}"

tail -n 6 "$out/rspec.log"
