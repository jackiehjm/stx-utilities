#!/bin/bash
################################################################################
# Copyright (c) 2013 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
################################################################################
#
### BEGIN INIT INFO
# Provides:          affine-platform
# Required-Start:
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Affine platform
### END INIT INFO

# Define minimal path
PATH=/bin:/usr/bin:/usr/local/bin

LOG_FUNCTIONS=${LOG_FUNCTIONS:-"/etc/init.d/log_functions.sh"}
CPUMAP_FUNCTIONS=${CPUMAP_FUNCTIONS:-"/etc/init.d/cpumap_functions.sh"}
TASK_AFFINITY_FUNCTIONS=${TASK_AFFINITY_FUNCTIONS:-"/etc/init.d/task_affinity_functions.sh"}
source /etc/init.d/functions
[[ -e ${LOG_FUNCTIONS} ]] && source ${LOG_FUNCTIONS}
[[ -e ${CPUMAP_FUNCTIONS} ]] && source ${CPUMAP_FUNCTIONS}
[[ -e ${TASK_AFFINITY_FUNCTIONS} ]] && source ${TASK_AFFINITY_FUNCTIONS}
linkname=$(readlink -n -f $0)
scriptname=$(basename $linkname)

# Enable debug logs
LOG_DEBUG=1

. /etc/platform/platform.conf

################################################################################
# Affine all running tasks to the CPULIST provided in the first parameter.
################################################################################
function affine_tasks {
    local CPULIST=$1
    local PIDLIST
    local RET=0

    # Get number of logical cpus
    N_CPUS=$(cat /proc/cpuinfo 2>/dev/null | \
        awk '/^[pP]rocessor/ { n +=1 } END { print (n>0) ? n : 1}')

    # Calculate platform cores cpumap. Reformat with comma separator every
    # 8 hex characters.
    PLATFORM_COREMASK=$(cpulist_to_cpumap ${CPULIST} ${N_CPUS} | \
        sed ':a;s/\B[0-9A-Fa-f]\{8\}\>/,&/;ta')

    # Set default IRQ affinity
    # NOTE: The following echoes a value to file and redirects the stderr to
    # stdout so that potential errors get captured in the variable ERROR.
    ERROR=$(echo ${PLATFORM_COREMASK} 2>&1 > /proc/irq/default_smp_affinity)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        log_error "Failed to set: ${PLATFORM_COREMASK}" \
                  "/proc/irq/default_smp_affinity, err=${ERROR}"
    fi

    # Affine all PCI/MSI interrupts to platform cores; this overrides
    # irqaffinity boot arg, since that does not handle IRQs for PCI devices
    # on numa nodes that do not intersect with platform cores.
    PCIDEVS=/sys/bus/pci/devices
    declare -a irqs=()
    irqs+=($(cat ${PCIDEVS}/*/irq 2>/dev/null | xargs))
    irqs+=($(ls ${PCIDEVS}/*/msi_irqs 2>/dev/null | grep -E '^[0-9]+$' | xargs))
    # flatten list of irqs, removing duplicates
    irqs=($(echo ${irqs[@]} | tr ' ' '\n' | sort -nu))
    log_debug "Affining all PCI/MSI irqs(${irqs[@]}) with cpus (${CPULIST})"
    for i in ${irqs[@]}; do
        /bin/bash -c "[[ -e /proc/irq/${i} ]] && echo ${CPULIST} > /proc/irq/${i}/smp_affinity_list" 2>/dev/null
    done
    if [[ "$subfunction" == *"worker,lowlatency" ]]; then
        # Affine work queues to platform cores
        ERROR=$(echo ${PLATFORM_COREMASK} 2>&1 > /sys/devices/virtual/workqueue/cpumask)
        RET=$?
        if [ ${RET} -ne 0 ]; then
            log_error "Failed to set: ${PLATFORM_COREMASK}" \
                      "/sys/devices/virtual/workqueue/cpumask, err=${ERROR}"
        fi
        ERROR=$(echo ${PLATFORM_COREMASK} 2>&1 > /sys/bus/workqueue/devices/writeback/cpumask)
        RET=$?
        if [ ${RET} -ne 0 ]; then
            log_error "Failed to set: ${PLATFORM_COREMASK}" \
                      "/sys/bus/workqueue/devices/writeback/cpumask, err=${ERROR}"
        fi

        # On low latency compute reassign the per cpu threads rcuc, ksoftirq,
        # ktimersoftd to FIFO along with the specified priority
        PIDLIST=$( ps -e -p 2 |grep rcuc | awk '{ print $1; }')
        for PID in ${PIDLIST[@]}; do
            chrt -p -f 4 ${PID}  2>/dev/null
        done

        PIDLIST=$( ps -e -p 2 |grep ksoftirq | awk '{ print $1; }')
        for PID in ${PIDLIST[@]}; do
            chrt -p -f 2 ${PID} 2>/dev/null
        done

        PIDLIST=$( ps -e -p 2 |grep ktimersoftd | awk '{ print $1; }')
        for PID in ${PIDLIST[@]}; do
            chrt -p -f 3 ${PID} 2>/dev/null
        done

        # Affine kernel irq/ nvme threads to platform cores
        pidlist=$(ps --ppid 2 -p 2 -o pid=,comm= | grep -E 'irq/.*nvme' | awk '{ print $1; }')
        for pid in ${pidlist[@]}; do
            taskset --all-tasks --pid --cpu-list ${PLATFORM_CPULIST} $pid &> /dev/null
        done

    fi

    return 0
}

################################################################################
# Start Action
################################################################################
function start {
    local RET=0

    echo -n "Starting ${scriptname}: "

    ## Check whether we are root (need root for taskset)
    if [ $UID -ne 0 ]; then
        log_error "require root or sudo"
        RET=1
        return ${RET}
    fi

    ## Define platform cpulist to be thread siblings of core 0
    PLATFORM_CPULIST=$(get_platform_cpu_list)

    # Affine all tasks to platform cpulist
    affine_tasks ${PLATFORM_CPULIST}
    RET=$?
    if [ ${RET} -ne 0 ]; then
        log_error "Failed to affine tasks ${PLATFORM_CPULIST}, rc=${RET}"
        return ${RET}
    fi

    print_status ${RET}
    return ${RET}
}

################################################################################
# Stop Action - don't do anything
################################################################################
function stop {
    local RET=0
    echo -n "Stopping ${scriptname}: "
    print_status ${RET}
    return ${RET}
}

################################################################################
# Restart Action
################################################################################
function restart {
    stop
    start
}

################################################################################
# Main Entry
#
################################################################################
case "$1" in
start)
    start
    ;;
stop)
    stop
    ;;
restart|reload)
    restart
    ;;
status)
    echo -n "OK"
    ;;
*)
    echo $"Usage: $0 {start|stop|restart|reload|status}"
    exit 1
esac

exit $?
