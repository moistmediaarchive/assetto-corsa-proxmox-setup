#!/bin/bash
set -e # exit on error

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

clear
echo -e "${YELLOW}"
echo -e "    __  _______  _______________    ___   ______"
echo -e "   /  |/  / __ \/  _/ ___/_  __/   /   | / ____/"
echo -e "  / /|_/ / / / // / \__ \ / /_____/ /| |/ /     "
echo -e " / /  / / /_/ // / ___/ // /_____/ ___ / /___   "
echo -e "/_/  /_/\____/___//____//_/     /_/  |_\____/   ${RESET}"
echo
echo
echo -e "${GREEN}[+] Welcome to the Assetto Corsa server setup wizard.${RESET}"

# --- LXC Set Up ---

# --- Collect Inputs ---
read -p "Enter preferred LXC ID: " CTID
read -p "Enter preferred LXC IP address (e.g. 192.168.1.50/24): " IP
read -p "Enter Gateway: " GATEWAY

echo -e "${GREEN}[+] Setting up LXC...${RESET}"

# --- Fixed LXC Spec ---
HOSTNAME="assetto-corsa"
MEMORY=16384
CORES=4
DISK="local-lvm:64"
STORAGE="local"

echo -e "${BLUE}[>] Looking for latest Ubuntu template ...${RESET}"

# --- Find the latest Ubuntu 22.04 template available online ---
LATEST_TEMPLATE=$(pveam available | grep "ubuntu-22.04-standard" | sort -V | tail -n 1 | awk '{print $2}')

# --- Build the full template path ---
TEMPLATE_NAME="$LATEST_TEMPLATE"
TEMPLATE="$STORAGE:vztmpl/$TEMPLATE_NAME"

# --- Download if missing ---
if ! pveam list $STORAGE | grep -q "ubuntu-22.04-standard"; then
    echo -e "${BLUE}[>] Downloading latest template: $TEMPLATE_NAME ${RESET}"
    pveam download $STORAGE $TEMPLATE_NAME
fi

echo -e "${BLUE}[>] Creating LXC ...${RESET}"
pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --memory $MEMORY \
  --cores $CORES \
  --rootfs $DISK \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY \
  >/dev/null 2>&1 &
spinner $!
echo -e "${GREEN}[+] LXC Created.${RESET}"

echo -e "${BLUE}[>] Starting LXC ...${RESET}"

# --- Start LXC ---
pct start $CTID
sleep 10

echo -e "${GREEN}[+] LXC Started.${RESET}"

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

echo -e "${BLUE}[>] Updating container - this may take some time ...${RESET}"
pct exec $CTID -- bash -c "apt-get -qq update && apt-get -qq -y upgrade" >/dev/null 2>&1 &
spinner $!
echo -e "${GREEN}[+] LXC Updated.${RESET}"

echo -e "${BLUE}[>] Installing dependencies ...${RESET}"
pct exec $CTID -- bash -c "apt-get -qq install -y unzip python3-venv python3-pip git" >/dev/null 2>&1 &
spinner $!
echo -e "${GREEN}[+] Dependencies installed.${RESET}"

# --- Configure LXC User ---
read -p "Enter desired username: " USERNAME
read -s -p "Enter user password (hidden): " USERPASS
echo

echo -e "${BLUE}[>] Creating user ...${RESET}"

pct exec $CTID -- bash -c "useradd -m -s /bin/bash $USERNAME"

pct exec $CTID -- bash -c "echo '$USERNAME:$USERPASS' | chpasswd"

pct exec $CTID -- bash -c "command -v visudo >/dev/null && echo '$USERNAME ALL=(ALL:ALL) ALL' | EDITOR='tee -a' visudo || echo '${RED}$USERNAME ALL=(ALL:ALL) ALL${RESET}' >> /etc/sudoers"

# Create folders
pct exec $CTID -- bash -c "mkdir -p /home/$USERNAME/assetto-servers /home/$USERNAME/discord-bot && chown -R $USERNAME:$USERNAME /home/$USERNAME"

echo -e "${GREEN}[+] User $USERNAME created with sudo access (password required).${RESET}"

read -p "Enter GitHub repo URL for Discord bot: " BOT_REPO

read -s -p "Enter Discord bot token (hidden): " BOT_TOKEN
echo

read -p "Enter Discord Guild/Server ID: " GUILD_ID

echo -e "${BLUE}[>] Downloading Discord bot files ..."

