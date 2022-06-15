#!/bin/bash
set -e

# RetroPie-fy Ubuntu Server install. Part II: Optional OS optimizations

# NOTE: This script makes certain assumptions about the environment and will
#       not produce a working setup unless ./00_rpie_ubuntu_os_setup.sh has
#       been succesfully executed before running this script.

##############################################################################

##
## computed; don't modify
USER="$SUDO_USER"
USER_HOME="/home/$USER"
LOG_FILE="${USER_HOME}/install-logs/$(basename "$0" .sh)-$(date +"%Y%m%d_%H%M%S").log"
APT_LOG="${USER_HOME}/install-logs/apt-$(date +"%Y%m%d_%H%M%S").log"

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

RetroPie-fy Ubuntu Server install. Part II: Wrestle Ubuntu into submission
URL: https://github.com/etheling/retropiefy-ubuntu

This script is derivative of Ubuntu Retropie install script by MisterB
(https://github.com/MizterB/RetroPie-Setup-Ubuntu), and of ideas and expirements
discussed in RetroPie forums (https://retropie.org.uk/forum/post/156839).

This script performs following actions: (all these are optional!)
- Install all kinds of useful things (mame_tools, p7zip,...)
- Disable system services: multipathd, apparmor, apport, avahi-daemon,
  bluetooth, samba, modemmanager
- Purge/remove system packages: command-not-found, apparmor, apport
- Perform other questionable performance optimizations:
  * disable swap
  * disable CPU vulnerability mitigations
  * install and enable preload
- It can optionally perform following even more questionable 'optimizations':
  * eradicate snapd from the system (eradicate_snapd)
  * disable IPv6 (disable_ipv6)
  * disable ufw system firewall (disable_ufw)
- Install logs are stored in:
  * full install log: ${LOG_FILE}
  * apt operations log: ${APT_LOG}

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
	    echo " * apt operations log: ${APT_LOG}"
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

# Install more
# Install and Configure RetroPie dependencies
function install_custom_packages() {
    f_preamble "${FUNCNAME[0]}"
    echo "Install extra packages..."
    
    local __rpie_deps

    __rpie_deps=(	
	preload 
	htop net-tools zip unzip libncurses-dev zip unzip p7zip-full p7zip-rar unrar jq
	## gaming / graphics related
	mame-tools imagemagick ffmpeg

	## needed by pack resources
	exiftool

	## for Wine (extract windows installers, cabs)
	cabextract innoextract bchunk
    )

    echo "-> Running apt-get update|install... Logs are redirected to ${APT_LOG}" | tee -a "${APT_LOG}"
    {
	apt-get -y update
	apt-get -y install "${__rpie_deps[@]}"
    } >> "${APT_LOG}"

    f_postamble "${FUNCNAME[0]}"
}

# get rid of snapd
function eradicate_snapd () {
    f_preamble "${FUNCNAME[0]}"
    echo "Removing snapd (OS purge will also purge snapd)..."
    snap list 
    snap remove lxd
    snap remove core18
    snap remove snapd

    systemctl disable snapd.apparmor.service
    systemctl disable snapd.seeded.service
    systemctl disable snapd.socket
    ## TODO: maybe rm -rf /snapd

    f_postamble "${FUNCNAME[0]}"
}

# Purge....
function purge_packages() {
    f_preamble "${FUNCNAME[0]}"
    echo "Remove OS packages..."

    #apt purge -y pulseaudio # leave it for X - reconsider later    
    #apt purge -y snapd

    echo "Purging packages: apparmor,apport, command-not-found,..."
    echo "Log in: ${APT_LOG}"
    {
	apt-get purge -y apparmor
	apt-get purge -y apport
	apt-get purge -y command-not-found
	apt-get purge -y systemd-oomd
	
    } >> "${APT_LOG}"
    
    f_postamble "${FUNCNAME[0]}"
}

# Disable services
function disable_system_services() {
    f_preamble "${FUNCNAME[0]}"
    echo "Disable OS services..."

    ## enable errors. some services may not exist (especially on re-run)
    set +e
    systemctl disable multipathd.service
    systemctl disable apparmor.service
    systemctl disable apport.service
    systemctl disable avahi-daemon.service
    systemctl disable bluetooth.service
    systemctl disable nmbd.service
    systemctl disable smbd.service
    systemctl disable ModemManager.service
    set -e
    
    f_postamble "${FUNCNAME[0]}"
}

# not for everyone... 
function disable_ipv6() {
    f_preamble "${FUNCNAME[0]}"
    echo "Disable IPv6"

    if grep "ipv6.disable=1" /etc/default/grub; then
	echo "WARNING: ipv6.disable=1 already set in /etc/default/grub. NOT setting again..."
	return
    fi

    backup_file /etc/default/grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"/&ipv6.disable=1 /' /etc/default/grub
    update-grub
    f_postamble "${FUNCNAME[0]}"
}

# disable swap - We've got RAM
function disable_swap() {
    f_preamble "${FUNCNAME[0]}"
    echo "Disable swap via /etc/fstab"
    backup_file /etc/fstab
    sed -i 's/.*swap/#&/' /etc/fstab
    f_postamble "${FUNCNAME[0]}"
}

# there be dragons...not for the weak and timid...but observed speedup
# maybe in the ballpark of 10-15% after aplying the kernel parameters
# https://make-linux-fast-again.com
# https://transformingembedded.sigmatechnology.se/insight-post/make-linux-fast-again-for-mortals/
function make_linux_fast_again() {
    f_preamble "${FUNCNAME[0]}"
    echo "Apply various kernel flags to speed up Linux including those that disable CPU vulnerabiliti mitigation (Danger, Will Robinson, Danger...)"
    
    if grep "mitigations=off" /etc/default/grub; then
	echo "WARNING: mitigations=off already set in /etc/default/grub. NOT setting again..."
	return
    fi

    backup_file /etc/default/grub
    ## NOTE: some of the flags are for Intel CPUs only. But should be ok even with AMD etc. cpu (e.g. they will be ignored)
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"/&noibrs noibpb nopti nospectre_v2 nospectre_v1 l1tf=off nospec_store_bypass_disable no_stf_barrier mds=off tsx=on tsx_async_abort=off mitigations=off /' /etc/default/grub
    update-grub
    f_postamble "${FUNCNAME[0]}"
}

# not for everyone... 
function disable_ufw() {
    f_preamble "${FUNCNAME[0]}"    
    echo "Disable system firewall (ufw)"
    ufw disable
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
    echo "| * APT operations log: ${APT_LOG}"
    echo "+-------------------------------------------------------------------------------"
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

are_we_root


if [[ -z "$1" ]]; then
    install_custom_packages
    disable_system_services
    #eradicate_snapd
    purge_packages
    disable_swap
    #disable_ipv6
    make_linux_fast_again
    #disable_ufw
else
    for call_function in "$@"; do
        $call_function
    done
fi

repair_permissions
complete_install
