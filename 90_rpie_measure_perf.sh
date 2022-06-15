#!/bin/bash
set -e

## RetroPie-fy Ubuntu Server install. Part X: Install and run performance tests

##
## computed; don't modify
USER="$SUDO_USER"
USER_HOME="/home/$USER"
LOG_FILE="${USER_HOME}/install-logs/$(basename "$0" .sh)-$(date +"%Y%m%d_%H%M%S").log"
COM_LOG="${USER_HOME}/install-logs/compile-$(date +"%Y%m%d_%H%M%S").log"

##
## Log all console output to logfile ; make sure log dir if writeable as ${USER} as well
mkdir -p "${USER_HOME}/install-logs"
chown "${USER}:${USER}" "${USER_HOME}/install-logs"
sudo -H -u "${USER}" touch "${LOG_FILE}"
exec > >(tee "${LOG_FILE}") 2>&1

cat << EOF
______     _            ______ _        _   _ _                 _         
| ___ \\   | |           | ___ (_)      | | | | |               | |  
| |_/ /___| |_ _ __ ___ | |_/ /_  ___  | | | | |__  _   _ _ __ | |_ _   _ 
|    // _ \\ __| '__/ _ \\|  __/| |/ _ \\ | | | | '_ \\| | | | '_ \\| __| | | |
| |\\ \\  __/ |_| | | (_) | |   | |  __/ | |_| | |_) | |_| | | | | |_| |_| |
\\_| \\_\\___|\\__|_|  \\___/\\_|   |_|\\___|fy\\___/|_.__/ \\__,_|_| |_|\\__|\\__,_|

RetroPie-fy Ubuntu Server install. Part X: install and run performance tests
URL: https://github.com/etheling/retropiefy-ubuntu

This script will perform following actions:
 - Install GeekBench and run CPU and GPU tests
 - Install glslsandbox-player for KMS/X/Wayland performance testing
 - Run disk read/write speed tests using dd
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
	    echo " * Compilation log: ${COM_LOG}"
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



##
## FIXME: Shader benchmark; KMS; Wayland; X
## FIXME: KMS: https://github.com/astefanutti/kms-glsl (WORKS GREAT)
## FIXME: Vulkan shadertoy launcher for X/Wayland: https://github.com/danilw/vulkan-shadertoy-launcher
## FIXME: needs: libxcb-keysyms1-dev
## FIXME: tester for X11 / Wayland: https://github.com/jolivain/glslsandbox-player
##        --> ./configure --with-native-gfx=wl
##        --> sudo apt install libdrm-tests (for modetest)


