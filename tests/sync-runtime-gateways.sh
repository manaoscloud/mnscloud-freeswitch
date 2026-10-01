#!/usr/bin/env bash
# Validates that managed_gateway_names correctly extracts all trunk gateway names
# whether they appear on separate lines, multiple per line, or with varying whitespace.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

source_managed_gateway_names() {
  sed -n '/managed_gateway_names() {/,/^}/p' "${REPO}/scripts/sync-freeswitch-runtime.sh"
}

eval "$(source_managed_gateway_names)"

cat > "${WORK}/multiline.xml" <<'EOF'
<configuration name="sofia.conf">
  <profiles>
    <profile name="external">
      <gateways>
        <gateway name="trunk-bd8a8d32bdb411f191e7bc2411db6508">
          <param name="username" value="user1"/>
        </gateway>
        <gateway name="trunk-4f9b3933bcdc11f191e7bc2411db6508">
          <param name="proxy" value="proxy1"/>
        </gateway>
      </gateways>
    </profile>
  </profiles>
</configuration>
EOF

cat > "${WORK}/singleline.xml" <<'EOF'
<gateways><gateway name="trunk-bd8a8d32bdb411f191e7bc2411db6508"><param/></gateway><gateway name="trunk-4f9b3933bcdc11f191e7bc2411db6508"><param/></gateway></gateways>
EOF

cat > "${WORK}/empty.xml" <<'EOF'
<gateways>
  <!-- No gateways -->
</gateways>
EOF

expected=$'trunk-4f9b3933bcdc11f191e7bc2411db6508\ntrunk-bd8a8d32bdb411f191e7bc2411db6508'

res_multiline="$(managed_gateway_names "${WORK}/multiline.xml")"
if [[ "${res_multiline}" != "${expected}" ]]; then
  echo "FAIL: multiline extraction failed. Got:"
  echo "${res_multiline}"
  exit 1
fi

res_singleline="$(managed_gateway_names "${WORK}/singleline.xml")"
if [[ "${res_singleline}" != "${expected}" ]]; then
  echo "FAIL: singleline extraction failed. Got:"
  echo "${res_singleline}"
  exit 1
fi

res_empty="$(managed_gateway_names "${WORK}/empty.xml")"
if [[ -n "${res_empty}" ]]; then
  echo "FAIL: empty extraction should be empty. Got: ${res_empty}"
  exit 1
fi

echo "PASS: sync-runtime-gateways tests passed."