# Download bot repo
if [[ $BOT_REPO == *.git ]]; then
    pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME git clone $BOT_REPO repo && mv repo/* . && rm -rf repo"
else
    pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME wget -O bot.zip $BOT_REPO && sudo -u $USERNAME unzip bot.zip && rm bot.zip"
fi

echo -e "${GREEN}[+] Discord bot files downloaded.${RESET}"

# echo -e "${BLUE}[>] Setting up Discord bot ...${RESET}"

# # Setup Python venv
# pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && sudo -u $USERNAME python3 -m venv venv && sudo -u $USERNAME ./venv/bin/pip install -r requirements.txt"

echo -e "${BLUE}[>] Setting up Discord bot (installing requirements) ...${RESET}"

pct exec $CTID -- bash -c "cd /home/$USERNAME/discord-bot && \
    sudo -u $USERNAME python3 -m venv venv && \
    sudo -u $USERNAME ./venv/bin/pip install -q -r requirements.txt" >/dev/null 2>&1 &
spinner $!

echo -e "${GREEN}[+] Discord bot environment ready.${RESET}"

# Create .env file with bot token and config
pct exec $CTID -- bash -c "cat > /home/$USERNAME/discord-bot/.env <<EOF
DISCORD_TOKEN=$BOT_TOKEN
SERVER_BASE=/home/$USERNAME/assetto-servers
CONTROLLER_SCRIPT=/home/$USERNAME/discord-bot/server_controller.py
STATE_FILE=/home/$USERNAME/discord-bot/last_server.json
GUILD_ID=$GUILD_ID
EOF"

pct exec $CTID -- bash -c "chown $USERNAME:$USERNAME /home/$USERNAME/discord-bot/.env && chmod 600 /home/$USERNAME/discord-bot/.env"

echo -e "${BLUE}[>] Creating systemd service for Discord bot...${RESET}"

SERVICE_FILE="/etc/systemd/system/discord-bot.service"

pct exec $CTID -- bash -c "cat > $SERVICE_FILE <<EOF
[Unit]
Description=Discord Bot for Assetto Corsa
After=network.target

[Service]
Type=simple
User=$USERNAME
WorkingDirectory=/home/$USERNAME/discord-bot
ExecStart=/home/$USERNAME/discord-bot/venv/bin/python3 /home/$USERNAME/discord-bot/main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

# Reload systemd, enable and start the service
pct exec $CTID -- bash -c "systemctl daemon-reload && systemctl enable discord-bot && systemctl start discord-bot"

echo -e "${GREEN}[+] Discord bot service created and started.${RESET}"

echo -e "${GREEN}[+] Discord bot running and online.${RESET}"
echo

echo -e "${YELLOW}INFO:${RESET} If you have not already done so, add your Discord bot to your server."
echo

echo -e "${YELLOW}INFO:${RESET} Before continuing with Assetto Corsa server setup, make sure all of your packed server tar.gz archives from Content Manager are uploaded to a github repository. Each tar.gz archive should be in it's own folder with any extra fast_lane.aip files you have for ai traffic."
echo

read -p "Enter GitHub repo URL containing Assetto Corsa server folders: " AC_ARCHIVES

# Download Assetto Corsa track servers from CSP
if [[ $AC_ARCHIVES == *.git ]]; then
    pct exec $CTID -- bash -c "cd /home/$USERNAME/assetto-servers && sudo -u $USERNAME git clone $BOT_REPO repo && mv repo/* . && rm -rf repo"
else
    pct exec $CTID -- bash -c "cd /home/$USERNAME/assetto-servers && sudo -u $USERNAME wget -O bot.zip $BOT_REPO && sudo -u $USERNAME unzip bot.zip && rm bot.zip"
fi

echo -e "${BLUE}[>] Extracting Assetto Corsa track server packs ...${RESET}"

pct exec $CTID -- bash -c "
    for archive in /home/$USERNAME/assetto-servers/*/*.tar.gz; do
        [ -e \"\$archive\" ] || continue
        dir=\$(dirname \"\$archive\")
        sudo -u $USERNAME tar -xzf \"\$archive\" -C \"\$dir\"
        rm -f \"\$archive\"
    done
" >/dev/null 2>&1 &
spinner $!

echo -e "${GREEN}[+] Track servers extracted and cleaned up.${RESET}"

echo -e "${RED}WARNING:${RESET} The next part of this install includes a nested repo for AssettoServer. This has been community tested, but if you feel the need, now would be a good time to go review the nested repo for anything malicious."
echo 

echo "https://github.com/compujuckel/AssettoServer/releases/tag/v0.0.54"
echo 

MAX_ATTEMPTS=3
attempt=1
while [ $attempt -le $MAX_ATTEMPTS ]; do
    read -p "Would you like to continue with the install? (Y/N): " CONT_VAR
    case "$CONT_VAR" in
        [Yy]* )
            echo -e "${GREEN}[+] Continuing installation...${RESET}"
            # <--- place your AssettoServer install steps here
            break
            ;;
        [Nn]* )
            echo -e "${RED}[-] Installation aborted by user.${RESET}"
            exit 1
            ;;
        * )
            echo -e "${YELLOW}[!] Invalid input. Please enter Y or N. ($attempt/$MAX_ATTEMPTS)${RESET}"
            attempt=$((attempt+1))
            ;;
    esac
done

if [ $attempt -gt $MAX_ATTEMPTS ]; then
    echo -e "${RED}[-] Too many invalid attempts. Aborting installation.${RESET}"
    exit 1
fi

