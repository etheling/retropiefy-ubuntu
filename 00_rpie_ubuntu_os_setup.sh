#!/bin/bash
set -e

##
## Variables to control setup

# one of: wayland, kmsdrm, x11; if kmsdrm or Wayland don't support 1080p,
# and X does, then __default_session_type=x11 is forced by the script
__default_session_type="wayland"

# updating MESA will fail e.g. on Ubuntu development branch. Set to 0 to
# skip MESA update.
__update_mesa=0

##############################################################################

##
## computed; don't modify
USER="$SUDO_USER"
USER_HOME="/home/$USER"
LOG_FILE="${USER_HOME}/install-logs/$(basename "$0" .sh)-$(date +"%Y%m%d_%H%M%S").log"
APT_LOG="${USER_HOME}/install-logs/apt-$(date +"%Y%m%d_%H%M%S").log"
__target_release="22.04"

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

RetroPie-fy Ubuntu Server install. Part I: massage Ubuntu to our liking....
URL: https://github.com/etheling/retropiefy-ubuntu

This script is based on Ubuntu Retropie install script by MisterB
(https://github.com/MizterB/RetroPie-Setup-Ubuntu), and on ideas and expirements
discussed in RetroPie forums (https://retropie.org.uk/forum/post/156839).

This script will perform following actions to prepare OS for RetroPie install:
- Update MESA to 'bleeding edge' (if __update_mesa=1)
- Configure KMS/DRM, X.org/i3, and Wayland/sway to be ready to run Retropie
  with Variable Refresh Rate (VRR) enabled (if supported by HW)
- Set kernel video= option to 1920x1080p (even if larger resolutions would be
  supported, or to what ever is available if 1080p is not supported)
- Hide boot messages (allow booting directly and cleanly to EmulationSation)
- Set GRUB boot resolution to minimize resolution switches during boot
- Configure system (set timezone based on geoip, enable ntp, unrestrict dmesg, 
  disable sudo passwd, enable autologin for current user, add current user
  to video and input groups, ...
- Install logs are stored in:
  * full install log: ${LOG_FILE}
  * apt operations log: ${APT_LOG}
EOF


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
	    echo " * Full log: ${LOG_FILE}"
	    echo " * apt operations log: ${APT_LOG}"
	    echo ""
	} >&2
    fi
}
trap trapexit EXIT

if [[ $(who am i) =~ \([0-9\.]+\)$ ]]; then
    # https://serverfault.com/questions/187712/how-to-determine-if-im-logged-in-via-ssh
    echo ""
    echo "WARNING: It looks like you're running this script over SSH. Please run locally."
    echo "         (xrand resolution detection wont work over ssh). CTRL+C now to exit."
    echo ""
    sleep 5
fi

if [ ! "$(lsb_release -a 2>/dev/null| grep Release | cut -d: -f2 | xargs)" == "${__target_release}" ]; then
    echo ""
    echo "WARNING: This script targets Ubuntu Server ${__target_release}. You are running $(lsb_release -a 2>/dev/null| grep Release | cut -d: -f2 | xargs)."
    echo "         See https://github.com/etheling/retropify-ubuntu for more info."
    echo "         CTRL+C now to exit or wait to continue with the install..."
    echo ""
    sleep 10
fi

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

## FIXMME X,Y REFRESH
function util_get_refresh() {
    echo ">> CALL ${FUNCNAME[0]}(): [try to] get monitor max refresh and save monitor EDID to ${USER_HOME}/monitor.edid"
    
    if [ -z "$__fb" ]; then util_get_fb_type; fi
    ## if svgadrmfb (e.g. VirtualBox. vmware FB), then skip
    if ! echo "${__fb}" | grep -w -q "svgadrmfb"; then
	get-edid 2> /dev/null > "${USER_HOME}/monitor.edid"
	__refresh=$(parse-edid < "${USER_HOME}/monitor.edid" 2>&1 | grep VertRef | xargs | cut -d" " -f2 | cut -d- -f2-)
	
	export __refresh
    fi

    ## fallback if __refresh is not set; happens e.g. if svgadrmfb FB, and on
    ## many laptops
    if [ -z "$__refresh" ]; then
	__refresh=60
	echo "WARNING: Setting __refresh to fallback ${__refresh}Hz as monitor.edid was not read or didn't contain VertRef"
    fi
    export __refresh       
    
    echo "<< RETURN FROM ${FUNCNAME[0]}: Using monitor refresh rate: ${__refresh}Hz"
}

function util_get_connector() {
    echo ">> CALL ${FUNCNAME[0]}(): get display connector name for Wayland / KMS"
    local __i
    local __card
    for __i in /sys/class/drm/*/status ; do
	if grep -w 'connected' "${__i}" > /dev/null; then
	    __card="${__i}"
	    break
	fi
    done
    __connector=$(echo "${__card}" | cut -d'/' -f5 | cut -d'-' -f2-)
    export __connector
    echo "<< RETURN FROM ${FUNCNAME[0]}: using connector ${__connector}"
}

## FIXME: This function propably breaks in imaginative ways on every
##        system it hasn't been tested on....
## FIXME: Write open 'formula' of trying to determine useable resolution
##        ----> from xrandr output -> find highest available: cat xorg-xrandr-output.txt  | grep "^ " | sort -g | tail -1 | xargs  
## FIXME: This f() will override __default_session_type to 'x11' if KMS/Wayland dont't support 1080p but X does 
function util_default_resolution_refresh() {
    echo ">> CALL ${FUNCNAME[0]}(): Set/override screen resolution/refresh rate"

    local __swaystartlog
    local __x11startlog
    __swaystartlog="${USER_HOME}/install-logs/sway-start.log"
    __x11startlog="${USER_HOME}/install-logs/x11-start.log"

    ## [try to] determine available refresh rate(s) and display connector(s)
    util_get_refresh
    util_get_connector

    ## exported: __fbdev, __xres/__yres, __xx/__xy (X11 x and y resolution)
    local __tempres
    local __fbdev
    __fbdev="/dev/fb0"
    __tempres=$(fbset -fb "$__fbdev" -s | sed -n -e 's/^.*geometry //p')
    __xres=$(echo "$__tempres" | cut -d' ' -f1)
    __yres=$(echo "$__tempres" | cut -d' ' -f2)
    __xx=${__xres}
    __xy=${__yres}
    echo "Current ${__fb} geometry is ${__xres}x${__yres}"
    ## debug: force specific branch
    #__xres=2000
    #__fb=svgadrmfb
    if [[ "${__fb}" == "svgadrmfb" ]]; then
	echo "INFO: Virtual framebuffer (${__fb}). Setting target resolution to 1920x1080"
	__xres=1920
        __yres=1080
	__xx=1920
	__xy=1080    
    elif [ ${__xres} -gt 1920 ] || [ ${__yres} -gt 1080 ]; then
	echo "INFO: Current/default framebuffer resolution is > 1080p. Probing if 1080p is supported"
	if [ ! -f "${__x11startlog}" ]; then
	    util_get_xrandr_display
	fi
	if [ ! -f "${__swaystartlog}" ]; then
	    util_get_sway_log
	fi
	if grep 1920x1080 "${__x11startlog}"; then
	    echo "INFO: Found support for 1920x1080 from xrandr output..."
	    export __xx=1920
	    export __xy=1080	    
	fi
	if  grep "Configured mode" "${__swaystartlog}" | grep "not available"; then
	    grep "Modesetting" "${__swaystartlog}"	    
	    ## NOTE: sway output has changed; -f7 (sway 1.5) is now -f9 (sway 1.7)
	    __xres=$(grep "Modesetting" "${__swaystartlog}" | xargs | cut -d" " -f9 | cut -d"@" -f1 | cut -dx -f1)
	    __yres=$(grep "Modesetting" "${__swaystartlog}" | xargs | cut -d" " -f9 | cut -d"@" -f1 | cut -dx -f2)
	    echo "INFO: ====================================================================="
	    echo "INFO: Resolution 1920x1080 not available under Wayland. "
	    echo "INFO: Configuring for Wayland preferred resolution: ${__xres}x${__yres}:"
	    echo "INFO: ====================================================================="	    
	fi

	## test if X11 resolution is 1080p, and different from __xresX__yres to set x11 as default_session
	if [[ "${__xx}x${__xy}" == "1920x1080" ]] && [[ "${__xx}x${__xy}" != "${__xres}x${__yres}" ]]; then
	    ## Change default to x11; e.g. this is easyest way to get correct aspect ratios etc.
	    echo "WARNING: ##################################################################"
	    echo "WARNING: Changing default RetroPie session to x11 <- (from ${__default_session_type})"
	    echo "WARNING: (because KMS and Wayland do not appear to support 1080p)"
	    echo "WARNING: ##################################################################"	    
	    __default_session_type="x11"
	fi
	
    elif [ "${__xres}" -lt 1920 ] || [ "${__yres}" -lt 1080 ]; then
	echo "INFO: current framebuffer resolution < 1080p. Assuming this is max supported resolution."
	## FIXME: xrandr to test if larger is available
    fi

    echo "INFO: Attempting to set framebuffer to selected resolution (${__xres}x${__yres})"
    if ! fbset --test -fb "${__fbdev}" -xres "${__xres}" -yres "${__yres}" -match; then
	echo "WARNING: wasn't able to validate that resolution can be set."
    fi
    
    export __xres
    export __yres
        
    echo "<< RETURN ${FUNCNAME[0]}: setting installation screen resolution/refresh rate to ${__xres}x${__yres}@${__refresh} for ${__fb} (and using $__xx, $__xy for X)"
}

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

# Install and Configure RetroPie dependencies
function install_dependencies() {
    f_preamble "${FUNCNAME[0]}"
    echo "Updating OS packages and install aditional components"

    local __fbset
    local __currentver
    local __requiredver    
    local __rpie_deps

    ## imv   - Wayland native image viewer (fbi/feh used by runcommand don't support wayland,
    ##         enabling xwayland would allow using feh; also supports svg)
    ## i3    - 
    ## fbset - used by /opt/retropie/supplementary/runcommand/runcommand.sh and not
    ##         installed by default
    __rpie_deps=(
	alsa-utils menu git dialog unzip joystick fbset libdrm-dev libdrm-tests radeontop
	read-edid hwinfo bzip2 emacs-nox

	## unify Wayland / X.org experience by using i3 for X.org and Sway for Wayland
	xorg dbus-x11 wayland-protocols i3 unclutter xdotool sway

	## Wayland native image viewer (to replace fbi/feh)
	imv exiftool
	
	## FIXME: move MESA here and run update MESA before this....
    )

    echo "-> Running apt-get update|upgrade|install... Logs are redirected to ${APT_LOG}" | tee -a "${APT_LOG}"
    {
	apt-get -y update
	apt-get -y upgrade
	apt-get -y install "${__rpie_deps[@]}"
    } >> "${APT_LOG}"

    ## 'Configure' fbset;
    __fbset="$(which fbset)"
    echo "-> Allow ${__fbset} to be executed by non-root users"
    ## https://stackoverflow.com/questions/53052294/managing-linux-framebufferfb0-permission-in-low-level-c-graphics-code
    chgrp video "${__fbset}"
    chmod g+s "${__fbset}"

    echo "-> Add user $USER to the video group to allow ${__fbset} access /dev/fb"
    usermod -a -G video "${USER}"
    
    ## need sway >_ 1.5.x for vrr support; https://swaywm.org/; Ubuntu 21.04 and newer
    __currentver="$(sway --version | cut -d" " -f3- | xargs)"
    __requiredver="1.5.0"
    if [[ "$(printf '%s\n' "$__requiredver" "$__currentver" | sort -V | head -n1)" = "$__requiredver" ]]; then 
        echo "-> Installed Sway version ${__currentver} (>_ ${__requiredver} required for VRR supprot)"
    else
	## NOTE: this should no longer be the case since about Ubuntu 21.04
        echo "ERROR: Sway is older than ${__requiredver}. Wayland VRR support can not be enabled."
	sleep 10
    fi

    f_postamble "${FUNCNAME[0]}"
}

function update_mesa() {
    f_preamble "${FUNCNAME[0]}"
    
    local __mesa_ppa
    
    #__mesa_ppa="ppa:ubuntu-x-swat/updates"   # used by original script by MizterB - https://www.ubuntuupdates.org/ppa/ubuntu-x-swat
    #__mesa_ppa="ppa:kisak/kisak-mesa"        # stable
    __mesa_ppa="ppa:oibaf/graphics-drivers"  # bleeding edge

    echo "INFO: Adding and updating to MESA from ${__mesa_ppa}"
    echo "INFO: To remove and return to stock MESA: sudo ppa-purge ${__mesa_ppa}"
    echo "WARNING: using bleeding edge from ppa:oibaf/graphics-drivers may break install"
    ## https://itsfoss.com/install-mesa-ubuntu/

    if [ ! "${__update_mesa}" -eq 1 ]; then
	echo "${FUNCNAME[0]}: __update_mesa != 1. NOT going to update mesa."
    else
	{
	    ## install ppa-purge to make sure it is available on failed install
	    apt-get -y install ppa-purge
	    
	    add-apt-repository -y "${__mesa_ppa}"
	    apt-get -y update
	    apt-get -y upgrade
	    apt-get -y install mesa-utils mesa-vdpau-drivers mesa-vulkan-drivers 
	} >> "${APT_LOG}"
    fi
    
    f_postamble "${FUNCNAME[0]}"
}

## FIXME
function util_get_fb_type() {
    ## NOTE: this function has little functional purpose; it's here to primarily
    ## do some error checking and to document relevant comamnds / information to the
    ## install log EARLY on in the setup.
    echo ">> CALL ${FUNCNAME[0]}: find framebuffer type"

    local __supported
    local __tmp_fb

    ## svgadrmfb == virtualbox virtual framebuffer
    __supported="i915drmfb amdgpudrmfb svgadrmfb"
    __temp_fb="/dev/fb0"

    ## Test that /dev/fb0 is FB that we're (propably) looking at...
    echo "Current ${__temp_fb} configuration:"
    if ! fbset -fb "${__temp_fb}"; then
	echo "ERROR: cannot verify that ${__tmp_fb} is usable. Continuing but there be dragons. Maybe."
    fi
    
    ## Assumes single display setup; one display ought to be enough for anybody...
    if [ ! "$(wc -l < /proc/fb)" -eq 1 ]; then
	echo "WARNING: More than one framebuffer found. This may produce unexpected results."
	echo "         Configuring with info from ${__tmp_fb} - to change, hack function util_get_fb_type()"
    fi
    
    ## https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/6/html/deployment_guide/s2-proc-fb
    #echo "Available framebuffer(s)/display(s) are:"
    #ls -l /dev/fb*    
    echo "Framebuffer info from /proc/fb:"
    cat /proc/fb
    lshw -c display -short

    __fb="$(xargs < /proc/fb | cut -d" " -f2)"
    export __fb
    if echo "${__supported}" | grep -w -q "${__fb}"; then
	echo "Found supported framebuffer (${__fb})"
    else
cat << EOF
 __    __   ____  ____   ____   ____  ____    ____ 
|  |__|  | /    ||    \ |    \ |    ||    \  /    |
|  |  |  ||  o  ||  D  )|  _  | |  | |  _  ||   __|
|  |  |  ||     ||    / |  |  | |  | |  |  ||  |  |
|  '  '  ||  _  ||    \ |  |  | |  | |  |  ||  |_ |
 \      / |  |  ||  .  \|  |  | |  | |  |  ||     |
  \_/\_/  |__|__||__|\_||__|__||____||__|__||___,_|

WARNING: UNSUPPORTED framebuffer type ${__fb} found. Installation will proceed
         but may produce broken setup, and/or some features may not be 
         available or work as expect. Supported frame buffer types are:
         ${__supported}

	 CTRL+C now to abort. Script will otherwise continue in 30 seconds.
EOF
	sleep 30
    fi
    echo "<< RETURN FROM ${FUNCNAME[0]}: setting up for framebuffer ${__fb}"
}

function update_timezone() {
    f_preamble "${FUNCNAME[0]}"
    
    echo "INFO: Set system timezone based on IP geo location data and enable NTP for time acquistion"

    ## get time zone based on my IP (assume no VPN in use and reliable Geo IP for IP
    ## https://superuser.com/questions/309034/how-to-check-which-timezone-in-linux/639096

    ## NOTE: this will eventually break as someone pulls the plug on the
    ##       endpoint or changes API. So don't assume success. Or 100% reliability location or otherwise.
    local __tz
    if __tz="$(curl -Lsf https://ipwhois.app/line/?objects=timezone)"; then
	echo "=> Changing timezone to ${__tz}"

	timedatectl set-timezone "${__tz}"
	timedatectl set-ntp true	
	timedatectl status
    else
	echo "ERROR: unable to get time zone. Leaving time settings unchanged."
	sleep 30
    fi

    f_postamble "${FUNCNAME[0]}"
}

function write_sway_conf() {
    f_preamble "${FUNCNAME[0]}"
    
    local __swayconf
    local __footconf
    __swayconf="$USER_HOME/.config/sway/config"
    __footconf="$USER_HOME/.config/foot/foot.ini"

    if [ -z "$__xres" ]; then util_default_resolution_refresh; fi
    
    echo "INFO: Install ${__swayconf}: (${__xres}x${__yres}@${__refresh})"
    
    backup_file "${__swayconf}"
    mkdir -vp "$USER_HOME/.config/sway"
    chown "${USER}":"${USER}" "$USER_HOME/.config/sway"
    
    cat << EOF > "${__swayconf}"
## minimal sway config
## https://manpages.debian.org/experimental/sway/sway.5.en.html
##
## for full log, run with: sway --verbose -d > /dev/shm/sway.log 2>&1
##
## set SWAYSOCK for swaymsg using:
## export SWAYSOCK=/run/user/$(id -u)/sway-ipc.$(id -u).$(pgrep -x sway).sock
##

xwayland disable
#xwayland enable

# configure output
output ${__connector} mode ${__xres}x${__yres}@${__refresh}Hz
output ${__connector} scale 1
output * adaptive_sync on
output * bg #000000 solid_color

# prevent swaylock (possibly unnecessary)
for_window [app_id="emulationstation"] inhibit_idle fullscreen
for_window [app_id="retroarch"] inhibit_idle fullscreen

#workspace_layout tabbed
default_border none

## hide mouse cursor (aka unclutter)                                                                                                                                                                  
## NOTE: swayvm (as of at least 1.5.1) bugs and hide_cursor wont work until
## mouse has actually been moved. Thus the only(?) way to hide the mouse
## pointer is to move the mouse pointer off the visible screen.
seat seat0 {
    fallback true
    hide_cursor 100
    cursor set 3840 2160
}

## Win+Enter to open shell
set \$mod Mod4
bindsym \$mod+Return exec foot

## Also define Shift+Enter to open shell
bindsym Shift+Return exec foot

## additional minimal bindings from https://github.com/swaywm/sway/blob/master/config.in
# Kill focused window
bindsym \$mod+Shift+q kill
# Move your focus around
bindsym \$mod+Left focus left
bindsym \$mod+Down focus down
bindsym \$mod+Up focus up
bindsym \$mod+Right focus right
# Move the focused window with the same, but add Shift
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Down move down
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Right move right

## export SWAYSOCK
exec --no-startup-id export SWAYSOCK=/run/user/\$(id -u)/sway-ipc.\$(id -u).\$(pgrep -x sway).sock

## NOTE: 01_... retropie script will remove lines with 'exec --no-startup-id foot'
exec --no-startup-id foot 
##exec --no-startup-id foot --fullscreen -- emulationstation --no-splash > /dev/shm/emulationstation.log 2>&1

EOF

    chown -v "${USER}":"${USER}" "${__swayconf}"
    #rw-r--r--
    chmod -v 644 "${__swayconf}"

    ## create default config for foot terminal
    mkdir -vp "${USER_HOME}/.config/foot"
    cat << EOF > "${__footconf}"    
## complete foot .ini: https://codeberg.org/dnkl/foot/raw/branch/master/foot.ini
##
font=monospace:size=11
dpi-aware=yes
bold-text-in-bright=yes

[scrollback]
lines=10000

[cursor]
# style=block
# color=111111 dcdccc
blink=yes

EOF
    
    touch "${USER_HOME}/.config/foot/foot.ini"
    
    chown -v "${USER}":"${USER}" "${USER_HOME}/.config/foot/foot.ini"
    chmod -v 644 "${USER_HOME}/.config/foot/foot.ini"

    f_postamble "${FUNCNAME[0]}"    
}

##

__modeline="n/a"
function gen_xorg_modeline() {
    if [ -z "$__xres" ]; then util_default_resolution_refresh; fi

    echo "${FUNCNAME[0]}(): Generate modeline for xorg conf from monitor edid (saved to ~/monitor.edid)"
    echo "WARNING: LIKELY VERY FRAGILE / UNRELIABLE. Tested on exactly 1 monitor"

    ## http://www.polypux.org/projects/read-edid/ - note: get-edid needs root
    get-edid 2> /dev/null > "${USER_HOME}/monitor.edid"
    parse-edid < "${USER_HOME}/monitor.edid" 2> /dev/null > /tmp/monitor-edid.txt

    ## grep modelines matching XRES and sort by 4th column (clock) and just pick the highest clock
    ## https://en.wikipedia.org/wiki/XFree86_Modeline
    __modeline=$(grep Modeline /tmp/monitor-edid.txt | grep "${__xres}" | expand -t 1 | tr -s ' ' | sort -rnk4 | head -1)
    if [ -z "$__modeline" ]; then
	echo "WARNING: couldn't determine useable modeline; unsetting __modeline"
	unset __modeline
    else
	echo -n "Modeline: "
	echo "${__modeline}" | xargs
    fi
}

function util_get_sway_log() {
    echo "${FUNCNAME[0]}(): Run sway with --verbose -d to determine if it supports 1080p"

    ## FIXME: TEST IF WE'RE ON SSH ; and SKIP ETC.
    
    local __conf
    local __display
    local __swaystartlog

    ## NOTE: must be same as in util_default_resolution_refresh()
    __swaystartlog="${USER_HOME}/install-logs/sway-start.log"

    if [ ! -f "${__swaystartlog}" ]; then
	if [ -z "$__connector" ]; then
	    util_get_connector
	fi
    
	__conf="${USER_HOME}/.config/sway/config"
	mkdir -p "${USER_HOME}/.config/sway"
	
	if [ -f "${__conf}" ]; then
	    cp -v "${__conf}" "${__conf}.backup"
	fi

	cat << EOF > "${__conf}"
##
## Temporary sway conf for resolution probing
xwayland disable
output ${__connector} mode 1920x1080
output ${__connector} scale 1
exec --no-startup-id export SWAYSOCK=/run/user/\$(id -u)/sway-ipc.\$(id -u).\$(pgrep -x sway).sock
exec --no-startup-id sleep 2 && pkill -9 sway > /dev/null 2>&1 
EOF

	echo "INFO: Running Wayland/Sway as user ${USER}. Log in ${__swaystartlog}"

	set +e
	sudo -H -u "${USER}" XDG_RUNTIME_DIR="/run/user/$(sudo -H -u "${USER}" id -u)" sway --verbose -d 2>&1 | sudo tee "${__swaystartlog}" 
	set -e
    
	if [ -f "${__conf}.backup" ]; then
	    mv "${__conf}.backup" "${__conf}"
	else
	    rm "${__conf}"
	fi
    else
	echo "IMFO: Skipping probe. ${__swaystartlog} already exists. Remove to force probe."
    fi

    ## FIXME: do some sanity check on log to inform user...
}


function util_get_xrandr_display() {
    echo ">> CALL ${FUNCNAME[0]}(): Running xrandr to determine display name for .xsession and xorg.conf"
    echo "NOTE: this will *only* work when running from login console and *will* fail if running over SSH"
    echo "NOTE: IF running over ssh, set __X11DISPLAY"

    ## FIXME: TEST IF WE'RE ON SSH ; and SKIP ETC.
    
    local __conf
    local __display
    local __x11startlog

    ## NOTE: must match logname in ....
    __x11startlog="${USER_HOME}/install-logs/x11-start.log"

    if [ ! -f "${__x11startlog}" ]; then
	## NOTE: we will run as r00t -> thats where .xsession goes
	__conf="/root/.xsession"

	if [ -f "${__conf}" ]; then
	    cp -v "${__conf}" "${__conf}.backup"
	fi

	cat << EOF > "${__conf}"
##
## Temporary .xsession to run xrandr in order to obtain connected display name for X
sleep 1
xrandr > "${__x11startlog}" 2>&1
sleep 1
EOF
	
	## now startx (as root)
	echo "INFO: Starting X to record xrandr output. Log in ${__x11startlog}"
	startx 2>&1 | tee /tmp/startx-randr.log > /dev/null
	cp "${__conf}" /tmp/test.xsession	
	if [ -f "${__conf}.backup" ]; then
	    mv "${__conf}.backup" "${__conf}"
	else
	    rm "${__conf}"
	fi
    else
	echo "IMFO: Skipping probe. ${__x11startlog} already exists. Remove to force probe."
    fi

    ## NOTE: will FAIL if more than 2x displays connected
    ## FIXME: maybe add check sometime for 2+ displays
    __display=$(grep " connected" "${__x11startlog}" | cut -d" " -f1)

    export __X11DISPLAY="${__display}"
    echo "<< RETURN ${FUNCNAME[0]}: using ${__X11DISPLAY} as display connector name for X11"
}

##


function write_xorg_conf() {
    f_preamble "${FUNCNAME[0]}"

    local __xorgconf
    __xorgconf="/etc/X11/xorg.conf"
    
    backup_file "${__xorgconf}"
    rm -f "${__xorgconf}"
    
    if [ -z ${__X11DISPLAY+x} ]; then
	util_get_xrandr_display
    fi


    if [ -z "$__xres" ]; then util_default_resolution_refresh; fi    
    if [ -z "$__fb" ]; then util_get_fb_type; fi

    if [ -z "$__xx" ]; then
	__xx=$__xres
	__xy=$__yres
    fi

    echo "INFO: currently configured resolution for X: ${__xx}x${__xy}"
    
    ##echo "${FUNCNAME[0]}(): Generate ${__xorgconf} to set resolution, refresh rate, enable DRI3, VRR and tearfree support"
    ##echo "Setting X resolution to ${__x11xres}x${__x11yres}@${__refresh}Hz mode"
    #echo "Enable Direct Rendering Infrastructure 3 (DRI3), Variable Refresh Rate (VRR) and TearFree support."
    #echo "NOTE: After strating X, observe these logs to make sure everything is properly set:"
    #echo "NOTE:  ~/.local/share/xorg/Xorg.0.log and ~/.xsession-errors"


    echo "INFO: Try to generate modeline with highest supported refresh rate. Needed for VRR."
    gen_xorg_modeline
    if [ -n "${__modeline}" ]; then 
	local __modename
	__modename=$(echo "${__modeline}" | grep -oP '".*?"')
	echo "INFO: Success. Using ${__modename} for X.org"
    else
	echo "WARNING: Could not generate modeline. Starting X using x.org preferred refresh."
    fi

    ## VRR: https://wiki.archlinux.org/index.php/Variable_refresh_rate
    ## TearFree https://wiki.archlinux.org/index.php/Ryzen
    ## DRI3: https://en.wikipedia.org/wiki/Direct_Rendering_Infrastructure
    ## logs in: ~/.local/share/xorg/Xorg.0.log and ~/.xsession-errors
    ## use "xrandr --props" to see active properties for connectors
    
    
    ## for reference - workding xorg.conf for viewsonic XG2405:
    #Section "Monitor"
    # Identifier "DisplayPort-0"
    # Modeline "1920x1080_144"  325.08  1920 1944 1976 2056  1080 1083 1088 1098 +hsync +vsync
    # Option "PreferredMode" "1920x1080_144"
    # EndSection
    # Section "Device"
    #  Identifier "AMD"
    #  Driver "amdgpu"
    #  Option "TearFree" "true"
    #  Option "DRI" "3"
    #  Option "VariableRefresh" "true"
    # EndSection

    if [[ "${__fb}" == "amdgpudrmfb" ]] && [ -n "${__modeline}" ]; then
	cat << EOF > "${__xorgconf}"
##
## /etc/X11/xorg.conf for AMD Ryzen GPU and FreeSync display connected via
## DisplayPort (enables DRI3, tearfree, vrr/freesync)
##
## https://wiki.archlinux.org/index.php/AMDGPU
## https://wiki.archlinux.org/index.php/Variable_refresh_rate
## https://wiki.archlinux.org/index.php/Ryzen
## https://en.wikipedia.org/wiki/Direct_Rendering_Infrastructure
## https://www.amd.com/en/support/kb/faq/gpu-754
##
## logs in: ~/.local/share/xorg/Xorg.0.log and ~/.xsession-errors##
##
## use "xrandr --props" to see active properties for connectors
## (note: property freesync is set using xrandr in .xsession)
## 

## NOTE: Identifier must be extracted for connected display from xrandr output
Section "Monitor"
     Identifier "${__X11DISPLAY}"
     ${__modeline}
     Option "PreferredMode" ${__modename}
EndSection

### FIXME: depending which FB we have; set differently
Section "Device"
     Identifier "AMD"
     Driver "amdgpu"
     Option "TearFree" "true"
     Option "DRI" "3"
     Option "VariableRefresh" "true"
EndSection
EOF

    elif [[ "${__fb}" == "svgadrmfb" ]]; then
	cat << EOF > "${__xorgconf}"
##
## /etc/X11/xorg.conf for VirtualBox VMs
##
## logs in: ~/.local/share/xorg/Xorg.0.log and ~/.xsession-errors##
##
## use "xrandr --props" to see active properties for connectors
## 

Section "Device"
     Identifier "Video Device"
     Driver "vboxvideo"
     Option "TearFree" "true"
     Option "DRI" "3"
     #Option "VariableRefresh" "true"
EndSection

Section "Screen"
	Identifier "Default Screen"
	Monitor "${__connector}"
	Device "Video Device"
	DefaultDepth 24
	#SubSection   "Display"
	## uncomment subsection to force resolution; instead of letting
	## VM set resolution based on window size
	#	     Depth	24
	#	     Modes	"${__xx}x${__xy}"
	#EndSubSection
EndSection

Section "Monitor"
     Identifier "${__connector}"
EndSection
EOF

	## fallback; i915drmf
	## NOTE: VRR unlikley to work. IF you're reading, and you've got working Intel VRR setup, let me know of the config.
    else 
	cat << EOF > "${__xorgconf}"
##
## /etc/X11/xorg.conf for i915drmfb and for others where modeline isn't available
##
## logs in: ~/.local/share/xorg/Xorg.0.log and ~/.xsession-errors##
##
## use "xrandr --props" to see active properties for connectors
## 
## NOTE: not tested with actual Intel VRR capable HW - VRR unlikely to work
## (thus don't bother with specific Modeline - let HW pick preferred Hz)
##

## https://wiki.archlinux.org/title/intel_graphics
## https://man.archlinux.org/man/intel.4#CONFIGURATION_DETAILS

Section "Device"
  	Identifier "Intel Graphics"
	Driver "intel"

	## NOTE: below are experimental / likely have little actual effect - good or bad...
       	Option "TearFree" "true"
	## possibly reduce latency by disabling TripleBuffer
	Option "TripleBuffer" "false"
	#Option "DRI" "3"
	Option "VariableRefresh" "true"
EndSection

Section "Screen"
	Identifier "Default Screen"
	Monitor "${__connector}"
	#Device "Video Device"
	#DefaultDepth 24
	SubSection   "Display"
	#	     Depth	24
		     Modes	"${__xx}x${__xy}"
	EndSubSection
EndSection

Section "Monitor"
     Identifier "${__connector}"
EndSection
EOF

    fi
    
    chown -v root:root "${__xorgconf}"
    chmod -v 644 "${__xorgconf}" ; #rw-r--r--

    f_postamble "${FUNCNAME[0]}"    
}

function write_xsession() {
    f_preamble "${FUNCNAME[0]}"

    local __xsession
    __xsession="${USER_HOME}/.xsession"
    echo "INFO: creating ${__xsession} to launch X11/i3 with FreeSync enabled"

    backup_file "${__xsession}"
    
    if [ -z "$__xres" ]; then util_default_resolution_refresh; fi

    if [ -z ${__X11DISPLAY+x} ]; then
	util_get_xrandr_display
    fi
    
    cat << EOF > "${__xsession}"
##
## sleep to allow X to 'settle'?
#sleep 1

## hide mouse pointer (first move it outside screen boundary) and
## enable unclutter (while making sure old instances aren't running)
xdotool mousemove ${__xres} ${__yres}
pkill -9 unclutter
unclutter -root -idle 1 & disown
## consider adding to unclutter if mouse doesn't stay hidden; -visible -jitter 10

## Disable screen saver blanking and Display Power Management Signaling
## https://wiki.archlinux.org/index.php/Display_Power_Management_Signaling
xset s off && xset -dpms

## Try to Enable VRR/FreeSync - doesn't appear to breatk things even if VRR not available
## https://www.amd.com/en/support/kb/faq/gpu-754
DISPLAY=:0 xrandr --output ${__X11DISPLAY} --set "freesync" 1

## start i3 - https://i3wm.org/
i3
EOF

    chown -v "${USER}":"${USER}" "${__xsession}"
    chmod -v 644 "${__xsession}"

    f_postamble "${FUNCNAME[0]}"
}

function write_i3_config() {
    f_preamble "${FUNCNAME[0]}"
    
    local __i3config
    __i3config="${USER_HOME}/.config/i3/config"

    echo "INFO: Creating ${__i3config}"
    backup_file "${__i3config}"

    mkdir -vp "${USER_HOME}/.config/i3"
    chown "${USER}":"${USER}" "${USER_HOME}/.config/i3"
    
    ## FIXME: minimize similar to minimal sway conf - now bloated default....
    cat << EOF > "${__i3config}"
for_window [class="^.*"] border pixel 0

# This file has been auto-generated by i3-config-wizard(1).
# It will not be overwritten, so edit it as you like.
#
# Should you change your keyboard layout some time, delete
# this file and re-run i3-config-wizard(1).
#

# i3 config file (v4)
#
# Please see https://i3wm.org/docs/userguide.html for a complete reference!

set \$mod Mod4

# Font for window titles. Will also be used by the bar unless a different font
# is used in the bar {} block below.
font pango:monospace 8

# This font is widely installed, provides lots of unicode glyphs, right-to-left
# text rendering and scalability on retina/hidpi displays (thanks to pango).
#font pango:DejaVu Sans Mono 8

# The combination of xss-lock, nm-applet and pactl is a popular choice, so
# they are included here as an example. Modify as you see fit.

# xss-lock grabs a logind suspend inhibit lock and will use i3lock to lock the
# screen before suspend. Use loginctl lock-session to lock your screen.
#exec --no-startup-id xss-lock --transfer-sleep-lock -- i3lock --nofork

# NetworkManager is the most popular way to manage wireless networks on Linux,
# and nm-applet is a desktop environment-independent system tray GUI for it.
#exec --no-startup-id nm-applet

exec --no-startup-id unclutter -idle 0.0001

## done in xorg.conf
#exec --no-startup-id xrandr --output "${__connector}" --rate 144 --mode 1920x1080

## done in .xsession
#exec --no-startup-id xrandr --output "${__connector}" --set "freesync" 1

# Use Mouse+\$mod to drag floating windows to their wanted position
# floating_modifier \$mod

# start a terminal
bindsym \$mod+Return exec i3-sensible-terminal

# kill focused window
bindsym \$mod+Shift+q kill

# start dmenu (a program launcher)
#bindsym \$mod+d exec dmenu_run
# There also is the (new) i3-dmenu-desktop which only displays applications
# shipping a .desktop file. It is a wrapper around dmenu, so you need that
# installed.
# bindsym \$mod+d exec --no-startup-id i3-dmenu-desktop

# change focus
bindsym \$mod+j focus left
bindsym \$mod+k focus down
bindsym \$mod+l focus up
bindsym \$mod+semicolon focus right

# alternatively, you can use the cursor keys:
bindsym \$mod+Left focus left
bindsym \$mod+Down focus down
bindsym \$mod+Up focus up
bindsym \$mod+Right focus right

# move focused window
bindsym \$mod+Shift+j move left
bindsym \$mod+Shift+k move down
bindsym \$mod+Shift+l move up
bindsym \$mod+Shift+semicolon move right

# alternatively, you can use the cursor keys:
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Down move down
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Right move right

# split in horizontal orientation
bindsym \$mod+h split h

# split in vertical orientation
bindsym \$mod+v split v

# enter fullscreen mode for the focused container
bindsym \$mod+f fullscreen toggle

# change container layout (stacked, tabbed, toggle split)
bindsym \$mod+s layout stacking
bindsym \$mod+w layout tabbed
bindsym \$mod+e layout toggle split

# toggle tiling / floating
bindsym \$mod+Shift+space floating toggle

# change focus between tiling / floating windows
bindsym \$mod+space focus mode_toggle

# focus the parent container
bindsym \$mod+a focus parent

# focus the child container
#bindsym \$mod+d focus child

# Define names for default workspaces for which we configure key bindings later on.
# We use variables to avoid repeating the names in multiple places.
set \$ws1 "1"
set \$ws2 "2"
set \$ws3 "3"
set \$ws4 "4"
set \$ws5 "5"
set \$ws6 "6"
set \$ws7 "7"
set \$ws8 "8"
set \$ws9 "9"
set \$ws10 "10"

# switch to workspace
bindsym \$mod+1 workspace number \$ws1
bindsym \$mod+2 workspace number \$ws2
bindsym \$mod+3 workspace number \$ws3
bindsym \$mod+4 workspace number \$ws4
bindsym \$mod+5 workspace number \$ws5
bindsym \$mod+6 workspace number \$ws6
bindsym \$mod+7 workspace number \$ws7
bindsym \$mod+8 workspace number \$ws8
bindsym \$mod+9 workspace number \$ws9
bindsym \$mod+0 workspace number \$ws10

# move focused container to workspace
bindsym \$mod+Shift+1 move container to workspace number \$ws1
bindsym \$mod+Shift+2 move container to workspace number \$ws2
bindsym \$mod+Shift+3 move container to workspace number \$ws3
bindsym \$mod+Shift+4 move container to workspace number \$ws4
bindsym \$mod+Shift+5 move container to workspace number \$ws5
bindsym \$mod+Shift+6 move container to workspace number \$ws6
bindsym \$mod+Shift+7 move container to workspace number \$ws7
bindsym \$mod+Shift+8 move container to workspace number \$ws8
bindsym \$mod+Shift+9 move container to workspace number \$ws9
bindsym \$mod+Shift+0 move container to workspace number \$ws10

# reload the configuration file
bindsym \$mod+Shift+c reload
# restart i3 inplace (preserves your layout/session, can be used to upgrade i3)
bindsym \$mod+Shift+r restart
# exit i3 (logs you out of your X session)
bindsym \$mod+Shift+e exec "i3-nagbar -t warning -m 'You pressed the exit shortcut. Do you really want to exit i3? This will end your X session.' -B 'Yes, exit i3' 'i3-msg exit'"

# resize window (you can also use the mouse for that)
mode "resize" {
        # These bindings trigger as soon as you enter the resize mode

        # Pressing left will shrink the window’s width.
        # Pressing right will grow the window’s width.
        # Pressing up will shrink the window’s height.
        # Pressing down will grow the window’s height.
        bindsym j resize shrink width 10 px or 10 ppt
        bindsym k resize grow height 10 px or 10 ppt
        bindsym l resize shrink height 10 px or 10 ppt
        bindsym semicolon resize grow width 10 px or 10 ppt

        # same bindings, but for the arrow keys
        bindsym Left resize shrink width 10 px or 10 ppt
        bindsym Down resize grow height 10 px or 10 ppt
        bindsym Up resize shrink height 10 px or 10 ppt
        bindsym Right resize grow width 10 px or 10 ppt

        # back to normal: Enter or Escape or \$mod+r
        bindsym Return mode "default"
        bindsym Escape mode "default"
        bindsym \$mod+r mode "default"
}

bindsym \$mod+r mode "resize"

# Start i3bar to display a workspace bar (plus the system information i3status
# finds out, if available)
#bar {
#        status_command i3status
#}

## Define Shift+Enter to open shell
bindsym Shift+Return exec i3-sensible-terminal

## NOTE: 'exec --no-startup-id gnome-terminal' will be replaced in phase #1
exec --no-startup-id gnome-terminal
#exec --no-startup-id gnome-terminal -- emulationstation --no-splash > /dev/shm/emulationstation.log 2>&1


EOF

    chown "${USER}":"${USER}" "${__i3config}"

    f_postamble "${FUNCNAME[0]}"
}

function write_bash_profile() {
    f_preamble "${FUNCNAME[0]}"    
    
    local __conf
    __conf="$USER_HOME/.profile"
    echo "INFO: Install new ${__conf} - session type: ${__default_session_type}"
    
    backup_file "${__conf}"
    
    cat << EOF > "${__conf}"
# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# If running bash
if [ -n "\$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "\$HOME/.bashrc" ]; then
	. "\$HOME/.bashrc"
    fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "\$HOME/bin" ] ; then
    PATH="\$HOME/bin:\$PATH"
fi

# set PATH so it includes user's private bin if it exists
if [ -d "\$HOME/.local/bin" ] ; then
    PATH="\$HOME/.local/bin:\$PATH"
fi

## retropie additions

if [[ -z \$DISPLAY ]] && [[ ! \$(tty) == /dev/tty1 ]]; then
    alias ls='ls --color=auto'
    if [ -f /usr/local/bin/rpie-nuc-welcome.sh ]; then /usr/local/bin/rpie-nuc-welcome.sh ; fi
    if [ -f /etc/motd.ssh ]; then 
       alias help="/usr/bin/cat /etc/motd.ssh"
       cat /etc/motd.ssh
    fi
    PS1="\\[\\033[01;34m\\]\\u@\\h\\[\\033[1;39m\\] \\w \\[\\033[1;36m\\]\\$\[\\033[00m\\] "        
fi

## test if logging in using ssh and early exit
if [ -n "\$SSH_CLIENT" ] || [ -n "\$SSH_TTY" ]; then
    return
fi

## Test if RetroPie session type has been defined, and if not, set
## NOTE: this can be changed by running from shell (with no X/Wayland running):
## # export RETROPIE_SESSION_TYPE=kmsdrm # of kmsdrm, wayland, x11
## # source ~/.profile

if [ -z "\${RETROPIE_SESSION_TYPE+x}" ]; then
   export RETROPIE_SESSION_TYPE=${__default_session_type}
fi

case "\${RETROPIE_SESSION_TYPE}" in
  kmsdrm)
    source "$USER_HOME/.env-kmsdrm"
    ## anchor-emulationstation
    ;;

  wayland)
    source "$USER_HOME/.env-wayland"
    sway >/dev/null 2>&1    
    ;;

  x11)
    source "$USER_HOME/.env-xorg"
    startx
    ;;
  *)
    echo "WARNING: Unknown RETROPIE_SESSION_TYPE: \${RETROPIE_SESSION_TYPE} - environment NOT properly set-up"
    ;;
esac

EOF

    echo "INFO: Writing ${USER_HOME}/{.env-wayland|.env-xorg|.env-kmsdrm}..."
    cat << EOF > "${USER_HOME}/.env-wayland"
## https://wiki.archlinux.org/index.php/wayland
## https://discourse.ubuntu.com/t/environment-variables-for-wayland-hackers/12750
export XDG_CURRENT_DESKTOP=sway
export XDG_SESSION_TYPE=wayland
export XDG_CONFIG_HOME="\$HOME/.config"
export SDL_VIDEODRIVER=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_WAYLAND_FORCE_DPI="physical"
export QT_QPA_PLATFORM="wayland-egl"
export GDK_BACKEND=wayland
EOF

    ## FIXME: fix the vars for X
    cat << EOF > "${USER_HOME}/.env-xorg"
export XDG_CONFIG_HOME="\$HOME/.config"
export XDG_CURRENT_DESKTOP=i3
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11 
unset SDL_VIDEODRIVER
unset MOZ_ENABLE_WAYLAND
unset QT_WAYLAND_FORCE_DPI
unset QT_QPA_PLATFORM

## modify gnome terminal - https://github.com/MizterB/RetroPie-Setup-Ubuntu/blob/master/retropie_setup_ubuntu.sh
GNOME_TERMINAL_SETTINGS='dbus-launch gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/'
\$GNOME_TERMINAL_SETTINGS use-theme-colors false
\$GNOME_TERMINAL_SETTINGS use-theme-transparency false
\$GNOME_TERMINAL_SETTINGS foreground-color '#FFFFFF'
\$GNOME_TERMINAL_SETTINGS background-color '#000000'
\$GNOME_TERMINAL_SETTINGS cursor-blink-mode 'off'
\$GNOME_TERMINAL_SETTINGS scrollbar-policy 'never'
\$GNOME_TERMINAL_SETTINGS audible-bell 'false'
gsettings set org.gnome.Terminal.Legacy.Settings default-show-menubar false

EOF

    ## KMS/DRM environment
    cat << EOF > "${USER_HOME}/.env-kmsdrm"
unset XDG_CONFIG_HOME
unset XDG_CURRENT_DESKTOP
unset XDG_SESSION_TYPE
unset SDL_VIDEODRIVER
unset MOZ_ENABLE_WAYLAND
unset QT_WAYLAND_FORCE_DPI
unset QT_QPA_PLATFORM
unset GDK_BACKEND
EOF
    

    chown -v "${USER}":"${USER}" "${__conf}"
    chmod -v 644 "${__conf}"
    chown -v "${USER}":"${USER}" "${USER_HOME}/.env-kmsdrm"
    chmod -v 644 "${USER_HOME}/.env-kmsdrm"
    chown -v "${USER}":"${USER}" "${USER_HOME}/.env-xorg"
    chmod -v 644 "${USER_HOME}/.env-xorg"
    chown -v "${USER}":"${USER}" "${USER_HOME}/.env-wayland"
    chmod -v 644 "${USER_HOME}/.env-wayland"

    f_postamble "${FUNCNAME[0]}"
}


## Build video= kernel boot option string. Assumes only one connected display; falls back
## to generic form if multiple connected displays
## NOTE: THIS FUNCTION SETS __xres,...,__connector
function set_kernel_video_option() {
    f_preamble "${FUNCNAME[0]}"
    echo "INFO: Construct video= kernel boot option from /sys/class/drm/card*"
    
    local __card
    local __tempres
    local __kopt_video

    ## set defaults
    util_default_resolution_refresh

    __card="null"

    local __fbdev="/dev/fb0"    
    echo "/proc/fb: "
    cat /proc/fb
    fbset -fb "$__fbdev" -s

    # determine video= parameter(s)
    echo "INFO: List of output ports under /sys/class/drm/*:"
    for p in /sys/class/drm/*/status; do con=${p%/status}; echo -n "${con#*/card?-}: "; cat "$p"; done    
    if [ ! "$(cat /sys/class/drm/*/status | grep -wc "connected")" -eq 1 ]; then
	__kopt_video="video=${__xres}x${__yres}@${__refresh}"
	echo "WARNING: multiple (or zero) connected displays found. This is untested setup."
	echo "         Falling back to generic $__kopt_video kernel parameter."
	return
	## FIXME: THIS IS NOT RIGHT ACTION HERE
    fi

    for i in /sys/class/drm/*/status ; do
	if grep -w 'connected' "$i" > /dev/null; then
	#if [[ $? -eq 0 ]]; then
	    __card=$i
	    break
	fi
    done
    #echo $CARD | cut -d'/' -f5 | cut -d'-' -f2-
    __kopt_video="video=$(echo "${__card}" | cut -d'/' -f5 | cut -d'-' -f2-):${__xres}x${__yres}@${__refresh}"

    echo "INFO: kernel video boot option: ${__kopt_video}"
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*/& ${__kopt_video}/" /etc/default/grub
    update-grub
    grep "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub
    
    __connector=$(echo "${__card}" | cut -d'/' -f5 | cut -d'-' -f2-)
    export __connector
    echo "INFO: setting X connector information to ${__connector} for card ${__card}"

    f_postamble "${FUNCNAME[0]}"
}


# Create file in sudoers.d directory and disable password prompt
function disable_sudo_password() {
    f_preamble "${FUNCNAME[0]}"

    echo "INFO: Disabling the sudo password prompt"
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/${USER}-no-password-prompt"
    chmod -v 0440 "/etc/sudoers.d/${USER}-no-password-prompt"

    f_postamble "${FUNCNAME[0]}"    
}


# Hide Boot Messages
function hide_boot_messages() {
    f_preamble "${FUNCNAME[0]}"

    echo "Hiding boot messages (modify /etc/default/grub, rm cloudinit, add ~/.hushlogin)"
    
    # Hide kernel messages and blinking cursor via GRUB
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet vt.global_cursor_default=0 loglevel=1"/g' /etc/default/grub

    # Add GRUB_RECORDFAIL_TIMEOUT to hide grub boot menu when 'UEFI + single OS + LVM'
    # https://ubuntuforums.org/showthread.php?t=2412153
    # NOTE: adjust timeouts to 0 for faster and more silent boot and update-grub
    sed "s/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2\nGRUB_RECORDFAIL_TIMEOUT=2/g" /etc/default/grub
    
    update-grub

    # Remove cloud-init to suppress its boot messages
    apt-get purge cloud-init -y  >> "${APT_LOG}" 2>&1
    rm -rf /etc/cloud/ /var/lib/cloud/

    # Disable motd
    touch "${USER_HOME}/.hushlogin"
    chown -v "${USER:$USER}" "${USER_HOME}/.hushlogin"

    f_postamble "${FUNCNAME[0]}"
}


# Change the default runlevel to multi-user
# This disables GDM from loading at boot (new for 20.04)
function enable_runlevel_multiuser () {
    f_preamble "${FUNCNAME[0]}"
    echo "INFO: Enabling the 'multi-user' runlevel"
    echo "NOTE: 'sudo systemctl set-default graphical.target' to restore workstation"
    echo "       setup default."
    systemctl set-default multi-user
    f_postamble "${FUNCNAME[0]}"
}


# Configure user to autologin at the terminal
function enable_autologin_tty() {
    f_preamble "${FUNCNAME[0]}"
    echo "Enabling autologin to terminal via /etc/systemd/system/getty@tty1.service.d/override.conf"
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat << EOF >> /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --noissue --autologin $USER %I \$TERM
Type=idle
EOF
    f_postamble "${FUNCNAME[0]}"
}


# Install and configure extra tools
function fix_quirks() {
    f_preamble "${FUNCNAME[0]}"
    echo "INFO: Fixing any known quirks"

    # XDG_RUNTIME_DIR
    echo "INFO: Remove 'error: XDG_RUNTIME_DIR not set in the environment' CLI error"
    echo "      when exiting Retroarch from the RetroPie Setup screen within ES"
    echo "      by creating a file in sudoers.d directory to keep environment variable"
    echo 'Defaults	env_keep +="XDG_RUNTIME_DIR"' | sudo tee /etc/sudoers.d/keep-xdg-environment-variable
    chmod -v 0440 /etc/sudoers.d/keep-xdg-environment-variable
    echo ""

    echo "INFO: Add rpie user to the input group to allow /dev/input/* access"
    echo "      (needed for KMS/DRM mode with linxuraw/udev access"
    ## https://github.com/libretro/RetroArch/issues/5033
    ## RetroPie helpers.sh: echo 'SUBSYSTEM=="input", GROUP="input", MODE="0660"' > /etc/udev/rules.d/99-input.rules 
    usermod -a -G input "${USER}"
       
    f_postamble "${FUNCNAME[0]}"
}


## Sets the GRUB graphics mode (https://retropie.org.uk/forum/post/238241)
## This is to minimize mode switches (e.g. monitor flickering and delays) during
## boot. For this reason, it is set to what ever is the default selected by BIOS
## and then the actual modesetting is later done by kernel video= parameter.
## E.g. this setting has nothing to do with the resolution RetroPie will run
function set_resolution_grub() {
    f_preamble "${FUNCNAME[0]}"
    echo "To minimize modeswitches during boot set and keep BIOS default gfx mode"
    echo "throughout the boot."
    
    local __eflog
    local __grubresolution
    
    __eflog="${USER_HOME}/install-logs/efifb-probe.log"    
    dmesg | grep efifb > "${__eflog}" 2>&1

    ## Obtain currently used (EFI) framebuffer from kernel boot log
    ## NOTE: 'hwinfo --framebuffer' doesn't currently return available FBs...
    ## Grub vbeinfo/videoindo modes. You may want to manually see if 1920x1080
    ## is available and switch to it in your BIOS, if supported.
    __grubresolution=$(grep "efifb: mode" < "${__eflog}" | xargs | cut -d" " -f6)
    
    echo "Setting GRUB graphics mode to '${__grubresolution} in /etc/default/grub"

    ## run 'vbeinfo' (legacy BIOS) or 'videoinfo' (UEFI) from the GRUB command line
    ## to see the supported modes

    ## FIXME: ERASE LINES WITH GRUB_GFX and then just enter new
    sed -i "s/#GRUB_GFXMODE=.*/GRUB_GFXMODE=${__grubresolution}auto\nGRUB_GFXPAYLOAD=\"keep\"/g" "/etc/default/grub"
    update-grub

    echo "/etc/default/grub GRUB_GFXMODE and GRUB_GFXPAYLOAD set to:"
    grep "GRUB_GFX" /etc/default/grub

    f_postamble "${FUNCNAME[0]}"
}

function unrestrict_dmesg() {
    f_preamble "${FUNCNAME[0]}"
    local __sysctl
    __sysctl="/etc/sysctl.d/10-unrestrict-dmesg.conf"
    echo "Allow non-root user to dmesg (see ${__sysctl})"
    echo "(5.8.x series and newer kernels restric access to dmesg)"

    ## No need to backup as there is no existing file    
    cat << EOF > "${__sysctl}"
## https://www.cyberciti.biz/faq/how-to-prevent-unprivileged-users-from-viewing-dmesg-command-output-on-linux/
kernel.dmesg_restrict = 0
EOF

    chown -v root:root "${__sysctl}"
    chmod -v 644 "${__sysctl}"
    sysctl -w kernel.dmesg_restrict=0
    
    f_postamble "${FUNCNAME[0]}"
}

# Minimize post boot kernel console logging
function silence_kernel_console() {
    f_preamble "${FUNCNAME[0]}"

    local __sysctl
    __sysctl="/etc/sysctl.d/10-console-messages.conf"
    echo "Install new ${__sysctl} to limit kernel console logging"    
    echo "Files that control kernel.printk under /etc/sysctl.d:"
    grep "kernel.printk" /etc/sysctl.d/*

    backup_file "${__sysctl}"
    cat << EOF > "${__sysctl}"
# https://www.kernel.org/doc/html/latest/core-api/printk-basics.html
# make kernel console quiet:
kernel.printk = 0 4 0 7
EOF

    chown -v root:root "${__sysctl}"
    chmod -v 644 "${__sysctl}"

    f_postamble "${FUNCNAME[0]}" 
}


function i915_grub_modeset() {
    f_preamble "${FUNCNAME[0]}"
    echo "Add i915.modeset=1 to /etc/default/grub when on Intel HD graphics (i915drmfb)"

    backup_file /etc/default/grub
    
    ## https://retropie.org.uk/forum/topic/18810/retropie-installation-on-ubuntu-server-x64-18-04-1/161
    __kopt="i915.modeset=1"

    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*/& ${__kopt}/" /etc/default/grub
    update-grub
    grep "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub

    f_postamble "${FUNCNAME[0]}"
}

function i915_enable_metrics_discovery() {
    f_preamble "${FUNCNAME[0]}"
    echo "Set dev.i915.perf_stream_paranoid=0 sysctl to enable Intel Metrics discovery"
    echo "API to get rid of warning: MESA-INTEL: warning: Performance support disabled"
    echo "in /dev/shm/runcommand.log when running on Intel HD graphics fb (i915drmfb)."
    
    __SYSCTL_FILE=/etc/sysctl.d/60-i915-mdapi.conf
    __CURDIR="$(pwd)"
    echo "-> Writing $__SYSCTL_FILE (dev.i915.perf_stream_paranoid=0)"
    echo "dev.i915.perf_stream_paranoid=0" > "${__SYSCTL_FILE}"
    chown -v root:root "${__SYSCTL_FILE}"
    chmod -v 644 "${__SYSCTL_FILE}" ; #rw-r--r--

    ## NOTE: writing dev.915... sysctl on non i915 chipset will fail
    echo "installing Intel(R) Metrics Discovery Application Programming Interface"
    #sysctl -w dev.i915.perf_stream_paranoid=0
    mkdir -vp "${USER_HOME}/source"
    if [ -d "${USER_HOME}/source/metrics-discovery" ]; then
	rm -rf "${USER_HOME}/source/metrics-discovery"
    fi
    git clone https://github.com/intel/metrics-discovery "${USER_HOME}/source/metrics-discovery"
    mkdir -v "${USER_HOME}/source/metrics-discovery/build"
    cd "${USER_HOME}/source/metrics-discovery/build"

    echo "Install additional dependencies (see ${APT_LOG})..."
    apt-get -y install cmake g++ default-libmysqlclient-dev dpkg-dev >> "${APT_LOG}"
    
    cmake ..
    make -j"$(nproc)" && make install && make package 
    cd "${__CURDIR}"

    f_postamble "${FUNCNAME[0]}"
}

function repair_permissions() {
    f_preamble "${FUNCNAME[0]}"
    echo "Fix file/folder permissions under ${USER_HOME} (making ${USER} owner of files/dirs)"
    chown -R "${USER}:${USER}" "${USER_HOME}/"
    f_postamble "${FUNCNAME[0]}"
}

function remove_unneeded_packages() {
    f_preamble "${FUNCNAME[0]}"
    echo "Autoremoving any unneeded packages (apt -y autoremove)"
    
    apt-get update && apt-get -y upgrade  >> "${APT_LOG}"
    apt-get -y autoremove  >> "${APT_LOG}"

    f_postamble "${FUNCNAME[0]}"
}

# Final message to user
function complete_install() {
    local __tmsg
    RUNTIME=$SECONDS
    if [ "${__default_session_type}" = "x11" ]; then
	__tmsg=" (X configured for ${__xx}x${__xy})"
    fi
	
    echo "+-------------------------------------------------------------------------------"
    echo "| Installation completed: ${__default_session_type} using ${__fb} @ ${__xres}x${__yres}${__tmsg} 👍 🕹 "
    echo "|"
    echo "| Important configuration files created by config:"
    echo "| - ${USER_HOME}/.profile"
    echo "| - ${USER_HOME}/.config/sway/config"    
    echo "| - ${USER_HOME}/.config/i3/config"
    echo "| - /etc/X11/xorg.conf"        
    echo "|"
    echo "| Runtime: $((RUNTIME / 60)) minutes and $((RUNTIME % 60)) seconds"
    echo "| Output has been logged to '$LOG_FILE'"
    echo "+-------------------------------------------------------------------------------"
}

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


if [[ -z "$1" ]]; then
    # ... get package etc. in place
    update_mesa
    install_dependencies
    util_get_fb_type   

    # ... massage OS to our liking
    set_resolution_grub
    hide_boot_messages
    set_kernel_video_option
    disable_sudo_password
    enable_runlevel_multiuser
    enable_autologin_tty
    update_timezone
    unrestrict_dmesg
    silence_kernel_console
    fix_quirks

    if [ "${__fb}" == "i915drmfb" ]; then
	i915_grub_modeset
	i915_enable_metrics_discovery
    fi
    
    # ...set X/i3 and Wayland/Sway configs
    write_sway_conf
    write_xorg_conf
    write_xsession
    write_i3_config
    write_bash_profile
    
    # ...
    remove_unneeded_packages

# If function names are provided as arguments, just run those functions
else
    for call_function in "$@"; do
        $call_function
    done
fi

# ... restore perms and clean up
repair_permissions    
complete_install
