#!/bin/bash

# Export Nginx Proxy Manager's configuration through its API.
#
# NPM has no export in its UI, so the proxy hosts, streams, access lists and —
# above all — the hand-written "Advanced" snippets exist only inside its database.
# This dumps all of it to JSON, plus a readable summary.md, which is what rebuilding
# the ingress on something else (Traefik, plain nginx) would need.
#
# summary.md is dated from npm-config/exported-on, which only a complete fetch writes, so
# a --summary-only run keeps the date of the data it was built from.
#
# Runs from anywhere with LAN or Wireguard access, unlike export_all_stacks.sh
# which talks to Portainer on localhost.
#
# Usage: ./export_npm_config.sh --help
#
# Masking: npm-mask.env.json, next to this script and gitignored, maps values to the
# placeholder that replaces them, for things the vault keeps masked too. The WireGuard port
# is the one that matters: the router forwards only that UDP port, and this repo is public.
#   {"<wg port>": "WG_PORT"}
# A value is replaced only where it is a whole JSON value (a number or a string), never
# inside a longer string such as an Advanced snippet. The file is required, so a run cannot
# forget it; make it {} if there is nothing to hide.
#
# TLS is verified. npm.one137.dev presents the real Let's Encrypt wildcard, so there is no
# reason to skip it — and the token request carries the admin password. Set NPM_INSECURE=1
# only when pointing NPM_URL somewhere the certificate cannot match, such as https://ct-npm
# or a bare IP (that is why export_all_stacks.sh uses curl -k for Portainer on localhost).
#
# Secrets are NOT exported: anything PEM-encoded (certificate private keys, bodies and
# intermediates), the Cloudflare DNS token NPM keeps for the DNS challenge, access list
# passwords and their hints, and the Let's Encrypt email are replaced by "REDACTED". The owner expansion is not requested
# either, as it carries the admin account's email and name. None of this is needed to
# rebuild the routing, and all of it is recoverable from Cloudflare or by re-issuing the
# certificates. This matters because dockerhost-stacks is a public repo.
#
# NPM's custom include files are files, not API data. The one in use, http_top.conf, is
# copied by hand, from within npm-config/:
#   scp dockerhost:/srv/docker/volumes/npm/data/nginx/custom/http_top.conf .

# Constants
NPM_URL="${NPM_URL:-https://npm.one137.dev}"

CURL_OPTS=(-sS)
[[ "$NPM_INSECURE" == "1" ]] && CURL_OPTS+=(-k)
SCRIPT_DIR=$(dirname "$0")
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/npm-config}"
NPM_MASK_FILE="${NPM_MASK_FILE:-$SCRIPT_DIR/npm-mask.env.json}"

# Collections to fetch: <name>:<api path>
COLLECTIONS=(
    "proxy-hosts:nginx/proxy-hosts?expand=access_list,certificate"
    "redirection-hosts:nginx/redirection-hosts?expand=certificate"
    "dead-hosts:nginx/dead-hosts?expand=certificate"
    "streams:nginx/streams?expand=certificate"
    "access-lists:nginx/access-lists?expand=items,clients"
    "certificates:nginx/certificates"
)

usage() {
    cat << 'EOF'
Usage:
  NPM_EMAIL=... NPM_PASS=... ./export_npm_config.sh [--print-token]
  NPM_TOKEN=...              ./export_npm_config.sh      # reuse a token (they expire after a day)
  ./export_npm_config.sh --summary-only                  # rebuild summary.md from the JSON

Options:
  --print-token    show the token requested with NPM_EMAIL and NPM_PASS, to reuse as NPM_TOKEN
  --summary-only   don't call NPM: re-apply redaction and masks to the JSON in OUTPUT_DIR,
                   and rebuild summary.md from it
  -h, --help       show this help

Environment:
  NPM_URL          default https://npm.one137.dev
  NPM_INSECURE=1   skip TLS verification, only for an NPM_URL the certificate cannot match
  NPM_MASK_FILE    values to mask (required), default npm-mask.env.json next to this script
  OUTPUT_DIR       default npm-config next to this script
EOF
}

SUMMARY_ONLY=false
PRINT_TOKEN=false
for ARG in "$@"; do
    case "$ARG" in
        --summary-only) SUMMARY_ONLY=true ;;
        --print-token) PRINT_TOKEN=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $ARG"
            echo
            usage
            exit 1
            ;;
    esac
done

if ! command -v jq > /dev/null; then
    echo "Please install jq"
    exit 1
fi

if [[ "$SUMMARY_ONLY" == false && -z "$NPM_TOKEN" && (-z "$NPM_EMAIL" || -z "$NPM_PASS") ]]; then
    echo "Please define \$NPM_TOKEN, or \$NPM_EMAIL and \$NPM_PASS"
    echo
    usage
    exit 1
