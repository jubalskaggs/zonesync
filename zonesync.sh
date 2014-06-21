#!/bin/sh
##############################################################################
#
# This script is distributed under the MIT licence 
#
# Copyright (c) 2009 Sjaak Westdijk (slx86)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
# 
# Name: zonesync.sh
# 
# Task: syncing zone between 2 systems for cold standby
#
# Author: Sjaak Westdijk
#
# Date: 22-04-2009
#
# Last Change: 23-04-2009
#
# Description: This script syncs a zone that lives on a zfs filesystem to 
#					an other system for COLD standby usage. First it sync's the 
#					whole zfs volume of the zone to the other system, afterwards
#					the zone is created. All other runs only sync's the zfs delta.
#
# TODO: 
# 
##############################################################################
#trap 'exit_error' ERR
#set -e

##############################################################################
#
#  Static variables
#
##############################################################################
VERSION=1.0
SUCCES=0
FAILURE=1
ZFS="/usr/sbin/zfs"
ZONEADM="/usr/sbin/zoneadm"
ZONECFG="/usr/sbin/zonecfg"
DETACHFILE="SUNWdetached.xml"
SSH="/usr/bin/ssh -q"
SCP="/usr/bin/scp -q"

##############################################################################
#
#  Global variables
#
##############################################################################
ERR=""
ZPATH=""
FS=""
PREVSNAP=""
CURSNAP=""

##############################################################################
#
# Name: Error
#
# Task: Print error message and quit
#
##############################################################################
exit_error() {
	RC=$?
	echo "$1 ${RC}"
	exit ${RC}
}

##############################################################################
#
# Name: CheckZone
#
# Task: check if zone exists and lives on zfs
#
##############################################################################
CheckZone() {
	ZNE=""
	LFS=""

	echo "Checking zone $1: \c"
	ZNE=`${ZONEADM} list -vi | grep $1`
	if [ "${ZNE}" != "" ]; then
		ZPATH=`echo ${ZNE} | awk '{print $4}'`
		FS=`${ZFS} list | grep ${ZPATH} | awk '{print $1}'`
		if [ "${FS}" = "" ]; then
			exit_error "ERROR: zone $1 does not live on zfs"
		fi
	else
		exit_error "ERROR: zone $1 does not exists"
	fi
	echo "OK"
}

##############################################################################
#
# Name: GetSnapShot
#
# Task: Get the current snapshot
#
##############################################################################
GetSnapShot() {
	echo "Getting snaphot for volume $1: \c"
	PREVSNAP=`${ZFS} list -rH -o name -t snapshot $1` || \
										exit_error "Error getting previous snapshot"
	echo "OK"
}

##############################################################################
#
# Name: CreateSnapShot
#
# Task: Create a snapshot of the zfs volume
#
##############################################################################
CreateSnapShot() {
	DATE=""

	echo "Creating snaphot of volume $1: \c"
	DATE=`date '+%Y%m%d%H%M'`
	${ZFS} snapshot $1@repl${DATE} || \
								exit_error "Error creating snapshot $1@repl${DATE}"
	CURSNAP="$1@repl${DATE}"
	echo "OK"
}

##############################################################################
#
# Name: RemoveSnaphot
#
# Task: Create a snapshot of the zfs volume
#
##############################################################################
RemoveSnapshot() {
	echo "Removing remote previous snapshot: \c"
	${SSH} ${REMOTEHOST} ${ZFS} destroy $1 || \
										exit_error "Error removing remote snapshot $1"
	echo "OK"
	${ZFS} destroy $1 || exit_error "Error removing local snapshot $1"
	echo "OK"
}

##############################################################################
#
# Name: CheckRemote
#
# Task: Check for remore filesystem or snapshot
#
##############################################################################
CheckRemote() {
	LST=""

	if [ "$2" = "snapshot" ]; then
		echo "Checking for remote snapshot $1: \c"
		LST=`${SSH} ${REMOTEHOST} ${ZFS} list -rH -o name -t snapshot` || \
									exit_error "Error checking remote ${REMOTEHOST}"
	else			
		echo "Checking for remote filesystem $1: \c"
		LST=`${SSH} ${REMOTEHOST} ${ZFS} list -rH -o name` || \
									exit_error "Error checking remote ${REMOTEHOST}"
	fi
	for i in ${LST}
	do
		if [ "$i" = "$1" ]; then
			RFS=$i
		fi
	done
	echo "OK"
}

##############################################################################
#
# Name: SendFull
#
# Task: Send full filesystem to remote
#
##############################################################################
SendFull() {
	RFS=""

	CheckRemote $1 fs
	if [ "$RFS" != "" ]; then
		exit_error "ERROR: Filestystem $1 already exists, delta should run"
	else
		echo "Sending complete filesystem $1: \c"
		${ZFS} send ${CURSNAP} | ${SSH} ${REMOTEHOST} "${ZFS} recv $1" || \
								exit_error "ERROR: Failure in sending filesystem $1" 
		echo "OK"
	fi
}

##############################################################################
#
# Name: SendDelta
#
# Task: Send delta filesystem to remote
#
##############################################################################
SendDelta() {
	RFS=""

	CheckRemote ${PREVSNAP} snapshot
	if [ "$RFS" = "" ]; then
		exit_error "ERROR: Snapshot already exists, fix it manually"
	else
		echo "Sending delta for filesystem $1: \c"
		${ZFS} send -i ${PREVSNAP} ${CURSNAP} | \
	  					${SSH} ${REMOTEHOST} "${ZFS} recv -Fd $1" || \
						exit_error "ERROR: Sending delta failure for filesystem $1"
	fi
	echo "OK"
}

##############################################################################
#
# Name: ConfigRemZone
#
# Task: Export the zone config and install it remote
#
##############################################################################
ConfigRemZone() {
	echo "Config zone on remote system $1: \c"
	${ZONEADM} -z $1 detach -n > /tmp/${DETACHFILE} || \
									exit_error "ERROR: could not create ${DETACHFILE}"
	${SCP} /tmp/${DETACHFILE} ${REMOTEHOST}:${ZPATH} > /dev/null 2>&1 || \
					exit_error "ERROR: Write ${DETACHFILE} to remote host failed"
	rm /tmp/${DETACHFILE}
	${SSH} ${REMOTEHOST} ${ZONECFG} -z $1 create -a ${ZPATH} || \
								exit_error "ERROR: failed to create remote zone $1"
	${SSH} ${REMOTEHOST} ${ZONEADM} -z $1 attach || \
								exit_error "ERROR: failed to attach remote zone $1"
	${SSH} ${REMOTEHOST} ${ZONECFG} -z $1 set autoboot=false || \
								exit_error "ERROR: failed to disbable autoboot $1"
	echo "OK"
}


##############################################################################
#
# Name: Main
#
# Task: Main function of this script 
#
##############################################################################
if [ $# -ne 2 ];then
	echo "Usage : zonesync.sh <zone> <remotehost>"
	exit
fi
echo "zonesync.sh version ${VERSION}"

ZONE=$1
REMOTEHOST=$2

CheckZone $1
GetSnapShot ${FS}
CreateSnapShot ${FS}

if [ "${PREVSNAP}" = "" ];then
	SendFull ${FS}
	ConfigRemZone ${ZONE}
else
	if [ "$CURSNAP" = "" ]; then 
		exit_error ="ERROR: Internal error, snapshot should exists"
	else
		SendDelta ${FS}
		RemoveSnapshot ${PREVSNAP} 
	fi
fi

echo "Done"
exit 0

##############################################################################
#
# End of Script
#
##############################################################################
