#!/bin/bash
#
# Backup binlog files using mysqlbinlog 5.6
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear

set -o pipefail

# Initial values

lockFile="/var/lock/binlog-pull.lock"
errorFile="/var/log/mysql/pull-binlogs.err"
logFile="/var/log/mysql/pull-binlogs.log"
retention=30 # Retention in days
mysqlUser=root
mysqlPort=3306
mysqlPassword=""
remoteHost=localhost
binPrefix="mysql-bin"
backupPath="/root/backups"
respawn=3 # How many attempts to restart the mysqlbinlog process try
email="root@localhost"

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
	local latest=$(ls -1 $backupPath | grep $binPrefix | tail -1)
        rm -f $lockFile $errorFile
	
}

# Setting TRAP in order to capture SIG and cleanup things
trap destructor EXIT INT TERM

function verifyExecution () {
        local exitCode="$1"
        local mustDie=${3-:"false"}
        if [ $exitCode -ne "0" ]
        then
                msg="[ERROR] Failed execution. ${2}"
                echo "$msg" >> ${errorFile}
                if [ "$mustDie" == "true" ]; then
                        exit 1
                else
                        return 1
                fi
        fi
        return 0
}

function setLockFile () {
	pidmbl=$(pidof mysqlbinlog)
        if [[ -e "$lockFile"  || ! -z "$pidmbl" ]]; then
                trap - EXIT INT TERM
                verifyExecution "1" "Script already running. $lockFile exists or mysqlbinlog is already running. $pidmbl"
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

function getBinlogSize () {
	binlogSize=$(mysql -u${mysqlUser} --password=${mysqlPassword} -h${remoteHost} --port=${mysqlPort} -N -e"show variables like 'max_binlog_size'" 2> /dev/null | awk '{print $2}' 2>&1)
	verifyExecution "$?"  "Error getting max_binlog_size $out"

	if [ -z "$binlogSize" ]; then
		binlogSize=1024
		logInfo "[Warning] Cannot get max_binlog_size value, instead 1024 Bytes used"
		return
	fi

	logInfo "[OK] max_binlog_size obtained: $binlogSize"
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
        local first=$(mysql -u${mysqlUser} --password=${mysqlPassword} -h${remoteHost} --port=${mysqlPort} -N -e"show binary logs" 2> /dev/null | head -n1 | awk '{print $1}')
        echo $first
}

function findLatestBinlog () {
        pushd $backupPath &> /dev/null
        verifyExecution "$?"  "Backup path $backupPath does not exists" true

        local latest=$(ls -1 | grep $binPrefix | tail -1)
	msg="[OK] Found latest backup binlog: $latest"
        if [ -z "$latest" ]; then
                latest=$(findFirstBinlog)
		msg="[Warning] No binlog file founded on backup directory (${backupPath}). Using instead $latest as first file (obtained from SHOW BINARY LOGS)"
        fi
	logInfo "$msg"
        popd &>/dev/null
	latest=${latest%%.gz}
	echo "$latest"
}

function pullBinlogs () {
        firstBinlogFile=$(findLatestBinlog)
	pushd $backupPath &> /dev/null
	
	out=$(mysqlbinlog --raw --read-from-remote-server --stop-never --verify-binlog-checksum --user=${mysqlUser} --password=${mysqlPassword} --host=${remoteHost} --port=${mysqlPort} --stop-never-slave-server-id=54060 $firstBinlogFile 2>&1) &
	verifyExecution "$?"  "Error while launching mysqlbinlog utility. $out"
	pidMysqlbinlog=$(pidof mysqlbinlog)
	logInfo "[OK] Launched mysqlbinlog utility. Backup running: mysqlbinlog --raw --read-from-remote-server --stop-never --verify-binlog-checksum --user=${mysqlUser} --password=XXXXX --host=${remoteHost} --port=${mysqlPort} --stop-never-slave-server-id=54060 $firstBinlogFile"

	popd &>/dev/null
}

function rotateBackups () {
        
	out=$(find $backupPath -type f -name "${binPrefix}*" -mtime +${retention} -print | xargs /bin/rm 2>&1)
	es=$?
	if [ "$es" -ne 123 ]; then
		verifyExecution "$es" "Error while removing old backups. $out" true
	fi
	
}

function compressBinlogs () {
	
	pushd $backupPath &> /dev/null
	local now=$(date +%s)
	local skipFirst=1

	for i in $(ls -1t | grep $binPrefix | grep -v ".gz"); do
		if [ $skipFirst -eq 1 ]; then
			skipFirst=0
			continue;
		fi
		local created=$(stat -c %Y $i)
		local diff=$(($now-$created))
		local size=$(du -b $i | awk '{print $1}')

		if [[ $size -ge $binlogSize || $diff -gt 300 ]]; then
			out=$(gzip $i 2>&1)
			verifyExecution "$?" "Error compressing binlog file ${i}. $out" true
		fi
	done

	popd &>/dev/null

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

		compressBinlogs
		rotateBackups

		sleep 30;
	done

}

setLockFile
verifyMysqlbinlog
getBinlogSize
pullBinlogs
verifyAllRunning
