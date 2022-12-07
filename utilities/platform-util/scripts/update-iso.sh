#!/bin/bash
#
# Copyright (c) 2019-2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
#############################################################################
#
# Utility for updating a starlingX Debian ISO
#
# This utility supports the following update options:
#
# 1. Add a custom kickstart post addon script to the root directory
#    of the ISO, allowing the user to add some custom configuration,
#    such as custom network interface config.
#
# 2. Add or modify installation boot parameters, such as changing
#    the default install storage device.
#    Note: Recommend using by-path notation for storage device names.
#    Note: Added or modified boot parameters must be delimited by '='
#          For example: <some_boot_parm>=<some_boot_value>
#
# 3. Modify the default USB install type ; Standard Controller or
#    either standard or realtime kernel for All-In-One install type
#    with graphical or serial output modes.
#
# 4. Clear the default USB install type with -d|--default NULL.
#    Note: This will clear the default timeout ; set to no timeout.
#
#############################################################################

export GUESTMOUNT_POINT="/dev/sda1"

# Source shared utility functions
source "$(dirname "$0")/stx-iso-utils.sh"

# add new line before tool output
echo ""

function usage {
    cat <<ENDUSAGE
    Usage:

    $(basename "$0")
        -i|--input '/path/to/input/<bootimage>.iso'
        -o|--output '/path/to/output/<bootimage>.iso'

    Options:

        -a|--addon '/path/to/<ks-addon>.cfg
        -p|--param param=value
        -d|--default <default menu option>
        -t|--timeout <menu timeout>
        -m|--mount <guestmount point>
        -v|--verbose
        -h|--help

    Descriptions:

        -i <path/file>: Specify input ISO file
        -o <path/file>: Specify output ISO file
        -a <path/file>: Specify ks-addon.cfg file
        -p <p=v>:  Specify boot parameter

            Example:
            -p instdev=/dev/disk/by-path/pci-0000:00:0d.0-ata-1.0

        -d <default menu option>:
            Specify default boot menu option:
            0 - Standard Controller, Serial Console
            1 - Standard Controller, Graphical Console
            2 - AIO, Serial Console
            3 - AIO, Graphical Console
            4 - AIO Low-latency, Serial Console
            5 - AIO Low-latency, Graphical Console
            NULL - Clear default selection (default:0 ; no timeout)

        -m <guestmount point>
            default: /dev/sda1
                Note: applies to runs without sudo
                Note: See https://libguestfs.org/guestmount.1.html

        -t <menu timeout>:
                Specify boot menu timeout, in seconds

        -v      Verbose mode
        -h      Display this help

Kickstart Addon Example:
    What: Define a VLAN on initial OAM interface setup:
    How : Create and pass a file containing the following
          kind of code using the -a <filename> option.

#### start ks-addon.cfg
OAM_DEV=enp0s3
OAM_VLAN=1234

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-\$OAM_DEV
DEVICE=\$OAM_DEV
BOOTPROTO=none
ONBOOT=yes
LINKDELAY=20
EOF

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-\$OAM_DEV.\$OAM_VLAN
DEVICE=\$OAM_DEV.\$OAM_VLAN
BOOTPROTO=dhcp
ONBOOT=yes
VLAN=yes
LINKDELAY=20
EOF
#### end ks-addon.cfg

ENDUSAGE
    exit 0
}

function cleanup {
    common_cleanup
}

function check_requirements {
    common_check_requirements
}

function set_default_label {
    local isodir="$1"

    ilog "updating default menu selection to ${DEFAULT_GRUB_ENTRY}"

    if [ -z "${EFI_MOUNT}" ]; then
        mount_efiboot_img "${isodir}"
    fi

    # Note: This 'for' loop is not necessary but is intentionally maintained
    #       after the port from centos to debian where the second file was
    #       removed. Keeping the 'for' loop to minimize change and make it
    #       easy to add another file in the future if needed.
    for f in "${isodir}"/isolinux/isolinux.cfg; do
        if [ "${DEFAULT_LABEL}" = "NULL" ]; then
            # Remove default, if set
            grep -q '^default' "${f}"
            if [ $? -eq 0 ]; then
                sed -i '/^default/d' "${f}"
            fi
        else
            # Need to increment this value by 1 for the isolinux (BIOS) case.
            # This is because LAT starts the isolinux grub menu at 1 rather than 0.
            # Doing this avoids a customer visable menu selection numbering change.
            DEFAULT_LABEL=$((DEFAULT_LABEL+1))
            grep -q '^default' "${f}"
            if [ $? -ne 0 ]; then
                cat <<EOF >> "${f}"

default ${DEFAULT_LABEL}
EOF
            else
                sed -i "s/^default.*/default ${DEFAULT_LABEL}/" "${f}"
            fi

            # The Debian isolinux grub menus from LAT have a 'ontimoeout
            # setting that gets defaulted to 1=Controller Install. This
            # setting needs to be update as well.
            grep -q '^ontimeout' "${f}"
            if [ $? -eq 0 ]; then
                ilog "updating ontimeout label to ${DEFAULT_GRUB_ENTRY}"
                sed -i "s/^ontimeout.*/ontimeout ${DEFAULT_LABEL}/" "${f}"
            fi
        fi
    done

    for f in ${isodir}/EFI/BOOT/grub.cfg ${EFI_MOUNT}/EFI/BOOT/grub.cfg; do
        sed -i "s/^set default=.*/set default=\"${DEFAULT_GRUB_ENTRY}\"/" "${f}"
        # Now update the other cases that LAT adds to the grub file that
        # will override the above case if not dealt with similarly
        sed -i "s/^    set default=.*/    set default=\"${DEFAULT_GRUB_ENTRY}\"/" "${f}"
        sed -i "s/^      set default=.*/      set default=\"${DEFAULT_GRUB_ENTRY}\"/" "${f}"

    done
}

