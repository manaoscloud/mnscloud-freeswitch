#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: mnscloud-cdr-diagnostic-capture.sh --enabled yes --module sbc --engine opensips --resource-type sbc_cdr --resource-uuid <id> --call-id <call-id> [--interface any] [--duration 60] [--filter "port 5060"]

Captures a temporary PCAPNG diagnostic artifact, uploads it through a short-lived MNSCloud API
storage URL and registers only metadata in the CDR diagnostic attachment table. Default is
fail-closed: nothing is captured unless --enabled yes is provided.
USAGE
}

enabled="no"
module="pabx"
engine="freeswitch"
resource_type="pabx_cdr"
resource_uuid=""
call_id=""
iface="any"
duration="60"
filter_expr="port 5060"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enabled) enabled="${2:-}"; shift 2 ;;
    --module) module="${2:-}"; shift 2 ;;
    --engine) engine="${2:-}"; shift 2 ;;
    --resource-type) resource_type="${2:-}"; shift 2 ;;
    --resource-uuid) resource_uuid="${2:-}"; shift 2 ;;
    --call-id) call_id="${2:-}"; shift 2 ;;
    --interface) iface="${2:-}"; shift 2 ;;
    --duration) duration="${2:-}"; shift 2 ;;
    --filter) filter_expr="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ "$enabled" == "yes" ]] || { echo "Diagnostic capture disabled."; exit 0; }
[[ -n "$resource_uuid" && -n "$call_id" ]] || { echo "resource uuid and call id are required." >&2; exit 64; }
[[ "$duration" =~ ^[0-9]+$ && "$duration" -ge 1 && "$duration" -le 300 ]] || { echo "duration must be 1..300 seconds." >&2; exit 64; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 69; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 69; }
command -v dumpcap >/dev/null || { echo "dumpcap is required for pcapng capture." >&2; exit 69; }

api_base="${MNSCLOUD_API_BASE:-}"
api_token="${MNSCLOUD_API_TOKEN:-}"
[[ -n "$api_base" && -n "$api_token" ]] || { echo "MNSCLOUD_API_BASE and MNSCLOUD_API_TOKEN are required." >&2; exit 78; }

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
pcap="$tmp_dir/cdr-diagnostic.pcapng"

timeout "$duration" dumpcap -q -i "$iface" -f "$filter_expr" -w "$pcap" >/dev/null 2>&1 || true
[[ -s "$pcap" ]] || { echo "No packets captured." >&2; exit 75; }

size_bytes="$(stat -c '%s' "$pcap")"
checksum="$(sha256sum "$pcap" | awk '{print $1}')"

prepare_payload="$(jq -n \
  --arg module "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
  --arg resourceUUID "$resource_uuid" --arg diagnosticType "pcapng" \
  '{module:$module,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,diagnosticType:$diagnosticType,contentType:"application/vnd.tcpdump.pcap"}')"

prepare_response="$(curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics/upload-url" \
  -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" --data "$prepare_payload")"
upload_url="$(jq -r '.data.uploadUrl // empty' <<<"$prepare_response")"
storage_key="$(jq -r '.data.key // empty' <<<"$prepare_response")"
storage_account_uuid="$(jq -r '.data.storageAccountUUID // empty' <<<"$prepare_response")"
[[ -n "$upload_url" && -n "$storage_key" ]] || { echo "API did not return upload URL." >&2; exit 75; }

curl -fsS -X PUT "$upload_url" -H "Content-Type: application/vnd.tcpdump.pcap" --data-binary "@$pcap" >/dev/null

register_payload="$(jq -n \
  --arg module "$module" --arg engine "$engine" --arg resourceType "$resource_type" \
  --arg resourceUUID "$resource_uuid" --arg callID "$call_id" --arg storageAccountUUID "$storage_account_uuid" \
  --arg storageObjectKey "$storage_key" --arg checksumSha256 "$checksum" --argjson sizeBytes "$size_bytes" \
  '{module:$module,engine:$engine,resourceType:$resourceType,resourceUUID:$resourceUUID,callID:$callID,diagnosticType:"pcapng",captureMode:"pcapng",storageMode:"storage",storageAccountUUID:$storageAccountUUID,storageObjectKey:$storageObjectKey,originalFilename:"cdr-diagnostic.pcapng",contentType:"application/vnd.tcpdump.pcap",sizeBytes:$sizeBytes,checksumSha256:$checksumSha256,sanitized:false,containsSdp:true,containsPayload:true,status:"available"}')"

curl -fsS -X POST "${api_base%/}/api/v1/voip/cdr-diagnostics" \
  -H "Authorization: Bearer $api_token" -H "Content-Type: application/json" --data "$register_payload"
