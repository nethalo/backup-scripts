#!/bin/bash
#
# Logic Backup MySQL data using MyDumper tool
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear

set -o pipefail

# Initial values

lockFile="/var/lock/mydumper-pull.lock"
errorFile="/var/log/mysql/mydumper.err"
logFile="/var/log/mysql/mydumper.log"
mysqlUser=root
mysqlPort=3306
#remoteHost=192.168.1.105
remoteHost=localhost
backupPath="/root/backups/$(date +%Y%m%d)/"
numberThreads=4
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
                echo -e "${alertMsg}" | mailx -s "[$HOSTNAME] ALERT MyDumper backups" "${email}"
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

function verifyMysqldump () {
	which mysqldump &> /dev/null
        verifyExecution "$?" "Cannot find mysqldump tool" true
        logInfo "[OK] Found 'mysqldump' bin"
}

function runMysqldump () {
	
	verifyMysqldump

	out=$(mkdir -p $backupPath)
	verifyExecution "$?" "Can't create backup dir $backupPath. $out" true
	logInfo "[Info] $backupPath exists"

	local schemas=$(mysql -u${mysqlUser} -h${remoteHost} --port=${3306} -N -e"select schema_name from information_schema.schemata where schema_name not in ('information_schema', 'performance_schema')")
	if [ ! -z "$schemas" ]; then
		for i in $schemas; do
			out=$(mysqldump -u${mysqlUser} -h${remoteHost} --port=${3306} -d $i | gzip > $backupPath/${i}_schema.sql.gz 2>&1)
			verifyExecution "$?" "Problems dumping schema for db $i. $out"
			logInfo "[OK] Dumping $i schema with mysqldump"
		done
		return
	fi

	verifyExecution "1" "While getting schemas, this happened: $schemas"
}

function verifyMydumperBin () {
	which mydumper &> /dev/null
	verifyExecution "$?" "Cannot find mydumper tool" true
	logInfo "[OK] Found 'mydumper' bin"
}

function runMydumper () {

	verifyMydumperBin
	logInfo "[Info] Dumping data with MyDumper.....start"
	out=$(mydumper --user=${mysqlUser} --outputdir=${backupPath} --host=${remoteHost} --port=${mysqlPort} --threads=${numberThreads} --compress --kill-long-queries --no-schemas --verbose=3 &>> $logFile)
	verifyExecution "$?" "Couldn't execute MyDumper. $out" true

	logInfo "[Info] Dumping data with MyDumper.....end"
}

function removeOldBackup () {

	rootPath=$(dirname $backupPath 2>&1)
	verifyExecution "$?" "Couldn't find backup path. $rootPath" true

	pushd $rootPath &> /dev/null
	daysAgo=$(date -d "$daily days ago" +%s)
	weeksAgo=$(date -d "$weekly weeks ago" +%s)
	
	logInfo "[Info] Removing old backups"
	for i in $(ls -1); do
		day=$(cat $rootPath/$i/metadata | grep Finished | awk -F": " '{print $2}' | awk '{print $1}' 2>&1)
		verifyExecution "$?" "Couldn't find $rootPath/$i/metadata file. $day"

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
runMysqldump
runMydumper
removeOldBackup
