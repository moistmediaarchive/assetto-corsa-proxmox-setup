#!/bin/bash
set -e # exit on error

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

echo "${GREEN}[+] Welcome to the Assetto Corsa server setup wizard.${RESET}"

# --- LXC Set Up ---

# --- Collect Inputs ---
read -p "Enter preferred LXC ID: " CTID
read -p "Enter preferred LXC IP address (e.g. 192.168.1.50/24): " IP
read -p "Enter Gateway: " GATEWAY

echo "${GREEN}[+] Setting up LXC...${RESET}"

# --- Fixed LXC Spec ---
HOSTNAME="assetto-corsa"
MEMORY=16384
CORES=4
DISK="local-lvm:64"
STORAGE="local"

echo "${BLUE}[>] Looking for latest Ubuntu template...${RESET}"

# --- Find the latest Ubuntu 22.04 template available online ---
LATEST_TEMPLATE=$(pveam available | grep "ubuntu-22.04-standard" | sort -V | tail -n 1 | awk '{print $2}')

# --- Build the full template path ---
TEMPLATE_NAME="$LATEST_TEMPLATE"
TEMPLATE="$STORAGE:vztmpl/$TEMPLATE_NAME"

# --- Download if missing ---
if ! pveam list $STORAGE | grep -q "ubuntu-22.04-standard"; then
    echo "${BLUE}[>] Downloading latest template: $TEMPLATE_NAME ${RESET}"
    pveam download $STORAGE $TEMPLATE_NAME
fi

echo "${BLUE}[>] Creating LXC...${RESET}"

# --- Create LXC ---
pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --memory $MEMORY \
  --cores $CORES \
  --rootfs $DISK \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY

echo "${GREEN}[+] LXC Created.${RESET}"

echo "${BLUE}[>] Starting LXC...${RESET}"

# --- Start LXC ---
pct start $CTID
sleep 10

echo "${GREEN}[+] LXC Started.${RESET}"

echo "${BLUE}[>] Updating and getting LXC ready...${RESET}"

pct exec $CTID -- bash -c "apt-get update && apt-get -y upgrade"
pct exec $CTID -- bash -c "apt-get install -y unzip python3-venv python3-pip git"


echo "${GREEN}[+] LXC Updated.${RESET}"

# --- Configure LXC User ---
read -p "Enter desired username: " USERNAME
read -s -p "Enter user password (hidden): " USERPASS
echo

echo "${BLUE}[>] Creating user...${RESET}"

pct exec $CTID -- bash -c "useradd -m -s /bin/bash $USERNAME"

pct exec $CTID -- bash -c "echo '$USERNAME:$USERPASS' | chpasswd"

pct exec $CTID -- bash -c "command -v visudo >/dev/null && echo '$USERNAME ALL=(ALL:ALL) ALL' | EDITOR='tee -a' visudo || echo '$USERNAME ALL=(ALL:ALL) ALL' >> /etc/sudoers"

# Create folders
pct exec $CTID -- bash -c "mkdir -p /home/$USERNAME/assetto-servers /home/$USERNAME/discord-bot && chown -R $USERNAME:$USERNAME /home/$USERNAME"

echo "${GREEN}[+] User $USERNAME created with sudo access (password required).${RESET}"

read -p "Enter GitHub repo zip URL for Discord bot: " BOT_REPO

read -s -p "Enter Discord bot token (hidden): " BOT_TOKEN
echo

read -p "Enter Discord Guild/Server ID: " GUILD_ID

echo "${BLUE}[>] Downloading bot files..."

# Download bot repo
if [[ $BOT_REPO == *.git ]]; then
    pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME git clone $BOT_REPO repo && mv repo/* . && rm -rf repo"
else
    pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME wget -O bot.zip $BOT_REPO && sudo -u $USERNAME unzip bot.zip && rm bot.zip"
fi

echo "${GREEN}[+] Bot files downloaded.${RESET}"

echo "${BLUE}[>] Setting up Discord bot...${RESET}"

# Setup Python venv
pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME python3 -m venv venv && sudo -u $USERNAME ./venv/bin/pip install -r requirements.txt"

# Create .env file with bot token and config
pct exec $CTID -- bash -c "cat > /home/$USERNAME/discord-bot/.env <<EOF
DISCORD_TOKEN=$BOT_TOKEN
SERVER_BASE=/home/$USERNAME/assetto-servers
CONTROLLER_SCRIPT=/home/$USERNAME/discord-bot/server_controller.py
STATE_FILE=/home/$USERNAME/discord-bot/last_server.json
GUILD_ID=$GUILD_ID
EOF"

pct exec $CTID -- bash -c "chown $USERNAME:$USERNAME /home/$USERNAME/discord-bot/.env && chmod 600 /home/$USERNAME/discord-bot/.env"