function install_glslsandbox_player() {

    f_preamble "${FUNCNAME[0]}"
    
    echo "Install https://github.com/jolivain/glslsandbox-player for KMS/X/Wayland perf"
    echo "Compilation log in ${COM_LOG}"
    if [ -d /opt/glslsandbox-player ]; then
	echo "WARNING: /opt/glslsandbox-player exists. Deleting in 5 seconds. CTRL+C to abort."
	sleep 5
	rm -rf /opt/glslsandbox-player
    fi
    
    mkdir -p /opt/glslsandbox-player/src
    mkdir -p /opt/glslsandbox-player/bin

    echo "Installing autoconf and automake..."
    apt-get -y install autoconf automake >> "${COM_LOG}"
    echo "Cloning from https://github.com/jolivain/glslsandbox-player.git"
    git clone https://github.com/jolivain/glslsandbox-player.git /opt/glslsandbox-player/src

    echo "Compiling and installing glslsandbox-player..."
    cd /opt/glslsandbox-player/src
    {
	autoreconf -vfi
	./configure 
	make -j"$(nproc)" 
    } >> "${COM_LOG}" 2>&1
    cp -v src/glslsandbox-player /opt/glslsandbox-player/bin/glslsandbox-player-x11
    
    {
	make clean 
	./configure --with-native-gfx=wl
	make -j"$(nproc)" 
    } >> "${COM_LOG}" 2>&1
    cp -v src/glslsandbox-player /opt/glslsandbox-player/bin/glslsandbox-player-wayland

    {
	make clean
	./configure --with-native-gfx=kms
	make -j"$(nproc)"
    } >> "${COM_LOG}" 2>&1
    cp -v src/glslsandbox-player /opt/glslsandbox-player/bin/glslsandbox-player-kms
    
    chmod -v ugo+x /opt/glslsandbox-player/bin/*

    ## run test
    sudo -H -u "${USER}" /opt/glslsandbox-player/bin/glslsandbox-player-kms -f2000 -r500 -i109
    echo "+ + Reference on AMD AMD Radeon Vega 11 Graphics / OpenGL ES 3.2 Mesa 22.0.1 / ES GLSL ES 3.20: + +"
    echo "from_frame:1500    to_frame:1999    time:16.672  frame_rate:29.990    shadertime=66.796"
    echo ""
    
    echo "Installation completed. '/opt/glslsandbox-player/bin/glslsandbox-player-kms -h' for help:"
    echo " * /opt/glslsandbox-player/bin/glslsandbox-player-kms -l"
    echo " * /opt/glslsandbox-player/bin/glslsandbox-player-kms -f3000 -r500 -i109"
    echo " * /opt/glslsandbox-player/bin/glslsandbox-player-wayland -f3000 -r500 -i110"
    echo " * /opt/glslsandbox-player/bin/glslsandbox-player-x11 -f3000 -r500 -i111"
    
    f_postamble "${FUNCNAME[0]}"
}


function benchmark_disk() {
    f_preamble "${FUNCNAME[0]}"
    echo "Performing disk write benchmark using dd (bs=1024,8192 blocks=524288)"
    dd if=/dev/zero of=./bs1024 bs=1024 count=524288
    rm ./bs1024
    dd if=/dev/zero of=./bs8192 bs=8192 count=524288
    rm ./bs8192
    sync

    echo "+ + + +"
    ## 2022-06-15 on 5.15.0-39-generic
    echo "Reference write speeds (m.2/AMD Ryzen): 476 MB/s (bs=1024), 900 MB/s (bs=8192)"
    
    f_postamble "${FUNCNAME[0]}"    
}

function benchmark_p7zip() {
    f_preamble "${FUNCNAME[0]}"
    echo "Running p7zip benchmark using single CPU only:"
    7z b -mmt1
    
    echo "+ + + + + Reference (AMD Ryzen 5 3400GE @ 3.30 GHz): + + + + +"
    echo "Avr:             100   4062   4062  |              100   3965   3964"
    
    f_postamble "${FUNCNAME[0]}"

}



function install_perf_tools() {
    f_preamble "${FUNCNAME[0]}"
    echo "Apt log in ${COM_LOG}"
    
    apt-get install -y inxi net-tools >> "${COM_LOG}"
    ## performance
    apt-get install -y glmark2 intel-gpu-tools hwinfo kmscube p7zip-full >> "${COM_LOG}"

    f_postamble "${FUNCNAME[0]}"
}

##
GEEKBENCHVER=5.4.5
function get_geekbench5() {
    f_preamble "${FUNCNAME[0]}"
    echo "Get Geekbench 5 from https://www.geekbench.com/download/linux/"    

    local __GEEKBENCHURL
    __GEEKBENCHURL="https://cdn.geekbench.com/Geekbench-${GEEKBENCHVER}-Linux.tar.gz"
    wget -qO "/tmp/Geekbench-${GEEKBENCHVER}-Linux.tar.gz" $__GEEKBENCHURL
    mkdir -vp /opt/geekbench
    if tar zxf "/tmp/Geekbench-${GEEKBENCHVER}-Linux.tar.gz" -C /opt/geekbench; then
	echo "Success. Geekbench ${GEEKBENCHVER} installed to /opt/geekbench/..."
    fi

    f_postamble "${FUNCNAME[0]}"    
}

## echo "| * https://www.basemark.com/benchmarks/basemark-gpu/"
function benchmark_geekbench5() {
    f_preamble "${FUNCNAME[0]}"
    echo "Execute GeekBench5 sysinfo, cpu, compute"

    __GEEKBENCH5DIR="/opt/geekbench/Geekbench-${GEEKBENCHVER}-Linux"
    if [ -f $__GEEKBENCH5DIR/geekbench5 ]; then
	$__GEEKBENCH5DIR/geekbench5 --sysinfo
	$__GEEKBENCH5DIR/geekbench5 --cpu
	$__GEEKBENCH5DIR/geekbench5 --compute Vulkan
    else
	echo "GeekBench 5 not found. Skipping. See logs (install likely failed)"
    fi

    echo "+ + + + + Reference (AMD Ryzen 5 3400GE @ 3.30 GHz): + + + + +"
    echo "CPU single core: 1036, multi: 3461 (https://browser.geekbench.com/v5/cpu/7181649)"
    echo "Compute (Vulkan): 7470 (https://browser.geekbench.com/v5/compute/2614077)"
    
    f_postamble "${FUNCNAME[0]}"

}

function log_system_info() {
    f_preamble "${FUNCNAME[0]}"    
    echo "System information (lspci)"
    lspci
    
    echo "System information (lsusb)"
    lsusb
    
    echo "System information (lshw -short)"
    lshw -short

    echo "System information (inxi -F)"
    inxi -c 0 -F

    echo "Open network ports: netstat -na"
    netstat -nap | grep -E "(Internet|ip|tcp|udp)" | grep -v STREAM

    f_postamble "${FUNCNAME[0]}"
}

function complete_install() {
    local __tmsg
    RUNTIME=$SECONDS
	
    echo "+-------------------------------------------------------------------------------"
    echo "| Completed."
    echo "|"
    echo "| Runtime: $((RUNTIME / 60)) minutes and $((RUNTIME % 60)) seconds"
    echo "| Output has been logged to:"
    echo "| - ${LOG_FILE}"
    echo "| - ${COM_LOG}"    
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
    install_glslsandbox_player
    install_perf_tools
    get_geekbench5

    log_system_info

    benchmark_disk
    benchmark_p7zip
    benchmark_geekbench5
    
    


else
    # If function names are provided as arguments, just run those functions
    for call_function in "$@"; do
        $call_function
    done
fi

complete_install
