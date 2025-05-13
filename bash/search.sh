#!/bin/bash

# Color functions
green()   { echo -e "\e[32m$1\e[0m"; }
red()     { echo -e "\e[31m$1\e[0m"; }
yellow()  { echo -e "\e[33m$1\e[0m"; }

# Load settings.ini from the same directory as the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/settings.ini}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    red "Settings file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Check required variables
required_vars=(url_radarr token_api indexer_name list_ini)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        red "Error: Missing variable '$var' in settings file."
        yellow "Please check your configuration file."
        exit 1
    fi
done

# Ensure the list file exists
touch "$list_ini"

# Function: Check specific indexer
check_indexer() {
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET "${url_radarr}/api/v3/indexer" -H "X-Api-Key: ${token_api}")
    body="${response%HTTPSTATUS:*}"
    status="${response##*HTTPSTATUS:}"

    if [[ "$status" -ne 200 ]]; then
        red "API request failed with status code: $status"
        return 1
    fi

    id_indexer=$(echo "$body" | jq -r --arg name "$indexer_name" '.[] | select(.name == $name) | .id')

    if [[ -n "$id_indexer" ]]; then
        config_json=$(curl -s -H "X-Api-Key: ${token_api}" "${url_radarr}/api/v3/indexer/${id_indexer}")
        result=$(echo "$config_json" | curl -s -X POST "${url_radarr}/api/v3/indexer/test" \
            -H "X-Api-Key: ${token_api}" \
            -H "Content-Type: application/json" \
            --data-binary @-)

        if [[ "$result" == "{}" ]]; then
            return 0
        else
            red "Error testing indexer '${indexer_name}':"
            echo "$result" | jq
            return 1
        fi
    else
        red "Indexer '${indexer_name}' not found."
        exit 1
    fi
}

# Function: Test all indexers
test_all_indexers() {
    curl -s -X POST "${url_radarr}/api/v3/indexer/testall" -H "X-Api-Key: ${token_api}" > /dev/null
}

# Function: Get a movie to scan
get_movie_to_scan() {
    local max_attempts="$1"
    local found="nok"

    mapfile -t movies < <(echo "$body" | jq -c '.records | map(select(.status == "released")) | sort_by(.added) | reverse[]')

    for movie in "${movies[@]}"; do
        id=$(echo "$movie" | jq -r '.id')
        title=$(echo "$movie" | jq -r '.title')

        current_attempt=$(grep -E "^${id}=" "$list_ini" | cut -d'=' -f2)

        if [[ -z "$current_attempt" ]]; then
            echo "$id=1" >> "$list_ini"
            echo "Searching: $title (ID=$id, attempt #1)"
            found="yes"
            break
        elif (( current_attempt < max_attempts )); then
            new_attempt=$((current_attempt + 1))
            sed -i "s/^${id}=.*/${id}=${new_attempt}/" "$list_ini"
            echo "Searching: $title (ID=$id, attempt #$new_attempt)"
            found="yes"
            break
        fi
    done

    if [[ "$found" == "yes" ]]; then
        curl -s -X POST -H "X-Api-Key: ${token_api}" -H "Content-Type: application/json" \
            -d "{\"name\": \"MoviesSearch\", \"movieIds\": [${id}]}" \
            "${url_radarr}/api/v3/command" > /dev/null
    fi

    echo "$found"
}

# Function: Retrieve and process movie list
get_movie_list() {
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET \
        "${url_radarr}/api/v3/wanted/missing?page=1&pageSize=100&monitored=true" \
        -H "X-Api-Key: ${token_api}")

    body="${response%HTTPSTATUS:*}"
    status="${response##*HTTPSTATUS:}"

    if [[ "$status" -ne 200 ]]; then
        red "HTTP error: $status"
        return 1
    fi

    result=$(get_movie_to_scan 1)
    if [[ "$result" == "nok" ]]; then
        rm -f "$list_ini"
        exit 1
    else
        green "$result"
    fi
}

# Main Execution
if ! check_indexer; then
    yellow "Indexer '${indexer_name}' failed. Running fallback test for all indexers..."
    test_all_indexers
    exit 1
fi

get_movie_list
