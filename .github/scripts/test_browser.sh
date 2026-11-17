#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
out="$GITHUB_WORKSPACE/tmp/ci-evidence"
suffix="browser-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
network="jrc-$suffix"
pg="jrc-pg-$suffix"
redis="jrc-redis-$suffix"
web="jrc-web-$suffix"
relay="jrc-relay-$suffix"
cleanup() {
  docker logs "$web" > "$out/browser-server.log" 2>&1 || true
  docker logs "$relay" > "$out/browser-relay.log" 2>&1 || true
  docker rm -f -v "$relay" "$web" "$pg" "$redis" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create --internal "$network" >/dev/null
docker run -d --name "$pg" --network "$network" --network-alias postgres -e POSTGRES_PASSWORD=browser-local-only -e POSTGRES_DB=jrc_browser_test pgvector/pgvector:pg16 >/dev/null
docker run -d --name "$redis" --network "$network" --network-alias redis redis:7-alpine >/dev/null
for attempt in {1..40}; do
  if docker exec "$pg" pg_isready -U postgres -d jrc_browser_test >/dev/null; then break; fi
  sleep 0.5
done
args=(--network "$network" --mount "type=bind,source=$GITHUB_WORKSPACE,target=/app"
  --mount "type=bind,source=$GITHUB_WORKSPACE/.github/scripts/browser_guard.rb,target=/app/config/initializers/zz_flux_browser_guard.rb,readonly"
  -e GITHUB_ACTIONS=true -e RAILS_ENV=production -e RACK_ENV=production
  -e POSTGRES_HOST=postgres -e POSTGRES_DATABASE=jrc_browser_test
  -e POSTGRES_USERNAME=postgres -e POSTGRES_PASSWORD=browser-local-only
  -e REDIS_URL=redis://redis:6379/0 -e SECRET_KEY_BASE=isolated-browser-no-send-secret
  -e FRONTEND_URL=http://127.0.0.1:18417 -e FORCE_SSL=false -e RAILS_SERVE_STATIC_FILES=true
  -e RAILS_LOG_TO_STDOUT=true -e LOG_LEVEL=warn)
docker run --rm "${args[@]}" jrc-validation-runtime bundle exec rails db:schema:load > "$out/browser-schema.log" 2>&1
docker run --rm "${args[@]}" jrc-validation-runtime bundle exec rails runner .github/scripts/seed_browser.rb > "$out/browser-seed.log" 2>&1
docker run -d --name "$web" "${args[@]}" --network-alias web jrc-validation-runtime bundle exec rails s -b 0.0.0.0 -p 3000 >/dev/null
docker run -d --name "$relay" --network "$network" --publish 127.0.0.1:18417:18417 \
  --mount "type=bind,source=$GITHUB_WORKSPACE,target=/app,readonly" -e GITHUB_ACTIONS=true \
  jrc-validation-runtime ruby .github/scripts/browser_relay.rb >/dev/null
docker network connect bridge "$relay"
docker inspect "$web" --format '{{json .NetworkSettings.Networks}}' > "$out/browser-web-network.json"
ready=false
for attempt in {1..90}; do
  if curl --fail --silent http://127.0.0.1:18417/app/login >/dev/null; then ready=true; break; fi
  sleep 1
done
test "$ready" = true
npm install --prefix "$RUNNER_TEMP/jrc-browser-tools" --no-save --package-lock=false playwright@1.65.1 > "$out/browser-install.log" 2>&1
export JRC_PLAYWRIGHT_MODULE="$RUNNER_TEMP/jrc-browser-tools/node_modules/playwright"
export JRC_CHROME_PATH
JRC_CHROME_PATH="$(command -v google-chrome)"
node .github/scripts/browser_continuation.cjs
