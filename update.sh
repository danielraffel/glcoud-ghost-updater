#!/bin/bash

# What's the purpose of this script? Google Cloud's free micro instances lack the power to update Ghost without taking it offline. This script automates creating a new VM, updating Ghost there, and switching the IP, all without affecting the live instance.

# This script assumes you
# 1. Are running this script on your local machine 
# 2. Have the following installed: jq, curl, expect, ssh-keygen, ssh-keyscan, gcloud CLI
# 3. Setup your Ghost instance on Google cloud machine with a "service_account" similar to this setup https://scottleechua.com/blog/self-hosting-ghost-on-google-cloud/
# 4. Setup ssh keys on your Google cloud machine so that "service_account" can ssh into your server
# 5. Are using a premium (eg-not standard) static external IP address on your currently running micro-instance

# This is for debugging if you get a new updated VM and want to check the status and update the IP address run: update.sh compare
compare_versions() {
  # Replace with actual IP_ADDRESS
  IP_ADDRESS="ENTER_YOUR_IP_ADDRESS"
  LATEST_VERSION=$(curl --silent "https://api.github.com/repos/TryGhost/Ghost/releases/latest" | jq -r .tag_name)
  GHOST_VM_VERSION=$(ssh -i ~/.ssh/gcp service_account@$IP_ADDRESS "cd /var/www/ghost && ghost version | grep 'Ghost version:' | awk '{print \$3}'")
  GHOST_STATUS=$(ssh -i ~/.ssh/gcp service_account@${IP_ADDRESS} "cd /var/www/ghost && ghost status | grep -o 'running'")

  echo "Debug: Expected Ghost Version: '$LATEST_VERSION', Found Version: '$GHOST_VM_VERSION'"
  echo "Debug: Expected Ghost Status: 'running', Found Status: '$GHOST_STATUS'"

  # Check if Ghost is updated and running
  if [[ "$GHOST_VM_VERSION" == "${LATEST_VERSION:1}" && "$GHOST_STATUS" == "running" ]]; then
    echo "GOOD NEWS!! Ghost is running and is the latest version."

    read -p "Do you want to re-assign the IP address for: $NEW_VM_NAME? (y/n): " answer
    if [ "$answer" == "y" ]; then
      # Fetch the actual access-config names
      ACTUAL_ACCESS_CONFIG_NAME_OLD=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')
      ACTUAL_ACCESS_CONFIG_NAME_NEW=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')

      # Unassign the old IP from the OLD VM
      gcloud compute instances delete-access-config $VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_OLD" --zone=$ZONE

      # Remove any existing access config from the NEW VM
      gcloud compute instances delete-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --zone=$ZONE

      # Assign the old IP to the NEW VM
      gcloud compute instances add-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --address=$OLD_IP_ADDRESS --zone=$ZONE
    else
      echo "Not updating the IP."
    fi
  else
    echo "Not updating the IP address because the machine was not updated to the latest version of Ghost and/or isn't running."
  fi

  echo "Done."

}

case "$1" in
  "compare")
    compare_versions
    exit 0
    ;;
  *)

cat << "EOF"
 ██████  ██   ██  ██████  ███████ ████████ ██    ██ ██████  ██████   █████  ████████ ███████ ██████  
██       ██   ██ ██    ██ ██         ██    ██    ██ ██   ██ ██   ██ ██   ██    ██    ██      ██   ██ 
██   ███ ███████ ██    ██ ███████    ██    ██    ██ ██████  ██   ██ ███████    ██    █████   ██████  
██    ██ ██   ██ ██    ██      ██    ██    ██    ██ ██      ██   ██ ██   ██    ██    ██      ██   ██ 
 ██████  ██   ██  ██████  ███████    ██     ██████  ██      ██████  ██   ██    ██    ███████ ██   ██
EOF

# Prompt for Google Cloud info
read -p "Update Ghost on GCloud? Creates backup, starts a new VM, updates Ghost, re-assigns old IP if successful. (y/n): " answer