fi

# Keys whose value never leaves NPM, and any string holding a PEM block, whatever its key:
# that covers a custom certificate's body and intermediate as well as every private key.
REDACT='
  def secret_key: IN("password", "hint", "username", "private_key", "certificate_key",
                     "dns_provider_credentials", "letsencrypt_email");
  def pem: type == "string" and test("-----BEGIN ");
  walk(
    if type == "object"
    then with_entries(select(.key != "owner") | if .key | secret_key then .value = "REDACTED" else . end)
    elif pem then "REDACTED"
    else . end
  )
'

# Masking. Numbers become strings, which keeps the JSON valid, and re-running is a no-op
# once a value has been replaced.
MASK='
  walk(
    if type == "number" or type == "string"
    then $masks[tostring] // .
    else . end
  )
'

if [[ ! -f "$NPM_MASK_FILE" ]]; then
    echo "Error: no mask file at $NPM_MASK_FILE"
    echo "  It maps the values this public repo must not show to a placeholder, such as"
    echo "  {\"<wg port>\": \"WG_PORT\"}. Create it (*.env.json is gitignored), as {} if there"
    echo "  is nothing to hide."
    exit 1
fi
if ! MASKS=$(jq -ce 'select(type == "object" and all(.[]; type == "string"))' "$NPM_MASK_FILE" 2>/dev/null); then
    echo "Error: $NPM_MASK_FILE must be a JSON object of strings, such as {\"<wg port>\": \"WG_PORT\"}"
    exit 1
fi
echo -e "Masking $(jq 'length' <<< "$MASKS") value(s) from $NPM_MASK_FILE\n"

# The one step that writes NPM data to disk, in both modes.
clean() { jq --argjson masks "$MASKS" "$REDACT | $MASK" "$@"; }

mkdir -p "$OUTPUT_DIR"

if [[ "$SUMMARY_ONLY" == false ]]; then
    if [[ -z "$NPM_TOKEN" ]]; then
        # Secrets go through the environment and stdin, never on a command line, where any
        # local user could read them in ps while curl runs. Same for the token below.
        echo "Requesting a token for $NPM_EMAIL at $NPM_URL"
        TOKEN_RESPONSE=$(jq -nc '{identity: env.NPM_EMAIL, secret: env.NPM_PASS}' \
            | curl "${CURL_OPTS[@]}" -X POST "$NPM_URL/api/tokens" \
                -H "Content-Type: application/json" -d @- 2>&1)
        CURL_STATUS=$?

        if [[ $CURL_STATUS -ne 0 ]]; then
            echo "Error: could not reach $NPM_URL (curl exit $CURL_STATUS)"
            echo "  $TOKEN_RESPONSE"
            if [[ $CURL_STATUS -eq 60 ]]; then
                echo "  The certificate was not verified, so the password was not sent."
                echo "  Set NPM_INSECURE=1 if NPM_URL is deliberately not npm.one137.dev."
            fi
            exit 1
        fi

        NPM_TOKEN=$(jq -r '.token // empty' <<< "$TOKEN_RESPONSE" 2>/dev/null)
        if [[ -z "$NPM_TOKEN" ]]; then
            echo "Error: could not get a token. NPM said:"
            jq . <<< "$TOKEN_RESPONSE" 2>/dev/null || echo "  $TOKEN_RESPONSE"
            exit 1
        fi
        EXPIRES=$(jq -r '.expires // "?"' <<< "$TOKEN_RESPONSE")
        if [[ "$PRINT_TOKEN" == true ]]; then
            echo -e "Got token '${NPM_TOKEN}', expiring $EXPIRES\n"
        else
            echo -e "Got a token, expiring $EXPIRES (--print-token shows it, to reuse as \$NPM_TOKEN)\n"
        fi
    fi

    # Every response is redacted and masked before it is written, so nothing unmasked
    # reaches the disk.
    FAILED=()
    for COLLECTION in "${COLLECTIONS[@]}"; do
        NAME="${COLLECTION%%:*}"
        PATH_AND_QUERY="${COLLECTION#*:}"

        echo "Fetching $NAME"
        RESPONSE=$(printf 'Authorization: Bearer %s\n' "$NPM_TOKEN" \
            | curl "${CURL_OPTS[@]}" "$NPM_URL/api/$PATH_AND_QUERY" -H @- 2>&1)
        CURL_STATUS=$?

        if [[ $CURL_STATUS -ne 0 ]]; then
            echo "  Warning: request failed (curl exit $CURL_STATUS). Skipping."
            echo "    $RESPONSE"
            FAILED+=("$NAME")
            continue
        fi
        if [[ -z "$RESPONSE" ]]; then
            echo "  Warning: empty response. Skipping."
            FAILED+=("$NAME")
            continue
        fi
        if ! COUNT=$(jq 'if type == "array" then length else error end' <<< "$RESPONSE" 2>/dev/null); then
            echo "  Warning: unexpected response. NPM said:"
            jq -c . <<< "$RESPONSE" 2>/dev/null || echo "  $RESPONSE"
            FAILED+=("$NAME")
            continue
        fi

        JSON_PATH="$OUTPUT_DIR/$NAME.json"
        clean <<< "$RESPONSE" > "$JSON_PATH"
        echo "  Saved $COUNT entries to $JSON_PATH"
    done
    echo

    # Only a complete fetch is dated: with a collection missing, the JSON mixes two exports.
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo "Error: could not fetch ${FAILED[*]}. Their JSON was not updated, so summary.md was not rewritten."
        exit 1
    fi
    date +'%Y-%m-%d' > "$OUTPUT_DIR/exported-on"
