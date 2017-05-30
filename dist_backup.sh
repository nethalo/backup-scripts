#!/bin/bash
#
# Distributed Backup data using MySQL mysqldump tool
# Daniel Guzman Burgos <daniel.guzman.burgos@percona.com>
#

clear

set -o pipefail
set -x

# Initial values

lockFile="/var/lock/mysqldump.lock"
errorFile="/var/log/mysqldump.err"
logFile="/var/log/mysqldump.log"
mysqlUser=root
mysqlPort=3306
remoteHost=ps56-1
backupPath="/backups/$(date +%Y%m%d)/"
email="daniel.guzman.burgos@percona.com"

schemaName="percona"

# Function definitions

function sendAlert () {
        if [ -e "$errorFile" ]
        then
                alertMsg=$(cat $errorFile)
                echo -e "${alertMsg}" | mailx -s "[$HOSTNAME] ALERT Distributed backup"
        fi
}

function destructor () {
        #sendAlert
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

function verifyMysql () {
        which mysql &> /dev/null
        verifyExecution "$?" "Cannot find mysql client" true
        logInfo "[OK] Found 'mysql' bin"
}

function verifyPT () {
        which pt-slave-find &> /dev/null
        if [ $? -ne "0" ]; then
                logInfo "[Warning] pt-slave-find not found, downloading"
                wget percona.com/get/pt-slave-find
                verifyExecution "$?" "Cannot find mysql client" true
                logInfo "[OK] Found 'mysql' bin"
                chmod +x pt-slave-find
                mv pt-slave-find /usr/bin/pt-slave-find
                #apt-get install libdbd-mysql-perl
        fi
}


# get a list of all the tables
function listTables () {
        verifyMysql
        out=$(mysql -u$mysqlUser -h${remoteHost} -N -e"SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '${schemaName}'" 2>&1)
        verifyExecution "$?" "Can't get the table list. $out" true
        logInfo "[Info] table list gathered"
        echo $out > /tmp/tables.txt
        #echo "mysql -u$mysqlUser -h${remoteHost} -N -e\"SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '${schemaName}'\""
}
# find slaves
function findSlaves () {
        verifyPT
        out=$(pt-slave-find -h ${remoteHost} --report-format hostname --recurse 1 2>&1)
        verifyExecution "$?" "No slaves found. Finishing script. $out" true
        logInfo "[Info] slaves found"

        CHUNKS=$(echo $out | grep "+-" | wc -l)
        verifyExecution "$?" "Cannot get chunks. Finishing" true
        logInfo "[Info] slaves"

        IFS='
'
        index=1
        for i in $(echo $out | grep "+-" | awk '{print $2}'); 
        do
                slaves[$index]=$i;
                index=$(($index+1))
        done
}

# make N files with table names divided
makeDistLists () {
        SPLITTED=/tmp/filepart
        out=$(/usr/bin/split --number=l/$CHUNKS --numeric-suffixes --suffix-length=1 /tmp/tables.txt $SPLITTED 2>&1)
        verifyExecution "$?" "Cannot split tables into files. $out" true
        logInfo "[Info] lists created"
}

# freeze FTWRL + STOP SLAvE
freezeServers () {
        out=$(mysql -u$mysqlUser -h${remoteHost} -N -e"FLUSH TABLES WITH READ LOCK" 2>&1)
        verifyExecution "$?" "Cannot set FTWRL. $out" true
        logInfo "[Info] FTWRL set"

        for i in $(seq ${#slaves[@]}); 
        do
                host=${slaves[$i]};
                out=$(mysql -u$mysqlUser -h${host} -N -e"STOP SLAVE" 2>&1)
                verifyExecution "$?" "Cannot stop slave on $host. $out" true
                logInfo "[Info] slave stopped on $host"
        done
}

# find biggest executed master pos
findMostUpdatedSlave () {
        for i in $(seq ${#slaves[@]}); 
        do
                host=${slaves[$i]};
                out=$(mysql -u$mysqlUser -h${host} -e"SHOW SLAVE STATUS\G " | grep -i "exec_master_log_pos" | awk -F": " '{print $2}' 2>&1)
                verifyExecution "$?" "Cannot get slave status on $host. $out" true
                logInfo "[Info] slave status on $host"
                executedPos[$i]=$out;
        done

        IFS=$'\n' sorted=($(sort <<<"${executedPos[*]}"))
        unset IFS
        greatestPos=${executedPos[3]}
}

# execute start slave until
syncSlaves () {

        binlogFile=$(mysql -u$mysqlUser -h${slaves[1]} -e"SHOW SLAVE STATUS\G " | grep -i "Relay_Master_Log_File" | awk -F": " '{print $2}' 2>&1)
        verifyExecution "$?" "Cannot get binlogFile. $binlogFile" true
        logInfo "[Info] got binlogFile"

        for i in $(seq ${#slaves[@]}); 
        do
                host=${slaves[$i]};
                out=$(mysql -u$mysqlUser -h${host} -e"START SLAVE UNTIL MASTER_LOG_FILE = '$binlogFile', MASTER_LOG_POS = ${greatestPos}" 2>&1)
                verifyExecution "$?" "Cannot set start slave until on $host. $out" true
                logInfo "[Info] set start slave until on $host"
                executedPos[$i]=$out;
        done
}

# fire up N mysqldump instances (^subdivided by schema)
startDump () {
        for i in $(seq ${#slaves[@]}); 
        do
                host=${slaves[$i]};
                out=$(mysqldump -u${mysqlUser} -h${host} --single-transaction "${SPLITTED}$(($i-1))" > $backupPath/${host}.sql.gz 2>&1 &)
                verifyExecution "$?" "Problems dumping $host. $out"
                logInfo "[OK] Dumping $host"
        done
}

# unlock tables/start slave
unlockStartSlaves () {
        out=$(mysql -u$mysqlUser -h${remoteHost} -N -e"UNLOCK TABLES" 2>&1)
        verifyExecution "$?" "Cannot unloca tables. $out" true
        logInfo "[Info] FTWRL removed"

        for i in $(seq ${#slaves[@]}); 
        do
                host=${slaves[$i]};
                out=$(mysql -u$mysqlUser -h${host} -e"START SLAVE" 2>&1)
                verifyExecution "$?" "Cannot set start slave on $host. $out" true
                logInfo "[Info] set start slave on $host"
                executedPos[$i]=$out;
        done
}

listTables
findSlaves
makeDistLists
freezeServers
findMostUpdatedSlave
syncSlaves
startDump
unlockStartSlaves
# wait until all mysqldump instances finish.

