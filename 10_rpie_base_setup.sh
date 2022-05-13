#!/bin/bash
set -e

# RetroPie-fy Ubuntu Server install. Part III: Install and patch RetroPie.

# NOTE: This script makes certain assumptions about the environment and will
#       not produce a working setup unless ./00_rpie_ubuntu_os_setup.sh has
#       been succesfully executed before running this script.

## to rerun: (or './10_rpie_base_setup.sh make_clean')
# rm -rf <userhome>/RetroPie
# rm -rf <userhome>/RetroPie-Setup
# rm -rf /opt/retropie/
# rm -rf /etc/emulationstation/
# rm -rf /tmp/retroarch-head

##
## Variables to control setup

# comment out to disable KMS/DRM support
__has_kms=1
export __has_kms

##############################################################################

##
## computed; don't modify
USER="$SUDO_USER"
USER_HOME="/home/$USER"
LOG_FILE="${USER_HOME}/install-logs/$(basename "$0" .sh)-$(date +"%Y%m%d_%H%M%S").log"
RPIE_LOG="${USER_HOME}/install-logs/retropie-basic-install-$(date +"%Y%m%d_%H%M%S").log"
APT_LOG="${USER_HOME}/install-logs/core-compile-$(date +"%Y%m%d_%H%M%S").log"

__extra_cores=(
    lr-dolphin            # game cube
    lr-bluemsx            # MSX
    lr-vice               # C64/VIC-20
    lr-puae               # Amiga
    lr-hatari             # Atari ST
    lr-dosbox             # 640kb should be enough for anyone
    lr-mupen64plus-next   # N64
    lr-flycast            # Dreamcast
    lr-gw                 # Game & Watch
    lr-opera              # 3DO
    lr-virtualjaguar      # Atari Jaguar    
    lr-ppsspp             # PSP
    lr-picodrive          # Sega32x
    lr-genesis-plus-gx    # SegaCD
    lr-mesen              # NES (high accuracy, HdPacks support via BIOS/HdPacks/<romname>)
    lr-mame2010
    lr-mame2015
    lr-mame2016
    lr-scummvm
    #scummvm
    #uqm
)
## DEBUG: uncomment to quicken....
__extra_cores=(
    lr-gw
)

##
## Log all console output to logfile ; make sure log dir if writeable as ${USER} as well
mkdir -p "${USER_HOME}/install-logs"
chown "${USER}:${USER}" "${USER_HOME}/install-logs"
sudo -H -u "${USER}" touch "${LOG_FILE}"
exec > >(tee "${LOG_FILE}") 2>&1

## https://patorjk.com/software/taag/#p=display&f=Doom&t=RetroPie%20Ubuntu
cat << EOF
______     _            ______ _        _   _ _                 _         
| ___ \\   | |           | ___ (_)      | | | | |               | |  
| |_/ /___| |_ _ __ ___ | |_/ /_  ___  | | | | |__  _   _ _ __ | |_ _   _ 
|    // _ \\ __| '__/ _ \\|  __/| |/ _ \\ | | | | '_ \\| | | | '_ \\| __| | | |
| |\\ \\  __/ |_| | | (_) | |   | |  __/ | |_| | |_) | |_| | | | | |_| |_| |
\\_| \\_\\___|\\__|_|  \\___/\\_|   |_|\\___|fy\\___/|_.__/ \\__,_|_| |_|\\__|\\__,_|

RetroPie-fy Ubuntu Server install. Part III: Install and patch RetroPie.
URL: https://github.com/etheling/retropiefy-ubuntu