function set_timeout {
    local isodir="$1"

    ilog "updating default menu timeout to ${GRUB_TIMEOUT} secs"

    if [ -z "${EFI_MOUNT}" ]; then
        mount_efiboot_img "${isodir}"
    fi

    for f in "${isodir}"/isolinux/isolinux.cfg; do
        sed -i "s/^TIMEOUT.*/TIMEOUT ${TIMEOUT}/" "${f}"
    done

    for f in ${isodir}/EFI/BOOT/grub.cfg ${EFI_MOUNT}/EFI/BOOT/grub.cfg; do
        sed -i "s/^set timeout=.*/set timeout=${GRUB_TIMEOUT}/" "${f}"

        grep -q "^  set timeout=" "${f}"
        if [ $? -eq 0 ]; then
            # Submenu timeout is already added. Update the value
            sed -i -e "s#^  set timeout=.*#  set timeout=${GRUB_TIMEOUT}#" "${f}"
            if [ $? -ne 0 ]; then
                elog "Failed to update grub timeout"
            fi
        else
            # Parameter doesn't exist. Add it to the cmdline
            sed -i -e "/^submenu/a \ \ set timeout=${GRUB_TIMEOUT}" "${f}"
            if [ $? -ne 0 ]; then
                elog "Failed to add grub timeout"
            fi
        fi
    done
}

# print usage when there are no arguements provided
[ "${*}" == "" ] && usage

declare INPUT_ISO=
declare OUTPUT_ISO=
declare ADDON=
declare -a PARAMS
declare DEFAULT_LABEL=
declare DEFAULT_GRUB_ENTRY=
declare UPDATE_TIMEOUT="no"
declare -i TIMEOUT=0
declare GRUB_TIMEOUT=-1
declare VERBOSE=false

script=$(basename "$0")
OPTS=$(getopt -o a:d:hi:m:o:p:t:v \
                --long addon:,default:,help,input:,mount:,output:,param:,timeout:,verbose \
                -n "${script}" -- "$@")
if [ $? != 0 ]; then
    echo "Failed parsing options." >&2
    usage
fi

eval set -- "$OPTS"
while true; do
    [ ${VERBOSE} = true ] && ilog "Parsing Option: $1 $2"
    case "$1" in

        -v|--verbose)
            VERBOSE=true
            shift 1
            ;;
        -h|--help)
            usage
            shift 1
            ;;
        -i|--input)
            INPUT_ISO="${2}"
            shift 2
            ;;
        -m|--mount)
            GUESTMOUNT_POINT="${2}"
            shift 2
            ;;
        -o|--output)
            OUTPUT_ISO="${2}"
            shift 2
            ;;
        -a|--addon)
            ADDON="${2}"
            shift 2
            ;;
        -p|--param)
            PARAMS+=( "${2}" )
            shift 2
            ;;
        -d|--default)
            DEFAULT_LABEL=${2}
            case ${DEFAULT_LABEL} in
                0)
                    DEFAULT_GRUB_ENTRY="standard>serial"
                    ;;
                1)
                    DEFAULT_GRUB_ENTRY="standard>graphical"
                    ;;
                2)
                    DEFAULT_GRUB_ENTRY="aio>serial"
                    ;;
                3)
                    DEFAULT_GRUB_ENTRY="aio>graphical"
                    ;;
                4)
                    DEFAULT_GRUB_ENTRY="aio-lowlat>serial"
                    ;;
                5)
                    DEFAULT_GRUB_ENTRY="aio-lowlat>graphical"
                    ;;
                'NULL')
                    DEFAULT_GRUB_ENTRY="standard>serial"
                    ;;
                *)
                    msg_info="Invalid default boot menu option"
                    msg_help="needs to be value from 0..5 ; see --help screen"
                    elog "${msg_info}: ${DEFAULT_LABEL} ; ${msg_help}" >&2
                    ;;
            esac
            shift 2
            ;;
        -t|--timeout)
            declare -i timeout_arg=${2}
            if [ "${timeout_arg}" -gt 0 ]; then
                (( TIMEOUT=timeout_arg*10 ))
                GRUB_TIMEOUT=${timeout_arg}
            elif [ "${timeout_arg}" -eq 0 ]; then
                GRUB_TIMEOUT=0.001
            fi

            UPDATE_TIMEOUT="yes"
            shift 2
            ;;
        --)
            break
            ;;
    esac
