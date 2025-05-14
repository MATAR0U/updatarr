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
url_regex='^[A-Za-z]+://((25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2}):[0-9]+$'
while true; do
  while true; do
    read -p "Radarr URL (http://{ip}:{port}) (blank for skip): " radarr_url

    if [[ "$radarr_url" = "" ]]; then
      break
    fi

    if [[ "$radarr_url" =~ $url_regex ]]; then
      yellow "Checking connection to $radarr_url..."
      if curl -Is --max-time 15 "$radarr_url" | head -n 1 | grep -qE "HTTP/[0-9\.]+\s+[0-9]+"; then
        green "[OK] $radarr_url is reachable"
        break
      else
        red "[KO] $radarr_url is not reachable"
        yellow "Check the URL or network access"
      fi
    else
      red "Invalid URL format"
    fi
  done

  if [[ "$radarr_url" = "" ]]; then
      yellow "Skipping radarr configuration..."
      break
  fi

  # --------- API Token ---------
  read -s -p "Radarr API key: " radarr_key
  echo

  # --------- Get indexer ID by name ---------
  while true; do
      read -p "EXACT radarr indexer name (optional): " radarr_indexer

      if [ "$radarr_indexer" = "" ]; then
          yellow "Skip indexer"
          break
      fi

      response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET "$radarr_url/api/v3/indexer" -H "X-Api-Key: $radarr_key")
      body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
      http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

      if [ "$http_status" -ne 200 ]; then
          red "API error ($http_status)"
          exit 1
      fi

      id_indexer=$(echo "$body" | jq -r --arg name "$radarr_indexer" '.[] | select(.name == $name) | .id')

      if [ -n "$id_indexer" ]; then
          green "[OK] Indexer found: $radarr_indexer"
          break
      else
          red "Indexer not found: $radarr_indexer"
      fi
  done
  green "[OK] Radarr configuration"
  break
done

while true; do
  # --------- Ask for Sonarr URL ---------

  while true; do
    read -p "Sonarr URL (http://{ip}:{port}) (blank for skip): " sonarr_url

    if [[ "$sonarr_url" = "" ]]; then
      break
    fi

    if [[ "$sonarr_url" =~ $url_regex ]]; then
      yellow "Checking connection to $sonarr_url..."
      if curl -Is --max-time 15 "$sonarr_url" | head -n 1 | grep -qE "HTTP/[0-9\.]+\s+[0-9]+"; then
        green "[OK] $sonarr_url is reachable"
        break
      else
        red "[KO] $sonarr_url is not reachable"
        yellow "Check the URL or network access"
      fi
    else
      red "Invalid URL format"
    fi
  done

  if [[ "$sonarr_url" = "" ]]; then
      yellow "Skipping sonarr configuration..."
      break
  fi

  # --------- API Token ---------
  read -s -p "Sonarr API key: " sonarr_key
  echo

  # --------- Get indexer ID by name ---------
  while true; do
      read -p "EXACT Sonarr indexer name (optional): " sonarr_indexer

      if [ "$sonarr_indexer" = "" ]; then
          yellow "Skip indexer"
          break
      fi

      response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X GET "$sonarr_url/api/v3/indexer" -H "X-Api-Key: $sonarr_key")
      body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
      http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

      if [ "$http_status" -ne 200 ]; then
          red "API error ($http_status)"
          exit 1
      fi

      id_indexer=$(echo "$body" | jq -r --arg name "$sonarr_indexer" '.[] | select(.name == $name) | .id')

      if [ -n "$id_indexer" ]; then
          green "[OK] Indexer found: $sonarr_indexer"
          break
      else
          red "Indexer not found: $sonarr_indexer"
      fi
  done
  green "[OK] Sonarr configuration"
  break
done

# --------- Search for unsatisfactory limit ---------
while true; do
  read -p "Also look for unsatisfactory limit? (y/n): " confirm_unlimit_item
  case "$confirm_unlimit_item" in
    y)
      unsatisfactory=true
      break
      ;;
    n)
      unsatisfactory=false
      break
      ;;
    *)
      red "Invalid choice. Please enter y or n."
      continue
      ;;
  esac
done

# --------- Save configuration ---------
config_file="$working_dir/settings.ini"
{
  echo "radarr_url=\"$radarr_url\""
  echo "radarr_key=\"$radarr_key\""
  echo "radarr_indexer=\"$radarr_indexer\""
  echo "radarr_ini=\"$working_dir/radarr_list.ini\""
  echo "sonarr_url=\"$sonarr_url\""
  echo "sonarr_key=\"$sonarr_key\""
  echo "sonarr_indexer=\"$sonarr_indexer\""
  echo "sonarr_ini=\"$working_dir/sonarr_list.ini\""
  echo "unsatisfactory=$unsatisfactory"
} > "$config_file"

green "Configuration saved to $config_file"