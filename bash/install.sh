#!/bin/bash

# Color functions
green()   { echo -e "\e[32m$1\e[0m"; }
red()     { echo -e "\e[31m$1\e[0m"; }
yellow()  { echo -e "\e[33m$1\e[0m"; }

# --------- Check for curl installation ---------
if ! command -v curl >/dev/null 2>&1; then
  yellow "curl is not installed"
  yellow "Detecting package manager..."

  if command -v apt >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y curl
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm curl
  else
    red "Unsupported package manager. Please install curl manually."
    exit 1
  fi
else
  green "curl is already installed"
fi

# --------- Select working directory ---------
while true; do
  echo "Current working directory: $(pwd)"
  read -p "Use this directory? (y/n): " confirm
  case "$confirm" in
    y)
      working_dir=$(pwd)
      ;;
    n)
      read -p "Enter working directory path: " working_dir
      ;;
    *)
      red "Invalid choice. Please enter y or n."
      continue
      ;;
  esac

  if [ -d "$working_dir" ]; then
    green "Working directory set to: $working_dir"
    break
  else
    red "Directory does not exist: $working_dir"
  fi
done

# --------- Ask for Radarr URL ---------
radarr_regex='^[A-Za-z]+://((25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2}):[0-9]+$'

while true; do
  read -p "Radarr URL (http://{ip}:{port}): " url_radarr

  if [[ "$url_radarr" =~ $radarr_regex ]]; then
    yellow "Checking connection to $url_radarr..."
    if curl -Is --max-time 15 "$url_radarr" | head -n 1 | grep -qE "HTTP/[0-9\.]+\s+[0-9]+"; then
      green "[OK] $url_radarr is reachable"
      break
    else
      red "[KO] $url_radarr is not reachable"
      yellow "Check the URL or network access"
    fi
  else
    red "Invalid URL format"
  fi
done

# --------- API Token ---------
read -s -p "Enter API key: " token_api
echo

# --------- Get indexer ID by name ---------
while true; do
    read -p "Enter EXACT indexer name (optional): " indexer_name

    if [ "$indexer_name" = "" ]; then
        yellow "Skip indexer"
        break
    fi

    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET "$url_radarr/api/v3/indexer" -H "X-Api-Key: $token_api")
    body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
    http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

    if [ "$http_status" -ne 200 ]; then
        red "API error ($http_status)"
        exit 1
    fi

    id_indexer=$(echo "$body" | jq -r --arg name "$indexer_name" '.[] | select(.name == $name) | .id')

    if [ -n "$id_indexer" ]; then
        green "[OK] Indexer found: $indexer_name"
        break
    else
        red "Indexer not found: $indexer_name"
    fi
done

# --------- Save configuration ---------
config_file="$working_dir/settings.ini"
{
  echo "url_radarr=\"$url_radarr\""
  echo "token_api=\"$token_api\""
  echo "indexer_name=\"$indexer_name\""
  echo "list_ini=\"$working_dir/list.ini\""
} > "$config_file"

green "Configuration saved to $config_file"
