# shellcheck shell=bash
# Read structured unit conditions when systemctl cannot format their D-Bus type.
rr_systemd_show() {
    local raw="" unit="" property="" argument="" object="" payload=""
    raw=$(systemctl show "$@") || return 1
    case "$raw" in
        '[unprintable]'|'Conditions=[unprintable]'|'Asserts=[unprintable]') ;;
        *) printf '%s\n' "$raw"; return 0 ;;
    esac
    for argument in "$@"; do
        case "$argument" in
            --property=Conditions|--property=Asserts) property="${argument#*=}" ;;
            --value) ;;
            -*) return 1 ;;
            *) [ -z "$unit" ] || return 1; unit="$argument" ;;
        esac
    done
    [ -n "$property" ] && [ -n "$unit" ] || return 1
    # D-Bus object path escaping is byte-wise, including underscores and dots.
    object=$(python3 - "$unit" <<'PY'
import re, sys
unit = sys.argv[1]
if not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.(service|timer|path)', unit):
    raise SystemExit(1)
print('/org/freedesktop/systemd1/unit/' + ''.join(
    chr(c) if (65 <= c <= 90 or 97 <= c <= 122 or 48 <= c <= 57)
    else f'_{c:02x}' for c in unit.encode()))
PY
    ) || return 1
    payload=$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$object" org.freedesktop.systemd1.Unit "$property") || return 1
    python3 - "$payload" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
if value.get('type') != 'a(sbbsi)' or not isinstance(value.get('data'), list):
    raise SystemExit(1)
records = []
for row in value['data']:
    if (not isinstance(row, list) or len(row) != 5
        or type(row[0]) is not str or type(row[1]) is not bool
        or type(row[2]) is not bool or type(row[3]) is not str
        or type(row[4]) is not int):
        raise SystemExit(1)
    kind, trigger, negate, parameter, state = row
    if any(c in kind + parameter for c in '{};\r\n'):
        raise SystemExit(1)
    records.append('{ type=' + kind + '; trigger=' + ('yes' if trigger else 'no')
        + '; negate=' + ('yes' if negate else 'no') + '; parameter=' + parameter
        + '; state=' + str(state) + '; }')
print(' '.join(records))
PY
}
