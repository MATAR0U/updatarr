#!/bin/bash

# Color functions
green()   { echo -e "\e[32m$1\e[0m"; }
red()     { echo -e "\e[31m$1\e[0m"; }
yellow()  { echo -e "\e[33m$1\e[0m"; }

# Load settings.ini from the same directory as the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/settings.ini"

if [[ ! -f "$CONFIG_FILE" ]]; then
    red "Settings file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Radarr or sonarr option
while [[ $# -gt 0 ]]; do
    case "$1" in
        --radarr)
            if [[ -n "$api_url" ]]; then
                red "You cannot use both --radarr and --sonarr"
                exit 1
            fi
            radarr=true
            api_url="$radarr_url"
            api_key="$radarr_key"
            api_indexer="$radarr_indexer"
            list_ini="$radarr_ini"
            shift
            ;;
        --sonarr)
            if [[ -n "$api_url" ]]; then
                red "You cannot use both --radarr and --sonarr"
                exit 1
            fi
            sonarr=true
            api_url="$sonarr_url"
            api_key="$sonarr_key"
            api_indexer="$sonarr_indexer"
            list_ini="$sonarr_ini"
            shift
            ;;
        --no-indexer)
            api_indexer=""
            break
            ;;
        *)
            red "Invalid options."
            yellow "Mandatory options : \"--radarr\" or \"--sonarr\""
            yellow "Optionnal : \"--no-indexer\""
            exit 1
            ;;
    esac
done

if [[ -z "$api_url" ]]; then
    red "You must specify either --radarr or --sonarr, or please check your configuration file. You can run install.sh to rebuild it"
    yellow "Option \"--no-indexer\" must be placed last"
    exit 1
fi



# Check required variables
required_vars=(api_url api_key list_ini unsatisfactory)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        red "Error: Missing variable '$var' in settings file."
        yellow "Please check your configuration file. You can run install.sh to rebuild it"
        exit 1
    fi
done

# Ensure the list file exists
touch "$list_ini"

# Function: Check specific indexer
check_indexer() {
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET "${api_url}/api/v3/indexer" -H "X-Api-Key: ${api_key}")
    body="${response%HTTPSTATUS:*}"
    status="${response##*HTTPSTATUS:}"

    if [[ "$status" -ne 200 ]]; then
        red "API request failed with status code: $status"
        return 1
    fi

    id_indexer=$(echo "$body" | jq -r --arg name "$api_indexer" '.[] | select(.name == $name) | .id')

    if [[ -n "$id_indexer" ]]; then
        config_json=$(curl -s -H "X-Api-Key: ${api_key}" "${api_url}/api/v3/indexer/${id_indexer}")
        result=$(echo "$config_json" | curl -s -X POST "${api_url}/api/v3/indexer/test" \
            -H "X-Api-Key: ${api_key}" \
            -H "Content-Type: application/json" \
            --data-binary @-)

        if [[ "$result" == "{}" ]]; then
            return 0
        else
            red "Error testing indexer '${api_indexer}':"
            echo "$result" | jq
            return 1
        fi
    else
        red "Indexer '${api_indexer}' not found."
        exit 1
    fi
}

# Function: Test all indexers
test_all_indexers() {
    curl -s -X POST "${api_url}/api/v3/indexer/testall" -H "X-Api-Key: ${api_key}" > /dev/null
}

# Send command to API
send_command() {
  local api_url="$1"
  local api_key="$2"
  local name="$3"
  local id="$4"
  local id_name="$5"
  
  curl -s -X POST -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
       -d "{\"name\": \"${name}\", \"${id_name}\": ${id}}" \
       "${api_url}/api/v3/command" > /dev/null
}

# Function to handle movie and series processing
process_item() {
    local item="$1"
    local max_attempts="$2"
    local list_ini="$3"
    local type="$4"
    
    local id title current_attempt new_attempt

    if [ "$radarr" = "true" ]; then
        id=$(echo "$item" | jq -r '.id')
        title=$(echo "$item" | jq -r '.title')
    fi
    if [ "$sonarr" = "true" ]; then
        id=$(echo "$item" | jq -r '.series.id')
        title=$(echo "$item" | jq -r '.series.title')
    fi

    current_attempt=$(grep -E "^${id}=" "$list_ini" | cut -d'=' -f2)

    if [[ -z "$current_attempt" ]]; then
        echo "$id=1" >> "$list_ini"
        echo "Searching: $title (ID=$id, attempt #1)"
        return 0
    elif (( current_attempt < max_attempts )); then
        new_attempt=$((current_attempt + 1))
        sed -i "s/^${id}=.*/${id}=${new_attempt}/" "$list_ini"
        echo "Searching: $title (ID=$id, attempt #$new_attempt)"
        return 0
    fi

    return 1
}

