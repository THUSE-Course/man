#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "supports" ]]; then
  [[ "${2:-}" == "html" ]]
  exit $?
fi

if [[ $# -gt 0 ]]; then
  echo "unsupported arguments: $*" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run the secoder-domain mdBook preprocessor" >&2
  exit 1
fi

base_domain="${SECODER_BASE_DOMAIN:-t.secoder.net}"
if [[ -z "${base_domain//[[:space:]]/}" ]]; then
  base_domain="t.secoder.net"
fi

jq --arg base_domain "$base_domain" '
  .[1]
  | def replace_domain_token:
      if type == "object" and has("Chapter") then
        .Chapter.content |= gsub("@@SECODER_BASE_DOMAIN@@"; $base_domain)
      else
        .
      end;
    def walk_book:
      if type == "array" then
        map(walk_book)
      elif type == "object" then
        replace_domain_token | with_entries(.value |= walk_book)
      else
        .
      end;
    walk_book
'