if [ "$answer" == "y" ]; then
  # Fetch project ID and VM information
  PROJECT_ID=$(gcloud config list --format 'value(core.project)')
  VM_INFO=$(gcloud compute instances list --filter="name ~ '.*-ghost-.*' AND status=RUNNING" --format='csv[no-heading](name,zone,networkInterfaces[0].accessConfigs[0].natIP)')

  # Count the number of VM instances
  VM_LINES=$(echo "$VM_INFO" | wc -l)

  # If multiple VM instances are found, prompt the user to select one
  if [ "$VM_LINES" -gt 1 ]; then
    echo "Multiple VMs detected. Select one:"
    select OPTION in $VM_INFO; do
      IFS=',' read -ra ADDR <<< "$OPTION"
      VM_NAME=${ADDR[0]}
      ZONE=${ADDR[1]}
      OLD_IP_ADDRESS=${ADDR[2]}
      break
    done
  else
    # If only one VM instance is found, use that one
    IFS=',' read -ra ADDR <<< "$VM_INFO"
    VM_NAME=${ADDR[0]}
    ZONE=${ADDR[1]}
    OLD_IP_ADDRESS=${ADDR[2]}

    # Display the table
    echo "Found 1 VM:"
	printf "Name\tZone\tIP Address\n"
	printf "%s\t%s\t%s\n" "$VM_NAME" "$ZONE" "$OLD_IP_ADDRESS"
  fi

  # Extracting the numeric string from the suffix of the selected VM_NAME
  NUMERIC_SUFFIX=$(echo "$VM_NAME" | awk -F'-' '{print $(NF-2)"-"$(NF-1)"-"$NF}')
  
  echo "Found VM: $VM_NAME"

  COUNTER=0
  IMAGE_NAME="backup-${VM_NAME}"

  while true; do
    if gcloud compute machine-images describe $IMAGE_NAME --project=$PROJECT_ID &>/dev/null; then
      let COUNTER=COUNTER+1
      IMAGE_NAME="backup-${VM_NAME}-v${COUNTER}"
    else
      break
    fi
  done


  echo "Creating machine image..."
  gcloud compute machine-images create $IMAGE_NAME \
    --project=$PROJECT_ID \
    --source-instance=$VM_NAME \
    --source-instance-zone=$ZONE

  echo "Fetching latest Ghost Blog version..."
  LATEST_VERSION=$(curl --silent "https://api.github.com/repos/TryGhost/Ghost/releases/latest" | jq -r .tag_name)
  LATEST_VERSION_FORMATTED="${LATEST_VERSION//./-}"

  NEW_VM_NAME="${VM_NAME%-${NUMERIC_SUFFIX}}-${LATEST_VERSION_FORMATTED}"

  echo "Creating new VM instance..."
  gcloud compute instances create $NEW_VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --source-machine-image=$IMAGE_NAME

  echo "Waiting for VM to become RUNNING..."
  while true; do
    VM_STATUS=$(gcloud compute instances describe $NEW_VM_NAME \
      --project=$PROJECT_ID \
      --zone=$ZONE \
      --format='get(status)')
    if [ "$VM_STATUS" == "RUNNING" ]; then
      break
    fi
    sleep 5
  done

  # Rest of the original script
  IP_ADDRESS=$(gcloud compute instances describe $NEW_VM_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

  echo "Removing any existing keys for the IP: $IP_ADDRESS"
  ssh-keygen -R $IP_ADDRESS 2>/dev/null

  echo "Checking SSH readiness every 5 seconds..."
  MAX_ATTEMPTS=12
  COUNT=0
  while true; do
    ssh -q -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ~/.ssh/gcp service_account@${IP_ADDRESS} exit
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
      echo "SSH is ready."
      break
    fi
    let COUNT=COUNT+1
    if [ $COUNT -ge $MAX_ATTEMPTS ]; then
      echo "SSH not ready after $MAX_ATTEMPTS attempts. Exiting."
      exit 1
    fi
    echo "SSH not ready. Retrying ($COUNT/$MAX_ATTEMPTS)..."
    sleep 5
  done


  sshUpdateGhost() {
    ssh -t -i ~/.ssh/gcp service_account@$1 << "ENDSSH"
      cd /var/www/ghost
      ghost stop
      sudo npm install -g ghost-cli@latest
      ghost update
      ghost start
ENDSSH
  }

  fetchGhostInfo() {
    local ip=$1
    local version=$(ssh -i ~/.ssh/gcp service_account@$ip "cd /var/www/ghost && ghost version | grep 'Ghost version:' | awk '{print \$3}'")
    local status=$(ssh -i ~/.ssh/gcp service_account@$ip "cd /var/www/ghost && ghost status | grep -o 'running'")
    echo "$version,$status"
  }

  echo "SSHing into the VM instance to run update commands..."
  sshUpdateGhost $IP_ADDRESS

  # For text coloring
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  NC='\033[0m' # No Color

  # Fetch Ghost VM version and status
  IFS=',' read -ra GHOST_INFO <<< "$(fetchGhostInfo $IP_ADDRESS)"
  GHOST_VM_VERSION=$(echo "${GHOST_INFO[0]}" | xargs)  # Trim whitespaces
  GHOST_STATUS=$(echo "${GHOST_INFO[1]}" | xargs)  # Trim whitespaces

  # Debug: Expected vs Found
  echo "Debug: Expected Ghost Version: '$LATEST_VERSION', Found Version: '$GHOST_VM_VERSION'"
  echo "Debug: Expected Ghost Status: 'running', Found Status: '$GHOST_STATUS'"

  # Check if Ghost is updated and running
  if [[ "$GHOST_VM_VERSION" == "${LATEST_VERSION:1}" && "$GHOST_STATUS" == "running" ]]; then
    echo "GOOD NEWS!! Ghost is running and is the latest version."

    read -p "Do you want to re-assign the IP address for: $NEW_VM_NAME? (y/n): " answer
    if [ "$answer" == "y" ]; then
      # Fetch the actual access-config names
      ACTUAL_ACCESS_CONFIG_NAME_OLD=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')
      ACTUAL_ACCESS_CONFIG_NAME_NEW=$(gcloud compute instances describe $NEW_VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].name)')

      # Unassign the old IP from the OLD VM
      gcloud compute instances delete-access-config $VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_OLD" --zone=$ZONE

      # Remove any existing access config from the NEW VM
      gcloud compute instances delete-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --zone=$ZONE

      # Assign the old IP to the NEW VM
      gcloud compute instances add-access-config $NEW_VM_NAME --access-config-name="$ACTUAL_ACCESS_CONFIG_NAME_NEW" --address=$OLD_IP_ADDRESS --zone=$ZONE
    else
      echo "Not updating the IP."
    fi
  else
    echo "Not updating the IP address because the machine was not updated to the latest version of Ghost and/or isn't running."
  fi

  echo "Done."

  else
    echo "Skipping updating Ghost on Google Cloud. Exiting."
    exit 1
  fi

esac