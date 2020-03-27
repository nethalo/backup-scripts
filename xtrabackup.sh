#!/bin/bash
#
# Raw Backup MySQL data using Percona XtraBackup tool
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear

set -o pipefail

# Initial values

lockFile="/var/lock/xtrabackup.lock"
errorFile="/var/log/mysql/xtrabackup.err"
logFile="/var/log/mysql/xtrabackup.log"
mysqlUser=root
mysqlPort=3306
backupPath="/root/backups/xtrabackup/$(date +%Y%m%d%H%M%S)/"
# Retention times #
weekly=4
daily=7
######
email="root@localhost"

# Function definitions

function sendAlert () {
        if [ -e "$errorFile" ]
        then
                alertMsg=$(cat $errorFile)
                echo -e "${alertMsg}" | mailx -s "[$HOSTNAME] ALERT XtraBackup backup" "${email}"
        fi
}

function destructor () {
        sendAlert
        rm -f "$lockFile" "$errorFile"
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

function verifyXtrabackup () {
	which xtrabackup &> /dev/null
        verifyExecution "$?" "Cannot find xtrabackup tool" true
        logInfo "[OK] Found 'xtrabackup' bin"

	which innobackupex &> /dev/null
	verifyExecution "$?" "Cannot find innobackupex tool" true
        logInfo "[OK] Found 'innobackupex' bin"
}

function runXtrabackup () {

	verifyXtrabackup

	out=$(innobackupex --user=$mysqlUser --slave-info --safe-slave-backup --parallel=4 --lock-wait-threshold=90 --lock-wait-query-type=all --lock-wait-timeout=300 --kill-long-queries-timeout=40 --kill-long-query-type=all --rsync --no-timestamp $backupPath > $logFile 2>&1)
	verifyExecution "$?" "Problems executing innobackupex. $out" true
	touch $backupPath/unprepared
	logInfo "[OK] Innobackupex OK"
	echo "Finished dump at: $(date "+%Y-%m-%d %H:%M:%S")" > $backupPath/.metadata

	prepareXtrabackup
	return
}

function prepareXtrabackup () {
	
	out=$(innobackupex --apply-log $backupPath > $logFile 2>&1)
	verifyExecution "$?" "Can't prepare backup $backupPath. $out" true
	mv $backupPath/unprepared $backupPath/prepared
        logInfo "[Info] $backupPath prepared"
}

function removeOldBackup () {

	rootPath=$(dirname $backupPath 2>&1)
	verifyExecution "$?" "Couldn't find backup path. $rootPath" true

	pushd $rootPath &> /dev/null
	daysAgo=$(date -d "$daily days ago" +%s)
	weeksAgo=$(date -d "$weekly weeks ago" +%s)
	
	logInfo "[Info] Removing old backups"
	for i in $(ls -1); do
		day=$(cat $rootPath/$i/.metadata | grep Finished | awk -F": " '{print $2}' | awk '{print $1}' 2>&1)
		verifyExecution "$?" "Couldn't find $rootPath/$i/.metadata file. $day"

		backupTs=$(date --date="$day" +%s)

		# Remove weekly backups older than $weekly
                if [ $weeksAgo -gt $backupTs  ]; then
                        out=$(rm -rf $rootPath/$i 2>&1)
			verifyExecution "$?" "Error removing $rootPath/${i}. $out"
                        logInfo "  [OK] Removed $rootPath/$i weekly backup"
                fi
		
		# Do not remove daily backup if its from Sunday
		weekDay=$(date --date="$day" +%u)
		if [ $weekDay -eq 7 ]; then
			continue;
		fi
		
		# Remove daily backups older than $daily
		if [ $daysAgo -gt $backupTs  ]; then
			out=$(rm -rf $rootPath/$i 2>&1)
			verifyExecution "$?" "Error removing $rootPath/${i}. $out"
			logInfo "  [OK] Removed $rootPath/$i daily backup"
		fi

	done
	
	popd &> /dev/null
}

setLockFile
runXtrabackup
removeOldBackup
