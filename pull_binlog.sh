#!/bin/bash
#
# Backup binlog files using mysqlbinlog 5.6
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear
# Initial values

lockFile="/var/lock/binlog-pull.lock"
errorFile="/var/log/mysql/pull-binlogs.err"
logFile="/var/log/mysql/pull-binlogs.log"
retention=30 # Retention in days
mysqlUser=root
mysqlPort=3306
remoteHost=192.168.1.105
binPrefix="mysql-bin"
backupPath="/root/"
respawn=3 # How many attempts to restart the mysqlbinlog process try
email="daniel.guzman.burgos@percona.com"

# Function definitions

function sendAlert () {
        if [ -e "$errorFile" ]
        then
                alertMsg=$(cat $errorFile)
                echo -e "${alertMsg}" | mailx -s "[$HOSTNAME] ALERT binlog backups" "${email}"
        fi
}

function destructor () {
        sendAlert
        rm -f "$lockFile" #"$errorFile"
}

# Setting TRAP in order to capture SIG and cleanup things
trap destructor EXIT INT TERM

function verifyExecution () {
        local exitCode="$1"
        local mustDie=${3-:"false"}
        if [ $exitCode -ne "0" ]
        then
                msg="[ERROR] Failed execution. ${2}"
                echo "$msg" >> ${errorfile}
                if [ "$mustDie" == "true" ]; then
                        exit 1
                else
                        return 1
                fi
        fi
        return 0
}

function setLockFile () {
        if [ -e "$lockFile" ]; then
                trap - EXIT INT TERM
                verifyExecution "1" "Script already running. $lockFile exists"
                sendAlert
                rm -f "$errorFile"
                exit 2
        else
                touch "$lockFile"
        fi
}

function logInfo (){

        echo "[$(date +%y%m%d-%H:%M:%S)] $1" >> $logFile
}

function verifyMysqlbinlog () {

        which mysqlbinlog &> /dev/null
        verifyExecution "$?"  "Cannot find mysqlbinlog tool" true
        logInfo "[OK] Found 'mysqlbinlog' utility"

        haveRaw=$(mysqlbinlog --help | grep "\--raw")
        if [ -z "$haveRaw" ]
        then
                verifyExecution "1" "Incorrect mysqlbinlog version. Needs 5.6 version with --raw parameter" true
        fi
        logInfo "[OK] Verified mysqlbinlog utility version"
}

function findFirstBinlog () {
        local first=$(mysql -u${mysqlUser} -h${remoteHost} --port=${mysqlPort} -N -e"show binary logs" | head -n1 | awk '{print $1}')
        echo $first
}

function findLatestBinlog () {
        pushd $backupPath &> /dev/null
        verifyExecution "$?"  "Backup path $backupPath does not exists" true

        local latest=$(ls -1 | grep $binPrefix | tail -1)
	msg="[OK] Found latest backupe binlog: $latest"
        if [ -z "$latest" ]; then
                latest=$(findFirstBinlog)
		msg="[Warning] No binlog file founded on backup directory (${backupPath}). Using instead $latest as first file"
        fi
	logInfo "$msg"
        popd &>/dev/null
	echo $latest
}

function pullBinlogs () {

        firstBinlogFile=$(findLatestBinlog)
	
	pushd $backupPath &> /dev/null
	
	out=$(mysqlbinlog --raw --read-from-remote-server --stop-never --verify-binlog-checksum --user=${mysqlUser} --host=${remoteHost} --port=${mysqlPort} --stop-never-slave-server-id=54060 $firstBinlogFile 2>&1) &
	verifyExecution "$?"  "Error while launching mysqlbinlog utility. $out"
	pidMysqlbinlog=$(pidof mysqlbinlog)
	logInfo "[OK] Launched mysqlbinlog utility. Backup running"

	popd &>/dev/null
}

function rotateBackups () {
        
	find $backupPath -type f -name "${binPrefix}*" -mtime +30 -print | xargs /bin/rm
	
}

function verifyAllRunning () {

	local tryThisTimes=$(echo $respawn)
	while true; do
		if [ ! -d /proc/$pidMysqlbinlog ]; then
			logInfo "[ERROR] mysqlbinlog stopped. Attempting a restart .... "
			pullBinlogs
			tryThisTimes=$(($tryThisTimes-1))
			if [ $tryThisTimes -eq 0 ]; then
				verifyExecution "1"  "Error while restarting mysqlbinlog utility after $respawn attempts. Terminating the script" true
			fi
		fi
		sleep 30;
	done

}

verifyMysqlbinlog
pullBinlogs

verifyAllRunning