done

if [ "${DEFAULT_LABEL}" = "NULL" ]; then
    # Reset timeouts to default
    TIMEOUT=0
    GRUB_TIMEOUT=-1
    UPDATE_TIMEOUT="yes"
fi

[ $UID -ne 0 ] && ilog "guest mode ; ${GUESTMOUNT_POINT} must have virtual support"

check_requirements

check_required_param "-i" "${INPUT_ISO}"
check_required_param "-o" "${OUTPUT_ISO}"

if [ ! -f "${INPUT_ISO}" ]; then
    elog "Input file does not exist: ${INPUT_ISO}"
fi

if [ -f "${OUTPUT_ISO}" ]; then
    elog "Output file already exists: ${OUTPUT_ISO}"
fi

trap cleanup EXIT

BUILDDIR=$(mktemp -d -p "$PWD" updateiso_build_XXXXXX)
if [ -z "${BUILDDIR}" ] || [ ! -d "${BUILDDIR}" ]; then
    elog "Failed to create mount temp dir. Aborting..."
fi

mount_iso "${INPUT_ISO}" "${PWD}" "${GUESTMOUNT_POINT}"

ilog "rsync mounted content to ${BUILDDIR}"
rsync -a "${MNTDIR}/" "${BUILDDIR}/"
rc=$?
[ ${rc} -ne 0 ] && elog "rsync ISO content failed rc=${rc}. Aborting..."

unmount_iso

if [ ${#PARAMS[@]} -gt 0 ]; then
    for p in "${PARAMS[@]}"; do
        param=${p%%=*} # Strip from the first '=' on
        value=${p#*=}  # Strip to the first '='

        update_parameter "${BUILDDIR}" "${param}" "${value}"
    done
fi

if [ -n "${DEFAULT_LABEL}" ]; then
    set_default_label "${BUILDDIR}"
fi

if [ "${UPDATE_TIMEOUT}" = "yes" ]; then
    set_timeout "${BUILDDIR}"
fi

if [ -n "${ADDON}" ]; then
    ilog "adding ${ADDON} to ${BUILDDIR}/ks-addon.cfg"
    rm -f "${BUILDDIR}"/ks-addon.cfg
    cp "${ADDON}" "${BUILDDIR}"/ks-addon.cfg
    if [ $? -ne 0 ]; then
        elog "Failed to copy ${ADDON}"
    fi
fi

unmount_efiboot_img

ilog "making iso filesystem with mkisofs in ${OUTPUT_ISO}"

# get the install label
ISO_LABEL=$(grep -ri instiso "${BUILDDIR}"/isolinux/isolinux.cfg | head -1 | xargs -n1 | awk -F= /instiso/'{print $2}')
if [ -z "${ISO_LABEL}" ] ; then
    elog "Failed to get iso install label"
fi
vlog "ISO Label: ${ISO_LABEL}"

# Needs to be writable for mkisofs
[ ! -w "${BUILDDIR}/isolinux/isolinux.bin" ] && chmod 644 "${BUILDDIR}/isolinux/isolinux.bin"
mkisofs -o "${OUTPUT_ISO}" \
        -A "${ISO_LABEL}" -V "${ISO_LABEL}" \
        -quiet -U -J -joliet-long -r -iso-level 2 \
        -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot \
        -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e efi.img -no-emul-boot \
        "${BUILDDIR}"

if [ -e "${OUTPUT_ISO}" ] ; then
    if [ "${VERBOSE}" = true ] ; then
        isohybrid --uefi "${OUTPUT_ISO}"
    else
        isohybrid --uefi "${OUTPUT_ISO}" >&/dev/null
    fi

    if [ "${VERBOSE}" = true ] ; then
        implantisomd5 "${OUTPUT_ISO}"
    else
        implantisomd5 "${OUTPUT_ISO}" >&/dev/null
    fi
    rc=$?
    size=$(ls -lh "${OUTPUT_ISO}" | awk -F " " {'print $5'})
    ilog "created new ${size} iso ${OUTPUT_ISO} with requested updates"
    exit ${rc}
else
    elog "Failed to create ${OUTPUT_ISO}"
fi