This script is derivative of Ubuntu Retropie install script by MisterB
(https://github.com/MizterB/RetroPie-Setup-Ubuntu), and of ideas and expirements
discussed in RetroPie forums (https://retropie.org.uk/forum/post/156839).

This script performs following actions:
- Clone and install RetroPie from official GitHub repo
- Install additional RetroArch cores
- Install SLang and GLSL shaders from official RetroArch repo
- Patch RetroPie version of retroarch to support KMS/DRM on x64
- Patch runcommand.sh to support Wayland/imv for launching images
- Install 3rd party EmulationStation themes
- Install commandline scrapers (scraper, skyscraper)
- Compile / install RetroArch head for testing/experimentation
- Install logs are stored in:
  * Install log: ${LOG_FILE}
  * RetroPie & RetroArch compile log: ${RPIE_LOG}
  * LR-core compile log: ${APT_LOG}

EOF

### FIXME: ADD CHECK TO TEST THAT ./00_rpie_ubuntu_os_setup.sh has been executed

## trap script exit, and if exiting with non-zero exit code make sure user is
## notified about the abnormal exit (set -e & log redirection may otherwise cause
## script to exit without obviously failing)
## https://stackoverflow.com/questions/65420781/how-to-trap-on-exit-1-only-in-bash
function trapexit() {
    if [ ! $? -eq 0 ]; then
	{
	    echo ""
	    echo "##############################################################################"
	    echo "ERROR: abnormal script termination. Install Failed. Please check the logs:"
	    echo " * Install log: ${LOG_FILE}"
	    echo " * RetroPie & RetroArch compile log: ${RPIE_LOG}"
	    echo " * LR-core compile log: ${APT_LOG}"
	    echo ""
	} >&2
    fi
}
trap trapexit EXIT

## Show function pre/post ambles in a 'standard way'
function f_preamble() {
    echo "+-------------------------------------------------------------------------------"
    echo "| Function $1()"
    echo "+-------------------------------------------------------------------------------"        
}
function f_postamble() {
    echo "*------------------------------------------------------------------------------*"
    echo ""        
}

    
# Backup system config file(s) before modifications
function backup_file() {
    echo -n "${FUNCNAME[0]}(): "
    if [ ! -f "$1" ] ; then
	echo "$1 does not exist. Not creating $1.orig"
	return
    fi
    if [ ! -f "$1.orig" ]; then	
	cp -v "$1" "$1.orig"
    else
	echo "$1.orig already exists (and cowardly refusing to overwrite)"
    fi
}  

# Install RetroPie
function install_retropie() {
    f_preamble "${FUNCNAME[0]}"
    echo "Install RetroPie from https://github.com/RetroPie/RetroPie-Setup.git"

    # Get Retropie Setup script and perform an install of same packages 
    # See https://github.com/RetroPie/RetroPie-Setup/blob/master/scriptmodules/admin/image.sh
    cd "$USER_HOME"

    git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git

    # patch retropie to support KMS/DRM on x64
    if [ -n "$__has_kms" ]; then
	# https://retropie.org.uk/forum/topic/28159/update-retroarch-sh-to-enable-kms-drm-on-x11-platform/4
	echo "-> __has_kms= set. Enabling KMS/DRM support in RetroPie components."
	echo "-> patch RetroPie-Setup/scriptmodules/system.sh to enable both x11 and kms on x86"
	SYSTEMSH="$USER_HOME/RetroPie-Setup/scriptmodules/system.sh"
	cat << EOF >> "$SYSTEMSH.patch"
518c518,519
<         __platform_flags+=(kms)
---
>  	## modify non-default path to contain x11 (and kms)
>         __platform_flags+=(x11 kms)
EOF
	cp -v "$SYSTEMSH" "$SYSTEMSH.orig"
	patch "$SYSTEMSH" "$SYSTEMSH.patch"
    fi
    

    echo "Running $USER_HOME/RetroPie-Setup/retropie_packages.sh setup basic_install"
    echo "NOTE: this will take a loooong time (tail -f $RPIE_LOG)"

    ## git fails here and in other places... gets ome dbg info
    GIT_CURL_VERBOSE=1
    export GIT_CURL_VERBOSE

    "$USER_HOME"/RetroPie-Setup/retropie_packages.sh setup basic_install >> "${RPIE_LOG}" 2>&1

    chown -R "$USER":"$USER" "$USER_HOME"/RetroPie-Setup

    unset GIT_CURL_VERBOSE
    
    echo "Installed RetroArch version and capabilities:"
    /opt/retropie/emulators/retroarch/bin/retroarch --version
    /opt/retropie/emulators/retroarch/bin/retroarch --features    
    
    f_postamble "${FUNCNAME[0]}"
}

function wayland_patch_runcommand() {
    f_preamble "${FUNCNAME[0]}"
    echo "Enable runcommand to show launching images under Wayland."
    echo "INFO: https://retropie.org.uk/forum/post/257368"
    
    local __runcommand
    __runcommand="/opt/retropie/supplementary/runcommand/runcommand.sh"


    backup_file "${__runcommand}"
    
    cat << EOF > "${__runcommand}.patch"
1221,1222c1221,1231
<         # if we are running under X use feh otherwise try and use fbi
<         if [[ -n "\$DISPLAY" ]]; then
---
> 	if [[ "\$XDG_SESSION_TYPE" == "wayland" ]]; then
> 	    # if under Wayland use imv 
> 	    # alas, there appears to be no 'right' way to detect if we're on Wayland:
> 	    # https://stackoverflow.com/questions/45536141/how-i-can-find-out-if-a-linux-system-uses-wayland-or-x11
> 	    # https://unix.stackexchange.com/questions/202891/how-to-know-whether-wayland-or-x11-is-being-used	    
> 	    imv-wayland -f -s full -x "\$image" & &>/dev/null
> 	    IMG_PID=\$!
> 	    sleep "\$IMAGE_DELAY"
> 	    imv-msg "\$IMG_PID" "q"
>         elif [[ -n "\$DISPLAY" ]]; then
> 	    # if we are running under X use feh otherwise try and use fbi
EOF

    echo "Patching $__runcommand"
    patch  "${__runcommand}" "${__runcommand}.patch"

    #chown "${USER}":"${USER}" $__runcommand
    #rwxr-xr-x
    chmod 755 "${__runcommand}"

    f_postamble "${FUNCNAME[0]}"
}

# Install RetroArch shaders from official repository
function install_retroarch_shaders() {
    f_preamble "${FUNCNAME[0]}"
    
    echo "Remove the RPi shaders installed by RetroPie-Setup and replace with"
    echo "RetroArch (merge of common & GLSL, and new Slang) shaders from Libretro"
    
    # Cleanup pi shaders installed by RetroPie-Setup
    rm -rf /opt/retropie/configs/all/retroarch/shaders
    mkdir -p /opt/retropie/configs/all/retroarch/shaders
    # Install common shaders from Libretro repository
    git clone --depth=1 https://github.com/libretro/common-shaders.git /tmp/common-shaders
    cp -r /tmp/common-shaders/* /opt/retropie/configs/all/retroarch/shaders/
    rm -rf /tmp/common-shaders
    # Install GLSL shaders from Libretro repository
    git clone --depth=1 https://github.com/libretro/glsl-shaders.git /tmp/glsl-shaders
    cp -r /tmp/glsl-shaders/* /opt/retropie/configs/all/retroarch/shaders/
    rm -rf /tmp/glsl-shaders

    # Install Slang shaders from Libretro repository (for use with Vulkan, glcore, ..)                              
    # https://www.libretro.com/index.php/category/slang/                                                            
    git clone --depth=1 https://github.com/libretro/slang-shaders.git /tmp/slang-shaders
    cp -r /tmp/slang-shaders/* /opt/retropie/configs/all/retroarch/shaders/
    rm -rf /tmp/slang-shaders

    # Remove git repository from shader dir
    rm -rf /opt/retropie/configs/all/retroarch/shaders/.git
    
    chown -R "$USER":"$USER" /opt/retropie/configs

    f_postamble "${FUNCNAME[0]}"
}

# add libretro cores
function install_more_cores() {
    f_preamble "${FUNCNAME[0]}"
    echo "Install additional libretro cores and ports."
    echo "NOTE: this also will take a looooong time and not all the cores sometimes compile properly."
    echo "INFO: tail -f ${APT_LOG}"
    
    set +e
    for i in "${__extra_cores[@]}"; do
	echo "-> Installing $i..." 
	"$USER_HOME"/RetroPie-Setup/retropie_packages.sh "$i" >> "${APT_LOG}" 2>&1
    done
    set -e
    
    echo "-> All done. Now checking if there were (obvious) errors during compilation:"
    grep "Error running" < "${APT_LOG}" || true
    grep "Could not successfully" < "${APT_LOG}" || true
    
    f_postamble "${FUNCNAME[0]}"
}

## modify configs to start EmulationStation (ES) automtically
function mod_sway_i3_confs() {
    f_preamble "${FUNCNAME[0]}"
    echo "Modify $USER_HOME/.config/{i3|sway}/config(s) to start EmulationStation (ES) automtically"
    backup_file "$USER_HOME/.config/sway/config"
    backup_file "$USER_HOME/.config/i3/config"
    backup_file "$USER_HOME/.profile"

    echo "Process $USER_HOME/.config/sway/config"
    grep -v "exec --no-startup-id foot" "$USER_HOME/.config/sway/config" > /tmp/sway.config
    cat << EOF >> /tmp/sway.config

## launch emulationstation fullscreen
#exec --no-startup-id foot 
exec --no-startup-id foot --fullscreen -- emulationstation --no-splash > /dev/shm/emulationstation.log 2>&1

EOF
    cp -v /tmp/sway.config "$USER_HOME/.config/sway/config"
    chown -v "${USER}":"${USER}" "$USER_HOME/.config/sway/config"
    chmod -v 644 "$USER_HOME/.config/sway/config"

    echo "Process $USER_HOME/.config/i3/config"
    grep -v "exec --no-startup-id gnome-terminal" "$USER_HOME/.config/i3/config" > /tmp/i3.config
    cat << EOF >> /tmp/i3.config

## launch emulationstation fullscreen
#exec --no-startup-id gnome-terminal
exec --no-startup-id gnome-terminal -- emulationstation --no-splash > /dev/shm/emulationstation.log 2>&1

EOF
    cp -v /tmp/i3.config "$USER_HOME/.config/i3/config"
    chown -v "${USER}":"${USER}" "$USER_HOME/.config/i3/config"
    chmod -v 644 "$USER_HOME/.config/i3/config"

    ## ~/.profile
    echo "Enable ES for KMS/DRM via ~/.profile"
    sed -i 's/.*anchor-emula.*/    emulationstation --no-splash \> \/dev\/shm\/emulationstation.log 2\>\&1/' "$USER_HOME/.profile"

    
    f_postamble "${FUNCNAME[0]}"
}

function install_retroarch_head() {
    f_preamble "${FUNCNAME[0]}"
    echo "Install latest retroarch alongside RetroPie version to /opt/retropie/emulators/retroarch/bin"
    echo "NOTE: does not have some retropie patches, so useful mostly for testing only!"

    CURDIR="$(pwd)"
    git clone https://github.com/libretro/RetroArch /tmp/retroarch-head
    cd /tmp/retroarch-head

    ## configure with mostly similar options to RetroPie version (see .../RetroPie-Setup/scriptmodules/emulators/retroarch.sh)
    echo "Now compiling... (tail -f ${APT_LOG})"
    ./configure --disable-sdl --enable-sdl2 --disable-oss --disable-al --disable-jack --disable-qt --enable-opengles --enable-opengles3 --enable-kms --enable-egl --enable-vulkan --enable-wayland --prefix=/tmp/retroarch-head/build-out >> "${APT_LOG}" 2>&1
    make -j"$(nproc)" >> "${APT_LOG}" 2>&1
    make install >> "${APT_LOG}" 2>&1
    cp -v /tmp/retroarch-head/build-out/bin/retroarch /opt/retropie/emulators/retroarch/bin/retroarch.head
    cp -v /tmp/retroarch-head/build-out/bin/retroarch-cg2glsl /opt/retropie/emulators/retroarch/bin/retroarch-cg2glsl.head

    echo "Installed /opt/retropie/emulators/retroarch/bin/retroarch.head version and capabilities:"
    /opt/retropie/emulators/retroarch/bin/retroarch.head --version
    /opt/retropie/emulators/retroarch/bin/retroarch.head --features    
    
    cd "$CURDIR"

    f_postamble "${FUNCNAME[0]}"
}

function install_scrapers() {
    f_preamble "${FUNCNAME[0]}"
    echo "Install sky+scraper for scraping ROM metadata (/opt/retropie/supplementary...)"
    echo "INFO: tail -f ${RPIE_LOG}"

    echo "Installing skyscraper: /opt/retropie/supplementary/skyscraper/Skyscraper"
    "$USER_HOME"/RetroPie-Setup/retropie_packages.sh skyscraper >> "${RPIE_LOG}" 2>&1
    echo "Installing scraper: /opt/retropie/supplementary/scraper/scraper"    
    "$USER_HOME"/RetroPie-Setup/retropie_packages.sh scraper >> "${RPIE_LOG}" 2>&1

    echo "INFO: Installed scraper versions: (note: scraper version may be empty string)"
    echo -n "Scraper: "
    set +e
    ## yes...it's not working...
    /opt/retropie/supplementary/scraper/scraper -version
    set -e
    echo -n "SkyScraper: "
    /opt/retropie/supplementary/skyscraper/Skyscraper --version
    f_postamble "${FUNCNAME[0]}"
}


function install_3rdparty_themes () {
    f_preamble "${FUNCNAME[0]}"

    __tmpthemes="/tmp/themes"
    __themespath="/etc/emulationstation/themes"
    echo "Install 3rd party EmulationStation themes to $__themespath"
    
    mkdir -vp "${__themespath}"
    git clone https://github.com/chicueloarcade/es-theme-Chicuelo "${__themespath}/chicuelo" ; # https://retropie.org.uk/forum/topic/15830/chicuelo-theme
    git clone https://github.com/TMNTturtleguy/es-theme-ComicBook "${__themespath}/comicbook"
    git clone https://github.com/RetroHursty69/es-theme-comiccrazy "${__themespath}/comiccrazy"
    git clone https://github.com/c64-dev/es-theme-epicnoir "${__themespath}/epicnoir" ; # NUC & Arcade default theme
    git clone https://github.com/rxbrad/es-theme-gbz35 "${__themespath}/gbz35"
    git clone https://github.com/RetroHursty69/es-theme-graffiti "${__themespath}/graffiti"
    git clone https://github.com/RetroHursty69/es-theme-magazinemadness "${__themespath}/magazinemadness"
    git clone https://github.com/dmmarti/es-theme-maximuspie "${__themespath}/maximuspie"
    git clone https://github.com/KALEL1981/es-theme-nes-box "${__themespath}/nesbox"
    git clone https://github.com/lipebello/es-theme-retrorama "${__themespath}/retrorama" ; # older version of retrorama
    git clone https://github.com/lipebello/es-theme-retrorama-turbo "${__themespath}/retrorama-turbo" ; # https://retropie.org.uk/forum/topic/10601/retrorama-comic-theme/466
    git clone https://github.com/RetroHursty69/es-theme-soda "${__themespath}/soda" ; # soda can based theme
    git clone https://github.com/lipebello/es-theme-strangerstuff "${__themespath}/strangestuff"
    git clone https://github.com/CoinJunkie/es-theme-synthwave "${__themespath}/synthwave"
    git clone https://github.com/anthonycaccese/es-theme-tft "${__themespath}/tft" ; # flat theme (320x240 resolution targeted)
    git clone https://github.com/raelgc/es-theme-tronkyfran-super "${__themespath}/tronkyfran-super"
    git clone https://github.com/HerbFargus/es-theme-tronkyfran.git --branch dark --single-branch "${__themespath}/tronkyfran-dark"
    git clone https://github.com/robertybob/es-theme-tv "${__themespath}/tv"
    git clone https://github.com/ehettervik/es-theme-workbench "${__themespath}/workbench" ; # Amiga Workbench theme
    git clone https://github.com/Zechariel/VectorPie "${__themespath}/vectorpie" ; # for Atari 2600 build
    git clone https://github.com/Arcanthur/OmegaDrive "${__themespath}/omegadrive" ; # for Plus/4 build

    f_postamble "${FUNCNAME[0]}"
}



function repair_permissions() {
    f_preamble "${FUNCNAME[0]}"
    echo "Fix file/folder permissions under ${USER_HOME} (making ${USER} owner of files/dirs)"
    chown -R "${USER}:${USER}" "${USER_HOME}/"
    f_postamble "${FUNCNAME[0]}"
}

# Final message to user
function complete_install() {
    RUNTIME=$SECONDS
    echo "+-------------------------------------------------------------------------------"
    echo "| Installation complete" 
    echo "| Runtime: $((RUNTIME / 60)) minutes and $((RUNTIME % 60)) seconds"
    echo "| Output has been logged to"
    echo "| * Install log: ${LOG_FILE}"
    echo "| * RetroPie & RetroArch compile log: ${RPIE_LOG}"
    echo "| * LR-core compile log: ${APT_LOG}"
    echo "+-------------------------------------------------------------------------------"
}

# remove previous install.... to rerun
function make_clean() {
    f_preamble "${FUNCNAME[0]}"
    echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
    echo ""
    echo "Remove existing installation of RetroPie for re-running this script"
    echo ""
    echo "Will remove following directories in 30 seconds:"
    echo "  $USER_HOME/RetroPie"
    echo "  $USER_HOME/RetroPie-Setup"
    echo "  /opt/retropie/"
    echo "  /etc/emulationstation/"
    echo "  /tmp/retroarch-head"
    echo ""
    echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
    echo ""
    echo "CTRL+C now to abort"
    sleep 30

    echo "Erasing...."
    rm -rf "$USER_HOME/RetroPie"
    rm -rf "$USER_HOME/RetroPie-Setup"
    rm -rf /opt/retropie/
    rm -rf /etc/emulationstation/
    rm -rf /tmp/retroarch-head

    echo "Rolling back config files..."
    if [ -f "$USER_HOME/.config/sway/config.orig" ]; then
	cp -v "$USER_HOME/.config/sway/config.orig" "$USER_HOME/.config/sway/config"
    fi
    if [ -f "$USER_HOME/.config/i3/config.orig" ]; then
	cp -v "$USER_HOME/.config/i3/config.orig" "$USER_HOME/.config/i3/config"
    fi
    
    echo "Complete. Existing RetroPie installation removed"
    
    f_postamble "${FUNCNAME[0]}"
}

function are_we_root() {
    # Make sure the user is running the script via sudo
    if [ -z "$SUDO_USER" ]; then
	echo "This script requires sudo privileges. Please run with: sudo $0"
	exit 1
    fi
    # Don't allow the user to run this script from the root account. RetroPie doesn't like this.
    if [[ "$SUDO_USER" == root ]]; then
	echo "This script cannot be run by the root user.  Please run as normal user using sudo."
	exit 1
    fi
}

### 1,2,3,...
are_we_root


if [[ -z "$1" ]]; then
    install_retropie
    wayland_patch_runcommand
    install_retroarch_shaders
    install_more_cores
    install_retroarch_head
    install_scrapers
    install_3rdparty_themes
    
    mod_sway_i3_confs
else
    for call_function in "$@"; do
        $call_function
    done
fi

repair_permissions    
complete_install

