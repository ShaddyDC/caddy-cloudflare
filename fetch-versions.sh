#!/usr/bin/env bash

# Error handling
set -euo pipefail
IFS=$'\n\t'

# Logging function
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Function to make a curl request and handle errors
make_request() {
  local url="$1"
  local headers=("${@:2}")
  local response
  local http_code

  log "Making request to $url"
  response=$(curl -fsSL -w "%{http_code}" "${headers[@]}" "$url")
  http_code=${response: -3}
  body=${response:0:${#response}-3}

  log "Received HTTP status code: $http_code"

  if [[ $http_code -ne 200 ]]; then
    log "Error: HTTP $http_code for $url"
    log "Response body:"
    log "$body"
    return 1
  fi

  echo "$body"
}

# Get token
log "Requesting auth token"
token_response=$(make_request "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/caddy:pull")
if [[ -z "$token_response" ]]; then
  log "Error: Empty token response"
  exit 1
fi

log "Parsing token from response"
token=$(echo "$token_response" | jq --raw-output '.token')
if [[ -z "$token" || "$token" == "null" ]]; then
  log "Error: Failed to extract token from response"
  log "Token response: $token_response"
  exit 1
fi
export token

# Get manifest
log "Requesting manifest"
manifest_response=$(make_request "https://registry.hub.docker.com/v2/library/caddy/manifests/builder" -H "Authorization: Bearer $token")
if [[ -z "$manifest_response" ]]; then
  log "Error: Empty manifest response"
  exit 1
fi

log "Parsing manifest list"
# Get the current architecture
current_arch=$(uname -m)
case $current_arch in
x86_64) docker_arch="amd64" ;;
aarch64) docker_arch="arm64" ;;
armv7l) docker_arch="arm" ;;
*) docker_arch=$current_arch ;;
esac

log "Current architecture: $docker_arch"

# Find the manifest for the current architecture
manifest=$(echo "$manifest_response" | jq --arg arch "$docker_arch" '.manifests[] | select(.platform.architecture == $arch)')

if [[ -z "$manifest" || "$manifest" == "null" ]]; then
  log "Error: No manifest found for architecture $docker_arch"
  log "Available architectures:"
  echo "$manifest_response" | jq -r '.manifests[].platform.architecture' | sort -u
  exit 1
fi

log "Parsing created date from manifest"
created=$(echo "$manifest" | jq -r '.annotations["org.opencontainers.image.created"]' | sed -n '1p')
if [[ -z "$created" || "$created" == "null" ]]; then
  log "Error: Failed to extract created date from manifest"
  log "Manifest for $docker_arch:"
  echo "$manifest" | jq .
  exit 1
fi
export created
log "Creation date: $created"

log "Parsing Caddy version from manifest"
caddy_version=$(echo "$manifest" | jq -r '.annotations["org.opencontainers.image.version"]' | sed -n '1p')
if [[ -z "$caddy_version" || "$caddy_version" == "null" ]]; then
  log "Error: Failed to extract Caddy version from manifest"
  log "Manifest for $docker_arch:"
  echo "$manifest" | jq .
  exit 1
fi
export caddy_version
log "Caddy version: $caddy_version"

log "Writing output"
{
  echo "latest_version=$caddy_version"
  echo "current_version=$(<caddy.version)"
  echo "latest_created=$created"
  echo "current_created=$(<caddy.created)"

  if [[ "$caddy_version" != "$(<caddy.version)" ]]; then
    echo "updated=true"
  else
    echo "updated=false"
  fi
} >>"$GITHUB_OUTPUT"

log "Script completed successfully"
