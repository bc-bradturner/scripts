#!/bin/zsh
# Parse and prettify BigCommerce app logs with JSON payloads
#
# Usage: parse_logs.zsh [-x PATTERN ...] < logfile.log
#        tail -f logfile.log | parse_logs.zsh -x 'EmitterException' -x 'some_noise'
#
# -x/--exclude PATTERN   Drop lines matching PATTERN (grep -E, repeatable, applied like grep -v)

typeset -a exclude_patterns
while [[ $# -gt 0 ]]; do
    case "$1" in
        -x|--exclude)
            exclude_patterns+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

while IFS= read -r line; do
    # Skip empty lines
    [[ -z "$line" ]] && continue

    # Drop lines matching any exclude pattern (checked inline, not via a
    # piped grep, so we don't block-buffer output on a live-following stream)
    if (( ${#exclude_patterns[@]} > 0 )); then
        excluded=0
        for pat in "${exclude_patterns[@]}"; do
            if [[ $line =~ $pat ]]; then
                excluded=1
                break
            fi
        done
        (( excluded )) && continue
    fi

    # Parse syslog format: "Mmm DD HH:MM:SS.mmm hostname process[pid]: MESSAGE"
    if [[ $line =~ "^(.+) ([^ ]+) ([^ \[]+)\[([0-9]+)\]: (.+)$" ]]; then
        timestamp="$match[1]"
        hostname="$match[2]"
        process="$match[3]"
        pid="$match[4]"
        content="$match[5]"

        # Extract error level
        if [[ $content =~ "^([^:]+): (.+)$" ]]; then
            level="$match[1]"
            rest="$match[2]"
        else
            level=""
            rest="$content"
        fi

        # One-line condensed header
        printf "\033[36m%s\033[0m %s:%s[%s]" "$timestamp" "$hostname" "$process" "$pid"
        [[ -n "$level" ]] && printf " \033[33m%s\033[0m" "$level"
        echo

        # Split message from JSON
        if [[ $rest =~ "^([^{]+)(.+)$" ]]; then
            msg="${match[1]%% }"
            json_content="$match[2]"

            [[ -n "$msg" ]] && echo "  $msg"

            # Extract each JSON object/array and print it compact (one line, valid JSON)
            if [[ -n "$json_content" ]] && command -v python3 &>/dev/null; then
                LOG_JSON_CONTENT="$json_content" python3 <<'PYTHON'
import json
import os

content = os.environ["LOG_JSON_CONTENT"]
depth = 0
start = -1
in_string = False
escape = False
for i, char in enumerate(content):
    if escape:
        escape = False
        continue
    if char == "\\" and in_string:
        escape = True
        continue
    if char == '"':
        in_string = not in_string
        continue
    if in_string:
        continue
    if char in "{[":
        if depth == 0:
            start = i
        depth += 1
    elif char in "}]":
        depth -= 1
        if depth == 0 and start >= 0:
            raw = content[start:i + 1]
            try:
                obj = json.loads(raw)
                print("  " + json.dumps(obj, separators=(",", ":")))
            except Exception:
                print("  " + raw)
            start = -1
PYTHON
            elif [[ -n "$json_content" ]]; then
                echo "  $json_content"
            fi
        else
            [[ -n "$rest" ]] && echo "  $rest"
        fi
    else
        # Line doesn't match log format, print as-is
        echo "$line"
    fi
done

