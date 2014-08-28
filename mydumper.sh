#!/bin/bash
#
# Backup binlog files using mysqlbinlog 5.6
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear

set -o pipefail
# Initial values

lockFile="/var/lock/mydumper-pull.lock"
errorFile="/var/log/mysql/mydumper.err"
logFile="/var/log/mysql/mydumper.log"
retention=30 # Retention in days
mysqlUser=root
mysqlPort=3306
#remoteHost=192.168.1.105
remoteHost=localhost
backupPath="/root/backups"
numberThreads=4
respawn=3 # How many attempts to restart the mysqlbinlog process try
email="daniel.guzman.burgos@percona.com"

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

function verifyMysqldump () {
	which mysqldump &> /dev/null
        verifyExecution "$?" "Cannot find mysqldump tool" true
        logInfo "[OK] Found 'mysqldump' bin"
}

function runMysqldump () {
	
	verifyMysqldump

	local schemas=$(mysql -u${mysqlUser} -h${remoteHost} --port=${3306} -N -e"select schema_name from information_schema.schemata where schema_name not in ('information_schema', 'performance_schema')")
	if [ ! -z "$schemas" ]; then
		for i in $schemas; do
			out=$(mysqldumpi -u${mysqlUser} -h${remoteHost} --port=${3306} -d $i | gzip > $backupPath/${i}_schema.sql.gz 2>&1)
			verifyExecution "$?" "Problems dumping schema for db $i. $out"
			logInfo "[Info] Dumping $i schema with mysqldump"
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
	out=$(mydumper --user=${mysqlUser} --outputdir=${backupPath} --host=${remoteHost} --port=${mysqlPort} --threads=${numberThreads} --compress --kill-long-queries --no-schemas --verbose=3 2&>1)
	verifyExecution "$?" "Couldn't execute MyDumper. $out" true
        logInfo "[Info] Dumping data with MyDumper."
}

setLockFile
runMysqldump
runMydumper