else
    # Re-applied to whatever JSON is in OUTPUT_DIR, so a mask added later also cleans an
    # export taken earlier.
    for JSON_FILE in "$OUTPUT_DIR"/*.json; do
        [[ -e "$JSON_FILE" ]] || continue
        CLEANED=$(clean "$JSON_FILE") && echo "$CLEANED" > "$JSON_FILE"
    done
fi

# Summary

if [[ ! -f "$OUTPUT_DIR/proxy-hosts.json" ]]; then
    echo "No $OUTPUT_DIR/proxy-hosts.json to summarise."
    exit 1
fi

SUMMARY="$OUTPUT_DIR/summary.md"
EXPORTED_ON=$(cat "$OUTPUT_DIR/exported-on" 2>/dev/null) || EXPORTED_ON="an unknown date"

# Helpers shared by every summary program.
# A location's forward host can carry a path ("ct-clipse-api/"). NPM splits it off at the
# first "/" and appends it after the port, so that upstream is http://ct-clipse-api:8080/.
# The path decides whether nginx strips the location prefix, so the summary must show it.
JQ_LIB='
  def on($v): ($v == true) or ($v == 1);   # NPM returns booleans; older versions 0/1
  def flag(f; $label): if on(f) then $label else empty end;
  def disabled: if on(.enabled) then empty else "**disabled**" end;
  def has_advanced: (.advanced_config // "") != "";
  def cert: .certificate.nice_name // (if (.certificate_id // 0) == 0 then "_none_" else "#\(.certificate_id)" end);
  def hosts: sort_by(.domain_names[0]) | .[];
  def row: "| " + join(" | ") + " |";
  def upstream: (.forward_host | split("/")[0]) as $host
    | "\(.forward_scheme)://\($host):\(.forward_port)\(.forward_host[($host | length):])";
'
summarise() { jq -r "$JQ_LIB$1" "$OUTPUT_DIR/$2"; }

# A table under its own heading, left out when its file is missing or yields no row, so
# a host type that is not in use doesn't show up, and one that is never goes unseen.
# Usage: table <title> <header row> <file> <jq program>
table() {
    [[ -f "$OUTPUT_DIR/$3" ]] || return 0
    local ROWS
    ROWS=$(summarise "$4" "$3")
    [[ -n "$ROWS" ]] || return 0
    printf '\n## %s\n\n%s\n' "$1" "$2"
    sed 's/[^|]\+/ --- /g' <<< "$2"
    echo "$ROWS"
}

{
    echo "# NPM configuration"
    echo
    echo "Exported from NPM on $EXPORTED_ON by \`export_npm_config.sh\`. Secrets are redacted; see the script header."

    table "Proxy hosts" "| Domains | Upstream | Options | Access list | Certificate | Advanced |" proxy-hosts.json '
      hosts |
      [
        (.domain_names | join("<br>")),
        "`\(.forward_scheme)://\(.forward_host):\(.forward_port)`",
        ([
          flag(.allow_websocket_upgrade; "WS"),
          flag(.http2_support; "HTTP2"),
          flag(.ssl_forced; "force SSL"),
          flag(.block_exploits; "block exploits"),
          flag(.caching_enabled; "cache"),
          flag(.trust_forwarded_proto; "trust X-Forwarded-Proto"),
          disabled
        ] | join(", ")),
        (.access_list.name // (if (.access_list_id // 0) == 0 then "_public_" else "#\(.access_list_id)" end)),
        cert,
        ([
          (if has_advanced then "custom" else empty end),
          (.locations // [] | length | select(. > 0) | "\(.) location(s)")
        ] | join(", "))
      ] | row
    '

    # Locations route a path inside a proxy host, which is where services that live under
    # a path of one137.dev sit. They are invisible in the table above.
    table "Paths inside a proxy host" "| Host | Path | Upstream |" proxy-hosts.json '
      hosts | .domain_names[0] as $host | .locations[]? |
      [$host, "`\(.path)`", "`\(upstream)`"] | row
    '

    # NPM answers these itself. The redirect is shown as the nginx `return` it renders to.
    table "Redirection hosts" "| Domains | Redirect | Options | Certificate | Advanced |" redirection-hosts.json '
      hosts |
      [
        (.domain_names | join("<br>")),
        "`\(.forward_http_code) \(if .forward_scheme == "auto" then "$scheme" else .forward_scheme end)://\(.forward_domain_name)\(if on(.preserve_path) then "$request_uri" else "" end)`",
        ([flag(.http2_support; "HTTP2"), flag(.ssl_forced; "force SSL"), flag(.block_exploits; "block exploits"), disabled] | join(", ")),
        cert,
        (if has_advanced then "custom" else "" end)
      ] | row
    '

    table "404 hosts" "| Domains | Options | Certificate | Advanced |" dead-hosts.json '
      hosts |
      [
        (.domain_names | join("<br>")),
        ([flag(.http2_support; "HTTP2"), flag(.ssl_forced; "force SSL"), disabled] | join(", ")),
        cert,
        (if has_advanced then "custom" else "" end)
      ] | row
    '

    table "Streams" "| Incoming port | Forwards to | Protocol |" streams.json '
      sort_by(.incoming_port) | .[] |
      [
        "`\(.incoming_port)`",
        "`\(.forwarding_host):\(.forwarding_port)`",
        ([flag(.tcp_forwarding; "TCP"), flag(.udp_forwarding; "UDP")] | join(" + "))
          + (if on(.enabled) then "" else " (**disabled**)" end)
      ] | row
    '

    if [[ -f "$OUTPUT_DIR/access-lists.json" ]]; then
        echo
        echo "## Access lists"
        summarise '
          .[] |
          "",
          "### \(.name)\n",
          "- Satisfy: \(if on(.satisfy_any) then "any" else "all" end)",
          "- Pass auth upstream: \(if on(.pass_auth) then "yes" else "no" end)",
          "- Used by \(.proxy_host_count // 0) proxy host(s)",
          ((.clients // []) | if length > 0 then
            "- Rules:", (.[] | "    - `\(.directive) \(.address)`")
          else "- Rules: _none_" end),
          ((.items // []) | if length > 0 then
            "- Basic auth: \(length) user(s), credentials not exported"
          else empty end)
        ' access-lists.json
    fi

    table "Certificates" "| Name | Domains | Provider | Expires |" certificates.json '
      sort_by(.nice_name) | .[] |
      [
        .nice_name,
        (.domain_names | join("<br>")),
        .provider,
        (.expires_on // "-")
      ] | row
    '

    # The part that exists nowhere else: hand-written nginx snippets.
    echo
    echo "## Advanced configuration"
    echo
    echo "These snippets are typed into NPM's UI and live only in its database."
    echo

    if [[ -f "$OUTPUT_DIR/http_top.conf" ]]; then
        echo "They can also rely on \`data/nginx/custom/http_top.conf\`, which NPM includes at the top of its \`http\` block (a log format, for one). That file is not API data: [\`http_top.conf\`](http_top.conf) is a copy taken by hand, with \`scp dockerhost:/srv/docker/volumes/npm/data/nginx/custom/http_top.conf .\`. Its commented-out \`set_real_ip_from\` lines don't mean real-IP is off: NPM's own \`nginx.conf\` already sets them, with \`real_ip_header X-Real-IP\`."
        echo
    fi

    # Every kind of host can carry a snippet, and so can a proxy host's locations.
    HOST_FILES=()
    for NAME in proxy-hosts redirection-hosts dead-hosts; do
        [[ -f "$OUTPUT_DIR/$NAME.json" ]] && HOST_FILES+=("$OUTPUT_DIR/$NAME.json")
    done
    jq -rs "$JQ_LIB"'
      [add | hosts | select(has_advanced or any(.locations[]?; has_advanced))] |
      if length == 0 then "_None._" else .[] |
        "### \(.domain_names | join(", "))\n",
        (select(has_advanced) | "```nginx\n\(.advanced_config)\n```\n"),
        (.locations[]? | select(has_advanced) |
          "Location `\(.path)` → `\(upstream)`\n",
          "```nginx\n\(.advanced_config)\n```\n"
        )
      end
    ' "${HOST_FILES[@]}"
} > "$SUMMARY"

echo "Wrote $SUMMARY"