# Function: Get a movie or series to scan
get_item_to_scan() {
    local max_attempts="$1"
    local found="nok"

    # Process Movies
    if [ "$radarr" = "true" ]; then
        mapfile -t movies < <(echo "$body" | jq -c '.records | map(select(.status == "released")) | sort_by(.added) | reverse[]')
        for movie in "${movies[@]}"; do
            if process_item "$movie" "$max_attempts" "$list_ini" "movie"; then
                movie_id=$(echo "$movie" | jq -r '.id')
                send_command "$api_url" "$api_key" "MoviesSearch" "[$movie_id]" "movieIds"
                found="yes"
                break
            fi
        done
    fi

    # Process Series
    if [ "$sonarr" = "true" ]; then
        mapfile -t series < <(echo "$body" | jq -c '.records | sort_by(.added) | reverse[]')
        for serie in "${series[@]}"; do
            if process_item "$serie" "$max_attempts" "$list_ini" "serie"; then
                series_id=$(echo "$serie" | jq -r '.series.id')
                send_command "$api_url" "$api_key" "MissingEpisodeSearch" "$series_id" "seriesId"
                found="yes"
                break
            fi
        done
    fi

    echo "$found"
}

# Search for unsatisfactory movie
get_movie_unsatisfactory() {
    yellow "Recovery of the film with the lowest score..."
    movies_list=$(curl -s -X GET "${api_url}/api/v3/movie" -H "X-Api-Key: ${api_key}")
    movie_ids_brut=$(echo "$movies_list" | jq '[.[] | .movieFileId]')
    movie_ids=$(echo "$movie_ids_brut" | sed 's/null//g' | tr -d '[]' | tr -d '\n' | tr ',' ' ')
    movie_ids_array=($movie_ids)

    lowest_score=-1
    lowest_score_id=""

    for movie_id in "${movie_ids_array[@]}"; do
        if [ "$movie_id" -ne 0 ]; then
            # Get info
            movie_info=$(curl -s -X GET "${api_url}/api/v3/moviefile/$movie_id" -H "X-Api-Key: $api_key")

            score=$(echo $movie_info | jq -r ".customFormatScore")

            # Verify score
            if [ "$lowest_score" -eq -1 ] || [ "$score" -lt "$lowest_score" ]; then
                lowest_score=$score
                lowest_score_id=$(echo $movie_info | jq -r ".movieId")
            fi
        fi
    done

    if [ -n "$lowest_score_id" ]; then
        green "Movie with lowest score : ID $lowest_score_id = $lowest_score"
        send_command "$api_url" "$api_key" "MoviesSearch" "[$lowest_score_id]" "movieIds"
    else
        yellow "No film has a score below -1"
    fi
}
get_movie_unsatisfactory
exit
# Function: Retrieve and process item list
get_item_list() {
    if [ "$radarr" = "true" ]; then
        response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET \
            "${api_url}/api/v3/wanted/missing?page=1&pageSize=100&monitored=true" \
            -H "X-Api-Key: ${api_key}")
    fi
    if [ "$sonarr" = "true" ]; then
        response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET \
            "${api_url}/api/v3/wanted/missing?page=1&pageSize=100&monitored=true&includeSeries=true" \
            -H "X-Api-Key: ${api_key}")
    fi

    body="${response%HTTPSTATUS:*}"
    status="${response##*HTTPSTATUS:}"

    if [[ "$status" -ne 200 ]]; then
        red "HTTP error: $status"
        return 1
    fi

    result=$(get_item_to_scan 1)
    if [[ "$result" == "nok" ]]; then
        if unsatisfactory && radarr; then
            get_movie_unsatisfactory
        fi
        rm -f "$list_ini"
        exit 1
    else
        green "$result"
    fi
}

# Main Execution
if [[ -n "$api_indexer" ]]; then
    if ! check_indexer; then
        yellow "Indexer '${api_indexer}' failed. Running fallback test for all indexers..."
        test_all_indexers
        exit 1
    fi
else
    yellow "No api_indexer provided — skipping indexer check."
fi

get_item_list