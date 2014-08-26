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
remoteHost=192.168.1.105
binPrefix="mysql-bin"
backupPath="/root/"
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
        logInfo "Found mysqlbinlog"

        haveRaw=$(mysqlbinlog --help | grep "\--raw")
        if [ -z "$haveRaw" ]
        then
                verifyExecution "1" "Incorrect mysqlbinlog version. Needs 5.6 version with --raw parameter" true
        fi
        logInfo "Verified mysqlbinlog version"
}

function findFirstBinlog () {
        local first=$(mysql -u${mysqlUser} -h${remoteHost} -N -e"show binary logs" | head -n1 | awk '{print $1}')
        echo $first
}

function findLatestBinlog () {
        pushd $backupPath &> /dev/null
        verifyExecution "$?"  "Backup path $backupPath does not exists" true

        local latest=$(ls -1 | grep $binPrefix | tail -1)
        if [ -z "$latest" ]; then
                latest=$(findFirstBinlog)
        fi
        popd &>/dev/null
        echo $latest
}

function pullBinlogs () {
        echo "coming"
}

function rotateBackups () {
        echo "coming"
}

verifyMysqlbinlog
findLatestBinlog
pullBinlogs