# Confirmed continue
echo -e "${BLUE}[>] Downloading AssettoServer release...${RESET}"

ASSETTOSERVER_URL="https://github.com/compujuckel/AssettoServer/releases/download/v0.0.54/AssettoServer.linux-x64.tar.gz"
ASSETTOSERVER_FILE="AssettoServer.linux-x64.tar.gz"

# safer download (show error if fails)
if ! pct exec $CTID -- bash -c "cd /home/$USERNAME/assetto-servers && sudo -u $USERNAME wget -q $ASSETTOSERVER_URL -O $ASSETTOSERVER_FILE"; then
    echo -e "${RED}[-] Failed to download AssettoServer. Check your internet or the release URL.${RESET}"
    exit 1
fi

echo -e "${GREEN}[+] AssettoServer release downloaded.${RESET}"


echo -e "${BLUE}[>] Copying and extracting AssettoServer into each track folder...${RESET}"

pct exec $CTID -- bash -c "
    for track_dir in /home/$USERNAME/assetto-servers/*/; do
        [ -d \"\$track_dir\" ] || continue
        cp /home/$USERNAME/assetto-servers/$ASSETTOSERVER_FILE \"\$track_dir\"
        cd \"\$track_dir\"
        sudo -u $USERNAME tar -xzf $ASSETTOSERVER_FILE
        rm -f $ASSETTOSERVER_FILE
        # make sure the binary is executable
        if [ -f \"\$track_dir/AssettoServer\" ]; then
            chmod +x \"\$track_dir/AssettoServer\"
        fi
    done
"

# Cleanup the original downloaded tar.gz
pct exec $CTID -- rm -f "/home/$USERNAME/assetto-servers/$ASSETTOSERVER_FILE"

echo -e "${GREEN}[+] AssettoServer deployed and permissions set in each track folder.${RESET}"

echo -e "${BLUE}[>] Running initial setup for each track server...${RESET}"

pct exec $CTID -- bash -c "
    for track_dir in /home/$USERNAME/assetto-servers/*/; do
        [ -d \"\$track_dir\" ] || continue
        if [ -f \"\$track_dir/AssettoServer\" ]; then
            echo '[*] Starting initial setup for: ' \$(basename \"\$track_dir\")
            cd \"\$track_dir\"
            sudo -u $USERNAME ./AssettoServer > /dev/null 2>&1 &
            SERVER_PID=\$!
            sleep 10
            kill \$SERVER_PID >/dev/null 2>&1 || true
            echo '[+] Initial setup complete for: ' \$(basename \"\$track_dir\")
        fi
    done
"

echo -e "${GREEN}[+] All track servers have completed their initial setup.${RESET}"

# Individual Track Server Configuration

echo -e "${BLUE}[>] Starting individual track configuration ...${RESET}"

pct exec $CTID -- bash -c '
for track_dir in /home/'$USERNAME'/assetto-servers/*/; do
    [ -d "$track_dir" ] || continue
    track_name=$(basename "$track_dir")
    cfg_dir="$track_dir/cfg"
    extra_cfg="$cfg_dir/extra_cfg.yml"
    server_cfg="$cfg_dir/server_cfg.ini"

    echo "-----------------------------------------"
    echo "[Track] $track_name"
    echo "-----------------------------------------"

    # --- Enable CSP WeatherFX ---
    while true; do
        read -p "Enable CSP WeatherFX for $track_name? (y/n): " ans
        case "$ans" in
            [Yy]* )
                if [ -f "$extra_cfg" ]; then
                    sed -i "s/EnableWeatherFx: false/EnableWeatherFx: true/" "$extra_cfg"
                    echo "[+] CSP WeatherFX enabled for $track_name"
                fi
                break ;;
            [Nn]* ) break ;;
            * ) echo "[!] Please answer y or n." ;;
        esac
    done

    # --- Enable AI Traffic ---
    while true; do
        read -p "Enable AI Traffic for $track_name? (y/n): " ans
        case "$ans" in
            [Yy]* )
                if [ -f "$extra_cfg" ]; then
                    sed -i "s/EnableAi: false/EnableAi: true/" "$extra_cfg"
                    echo "[+] AI Traffic enabled for $track_name"
                fi
                break ;;
            [Nn]* ) break ;;
            * ) echo "[!] Please answer y or n." ;;
        esac
    done

    # --- Append INFINITE=1 ---
    if [ -f "$server_cfg" ]; then
        echo "INFINITE=1" >> "$server_cfg"
        echo "[+] Added INFINITE=1 to server_cfg.ini"
    fi

    # --- Move fast_lane.aip if present ---
    if [ -f "$track_dir/fast_lane.aip" ]; then
        dest="/home/'$USERNAME'/assetto-servers/$track_name/content/tracks/$track_name/ai"
        mkdir -p "$dest"
        mv "$track_dir/fast_lane.aip" "$dest/"
        echo "[+] Moved fast_lane.aip into $dest"
    fi
done
'

echo -e "${RED}COMPLETE${RESET}"
