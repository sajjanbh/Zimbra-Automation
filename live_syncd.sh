#!/bin/bash
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.

#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>

##########################################################################
# Title      :  live_syncd
# Author     :  Simon Blandford <simon -at- onepointltd -dt- com>
# Date       :  2013-03-12
# Requires   :  zimbra sync_commands inotify-tools
# Category   :  Administration
# Version    :  2.1.4
# Copyright  :  Simon Blandford, Onepoint Consulting Limited
# License    :  GPLv3 (see above)
##########################################################################
# Description
# Keep two Zimbra servers synchronised in near-realtime
##########################################################################


#******************************************************************************
#********************** Constants *********************************************
#******************************************************************************

LOG_LEVEL=5
REDO_LOG_HISTORY_DAYS=10
ERROR_CLEAR_MINUTES=10
LDAP_CHECK_MINUTES_INTERVAL=10

ZIMBRA_DIR="/opt/zimbra"
BASE_DIR="$ZIMBRA_DIR""/live_sync"
LOCKING_DIR="$BASE_DIR""/lock"
PID_DIR="$BASE_DIR""/pid"
LOG_DIR="$BASE_DIR""/log"
LOG_FILE="$LOG_DIR""/live_sync.log"
LDAP_TEMP_DIR="$BASE_DIR""/ldap"
LDAP_TEMP_LDIF="$BASE_DIR""/ldif.bak"
STATUS_DIR="$BASE_DIR""/status"
SSH_IDENTITY_FILE="$ZIMBRA_DIR""/.ssh/live_sync"
REDOLOG_DIR="$ZIMBRA_DIR""/redolog"
REDO_LOG_FILE="$REDOLOG_DIR""/redo.log"
ARCHIVE_DIR="$REDOLOG_DIR""/archive"
LIVE_SYNC_ARCHIVE_DIR="$REDOLOG_DIR""/live_sync_archives"
LDAP_DATA_DIR="$ZIMBRA_DIR""/data/ldap/"
BACKUP_DIR="$ZIMBRA_DIR""/backup"
SYNC_COMMANDS_SCRIPT="$BASE_DIR""/sync_commands"
SSH="ssh -i ""$SSH_IDENTITY_FILE"" -o StrictHostKeyChecking=no -o CheckHostIP=no"\
" -o PreferredAuthentications=hostbased,publickey"
LOCK_STATE_DIR="$LOCKING_DIR""/live_sync.lock"
STOP_FILE="$STATUS_DIR""/live_sync.stop"
LAST_GOOD_REDO_REPLAY="$STATUS_DIR""/last_good_redo_replay"
LAST_GOOD_REDO_SYNC="$STATUS_DIR""/last_good_redo_sync"
LAST_GOOD_REDO_STREAM="$STATUS_DIR""/last_good_redo_stream"
LAST_GOOD_LDAP_SYNC="$STATUS_DIR""/last_good_ldap_sync"
LAST_GOOD_LDAP_START="$STATUS_DIR""/last_good_ldap_start"
WATCHES_FILE="$STATUS_DIR""/watches"
PID_FILE_LDAP="$PID_DIR""/ldap_live_sync.pid"
PID_FILE_REDO="$PID_DIR""/redo_log_live_sync.pid"
CONF_FILE="$BASE_DIR""/live_sync.conf"

#******************************************************************************
#********************** Functions *********************************************
#******************************************************************************

#Format for log output with errors and warnings going to >&2
logit () {
  logit_1 () {
    echo -n "$( date ) :"
    case $ in
      1)
        echo -n "Error :"
        ;;
      2)
        echo -n "Warning :"
        ;;
      3)
        echo -n "Info :"
        ;;
      4)
        echo -n "Debug :"
        ;;
    esac
    echo $@
  }
  local msg_level output_chan
  if [ $1 -le $LOG_LEVEL ]; then
    msg_level=$1
    shift
    if [ $msg_level -le 2 ]; then
      logit_1 $@ >&2
    else
      logit_1 $@
    fi
  fi
}

#Detect HSM
detect_hsm () {
  local retval
  #LDAP must be running
  ldap status &>/dev/null || ldap start &>/dev/null
  #MySQL must be running
  mysql.server status &>/dev/null || mysql.server start &>/dev/null
  #Preserve mailbox running state
  zmmailboxdctl status &>/dev/null
  prev_zmmailbox_status=$?
  zmmailboxdctl start &>/dev/null
  zmvolume -l | grep "type: secondaryMessage" >/dev/null
  retval=$?
   if [ $prev_zmmailbox_status -ne 0 ]; then
    zmmailboxdctl stop &>/dev/null
  fi
  return $retval
}

#Ensure ldap, convertd and mysql servers are running and then replay redo logs
replay_redo_logs () {
  local server_failed

  ldap status &>/dev/null || ldap start &>/dev/null
  mysql.server status &>/dev/null || mysql.server start &>/dev/null
  server_failed=0
  if ! ldap status &>/dev/null; then
    logit 1 "Start of local ldap server failed"
    ldap status >&2
    #Return error to trigger a "break" in while loop
    server_failed=1
  fi
  if ! mysql.server status &>/dev/null; then
    logit 1 "Start of local mysql server failed"
    mysql.server status >&2
    #Return error to trigger a "break" in while loop
    server_failed=1
  fi
  if [ "x""$convertd_enabled" == "xtrue" ]; then
    #Make sure indexing works while replaying redo log 
    zmconvertctl status &>/dev/null || zmconvertctl start &>/dev/null
    if ! zmconvertctl status &>/dev/null; then
      logit 2 "Start of local convertd servers failed"
      zmconvertctl status >&2
    fi
  fi
  [ $server_failed -eq 1 ] && return 1
  logit 3 "Replaying redologs..."
  if ! zmplayredo >/dev/null; then
    logit 2 "Replay of redolog failed"
    #No error returned here since "break" is not necessary
  else
    #If no errors then archive redo log files
    if ! mkdir -p "$LIVE_SYNC_ARCHIVE_DIR"; then
      logit 1 "Unable to create directory $LIVE_SYNC_ARCHIVE_DIR"
      exit 1
    fi
    mv -f "$ARCHIVE_DIR""/"* "$LIVE_SYNC_ARCHIVE_DIR""/" 2>/dev/null
    touch "$LAST_GOOD_REDO_REPLAY"
  fi
  logit 3 "Replaying redologs done"
  return 0
}

#The redo log sync daemon
redo_log_live_sync () {
  local stream_pid archived_file i archived_redo_log_file prev_zmmailbox_status secondary_storage

  logit 3 "Starting redo log live sync process"

  #Wait for lock directory to be successfully created
  while ! mkdir "$LOCK_STATE_DIR" &>/dev/null; do
    sleep 2
  done
  logit 3 "Detecting if HSM used"
  if detect_hsm; then
    logit 3 "HSM Detected"
    secondary_storage="yes"
  else
    logit 3 "No HSM Detected"
  fi
  rmdir "$LOCK_STATE_DIR"
  
  while [ ! -f "$STOP_FILE" ]; do
    while [ ! -f "$STOP_FILE" ]; do
      #Wait for lock directory to be successfully created
      while ! mkdir "$LOCK_STATE_DIR" &>/dev/null; do
        sleep 2
      done
      [ -f "$STOP_FILE" ] && break
      logit 3 "Syncing redologs..."
      #If incremental backups are enabled then gather redo logs from backups and copy
      #to local archive directory
      redo_sync_fail="false"
      for archived_redo_log_file in $( echo "gather""$REDO_LOG_HISTORY_DAYS" | \
          $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" ); do
        if [ -f "$LIVE_SYNC_ARCHIVE_DIR""/""$( basename "$archived_redo_log_file" )" ]; then
          logit 4 "Already processed so skipping: $archived_redo_log_file"
        else
          logit 4 "Syncing incremental backup file: $archived_redo_log_file"
          if ! rsync -z -e "$SSH" --size-only "$remote_address"":""$archived_redo_log_file" \
              "$ARCHIVE_DIR""/".; then
            logit 2 "Rsync of a redolog, $archived_redo_log_file, failed"
            redo_sync_fail="true"
          fi
        fi
      done

      #Suspend if HSM is running
      if which zmhsm >/dev/null && zmhsm -u | grep "Currently running" >/dev/null; then
        logit 3 "Replaying redologs is suspended while HSM process is active"
      else
      
        #Mailbox process must not be running now. Preserve state and stop.
        zmmailboxdctl status &>/dev/null
        prev_zmmailbox_status=$?
        if [ $prev_zmmailbox_status -eq 0 ]; then
          zmmailboxdctl stop &>/dev/null
        fi
        sleep 2
        if zmmailboxdctl status &>/dev/null; then
          logit 1 "Unable to stop local Zimbra mailbox service"
          return 1
        fi
      
        logit 4 "Syncing $REDO_LOG_FILE"
        if ! rsync -e "$SSH" -z \
          "$remote_address"":$REDO_LOG_FILE" "$REDO_LOG_FILE"; then
          logit 2 "Rsync of $REDO_LOG_FILE failed"
          redo_sync_fail="true"
        fi
        logit 4 "Syncing $REDO_LOG_FILE done"
        if [ "x""$redo_sync_fail" == "xfalse" ]; then
          touch "$LAST_GOOD_REDO_SYNC"
        else
          break
        fi
        logit 4 "Syncing redologs done"
        logit 4 "Purging redolog directory and archives"
        #Purge local redolog directory
        find $REDOLOG_DIR -mtime +$REDO_LOG_HISTORY_DAYS -type f -exec rm {} \;
        #Purge any interrupted rsync files
        find $REDOLOG_DIR -name '.redo*' -type f -exec rm {} \;
        logit 4 "Purge redolog directory and archives done"
        replay_redo_logs || break
      
        #Restore mailboxd to previous running state or start if HSM is being used
        if [ $prev_zmmailbox_status -eq 0 ] || \
            [ "x""$secondary_storage" == "xyes" ] >/dev/null; then
          logit 4 "Re-starting Zimbra mailbox service"
          zmmailboxdctl start &>/dev/null
          if ! zmmailboxdctl status &>/dev/null; then
            logit 2 "Unable to re-start local Zimbra mailbox service"
          fi
        fi
      fi
      
      #If there are no incremental backups then remote archive directory will need purging
      if [ "x""$incremental_backups" != "xtrue" ]; then
        logit 4 "Purging remote redolog directory"
        echo "purge""$REDO_LOG_HISTORY_DAYS" | \
          $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT"
        logit 4 "Purging remote redolog directory done"
      fi
      #Establish copy-and-live-stream of current redo.log file
      logit 4 "Live streaming redolog"
      echo stream | \
        $SSH "$remote_address" \
        "$SYNC_COMMANDS_SCRIPT" >"$REDO_LOG_FILE" &
      stream_pid=$!
      disown $stream_pid
      #Delay as PID was sometimes not being found if checked immediately
      sleep 5
      #If successfully established stream then sit and wait for move to archive
      if ps $stream_pid | grep "$SYNC_COMMANDS_SCRIPT" &>/dev/null; then
        logit 4 "Live streaming redolog established"
        touch "$LAST_GOOD_REDO_STREAM"
        #Remove lock file, this is resting point
        rmdir "$LOCK_STATE_DIR" &>/dev/null
        #Wait for name to be passed of new archive file after redo.log is moved on remote server
        #This is normal resting point of this process
        archived_file=$( echo wait_redo | \
          $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" | \
          tail -n 1 | egrep -o "redo-.*log" )
        #Kill stream
        kill -KILL $( ps aux | grep "$SYNC_COMMANDS_SCRIPT" | \
          grep -v grep | awk '{print $2}' ) &>/dev/null
        #Mirror move operation on local server
        if echo "$archived_file" | egrep "redo-.*log" &>/dev/null; then
          logit 4 "Moving redo.log to $archived_file"
          mv -f "$REDO_LOG_FILE" "$ARCHIVE_DIR""/""$archived_file" 2>/dev/null
        else
          logit 2 "Archive file name not found"
        fi
        [ -f "$STOP_FILE" ] && break
      else
        logit 2 "Failed to start redolog streaming, PID=$stream_pid"
        break
      fi
    done
    rmdir "$LOCK_STATE_DIR" &>/dev/null
    #Wait $ERROR_CLEAR_MINUTES minutes for error to error to clear
    i=0
    while [ $(( i++ )) -lt 60 ] && [ ! -f "$STOP_FILE" ]; do
      sleep $ERROR_CLEAR_MINUTES
    done
  done
  logit 3 "Ending redo log live sync process"
}

#The ldap sync daemon
ldap_live_sync () {
  local ldap_wait_pid i last_ldap_success_state

  last_ldap_success_state="false"
  
  logit 3  "Starting ldap live sync process"
  while [ ! -f "$STOP_FILE" ]; do
    while [ ! -f "$STOP_FILE" ]; do
      #Wait for lock directory to be successfully created
      while ! mkdir "$LOCK_STATE_DIR" &>/dev/null; do
        sleep 3
      done
      if [ $zimbra_version -lt 8 ]; then
        logit 3 "Syncing ldap using rsync"
        #Use rsync for Zimbra older than verion 8
        while [ 1 ]; do
          #Check for changes during ldap sync operation
          echo wait_ldap | \
            $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" &>"$WATCHES_FILE" &
          ldap_wait_pid=$!
          disown $ldap_wait_pid
          if ! ps "$ldap_wait_pid" &>/dev/null; then
            logit 2 "Unable to establish watch on remote LDAP directory, no ldap sync performed"
            break
          fi
          #Wait for watches to be established
          while ! grep "established" "$WATCHES_FILE" &>/dev/null && \
              ps "$ldap_wait_pid" &>/dev/null; do
            sleep 1
          done
          #Echo out status
          cat "$WATCHES_FILE"
          rm -f "$WATCHES_FILE"
          
          
          #Rsync remote server to temporary local ldap directory
          if ! rsync -e "$SSH" -aHz --sparse --force --delete \
            "$remote_address"":$LDAP_DATA_DIR""/" "$LDAP_TEMP_DIR""/"; then
            logit 2 "Rsync of ldap failed"
            break
          else
            touch "$LAST_GOOD_LDAP_SYNC"
          fi
          ps $ldap_wait_pid &>/dev/null && break
          logit 3 "Ldap changed during rsync. Re-syncing."
          sleep 10
        done
        kill -KILL $ldap_wait_pid &>/dev/null
      else
        #Use ldif export for Zimbra 8 and over
        logit 3 "Syncing ldap using ldif"
        if ! echo dump_ldap | \
          $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" >"$LDAP_TEMP_LDIF"; then
          logit 2 "Unable to fetch remote LDIF, no LDAP sync performed"
          break
        else
          touch "$LAST_GOOD_LDAP_SYNC"
        fi
      fi
      if which zmhsm >/dev/null && zmhsm -u | grep "Currently running" >/dev/null; then
        logit 3 "LDAP update is suspended while HSM process is active"
      else
        #Stop ldap
        ldap status &>/dev/null && ldap stop &>/dev/null
        if ldap status &>/dev/null; then
          logit 1 "Unable to stop local ldap server"
          break
        fi
        if [ $zimbra_version -lt 8 ]; then
          #Use rsync for Zimbra older than verion 8
          #rsync temporary local ldap directory to real local ldap directory
          rsync -aH --sparse "$LDAP_TEMP_DIR""/" "$LDAP_DATA_DIR""/"
        else
          #Use LDIF import for Zimbra 8 and over
          rm -rf "$LDAP_DATA_DIR""/mdb" && \
          mkdir -p "$LDAP_DATA_DIR""/mdb/db" && \
          mkdir -p "$LDAP_DATA_DIR""/mdb/log" && \
          /opt/zimbra/libexec/zmslapadd "$LDAP_TEMP_LDIF"
          if [ $? != 0 ]; then
            logit 2 "Unable to import LDIF into local LDAP"
            break
          fi
        fi
        #Restart ldap
        ldap status &>/dev/null || ldap start &>/dev/null
        if ! ldap status &>/dev/null; then
          logit 1 "Unable to restart local ldap server"
          last_ldap_success_state="false"
        else
          last_ldap_success_state="true"
        fi
        logit 4 "Syncing LDAP done"
      fi
      rmdir "$LOCK_STATE_DIR" &>/dev/null
      [ -f "$STOP_FILE" ] && break
      #Wait for change in remote ldap over $LDAP_CHECK_MINUTES_INTERVAL intervals
      echo wait_ldap | \
        $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" &
      ldap_wait_pid=$!
      disown $ldap_wait_pid
      while [ ! -f "$STOP_FILE" ]; do
        logit 4 "Start new LDAP monitor period"
        #Repeat last ldap success so that no ldap change is not
        #interpreted by Nagios as no ldap success.
        if [ "x""$last_ldap_success_state" == "xtrue" ]; then
          touch "$LAST_GOOD_LDAP_START"
        fi
        #Restart wait for ldap change if required
        if ! ps $ldap_wait_pid &>/dev/null; then
          echo wait_ldap | \
            $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" &
          ldap_wait_pid=$!
          disown $ldap_wait_pid
        fi
        #Wait $LDAP_CHECK_MINUTES_INTERVAL minutes
        i=0
        while [ $(( i++ )) -lt 60 ] && [ ! -f "$STOP_FILE" ]; do
          sleep $LDAP_CHECK_MINUTES_INTERVAL
        done
        #If wait process is not still running then there was a change
        ps $ldap_wait_pid &>/dev/null || break
      done
    done
    rmdir "$LOCK_STATE_DIR" &>/dev/null
    #Wait $ERROR_CLEAR_MINUTES minutes for error to error to clear
    i=0
    while [ $(( i++ )) -lt 60 ] && [ ! -f "$STOP_FILE" ]; do
      sleep $ERROR_CLEAR_MINUTES
    done
  done
  logit 3 "Ending ldap live sync process"
}

get_zimbra_config_globals () {
  #Query whether incremental backups are enabled
  incremental_backups=$( echo "query_incremental" | \
    $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" )
    
  #Query whether convertd is installed and enabled
  ldap status &>/dev/null || ldap start &>/dev/null
  if ! ldap status &>/dev/null; then
    logit 1 "Unable to start local ldap server"
    exit 1
  fi
  if [ $( zmprov -l  gs `zmhostname` | \
          egrep "(zimbraServiceInstalled|zimbraServiceEnabled):[[:space:]]*convertd" | \
          wc -l  ) -eq 2 ]; then
    convertd_enabled="true"
  else
    convertd_enabled="false"
  fi
}

kill_everything () {
  touch "$STOP_FILE"
  kill -KILL $( head -n 1 "$PID_FILE_LDAP" 2>/dev/null ) &>/dev/null
  kill -KILL $( head -n 1 "$PID_FILE_REDO" 2>/dev/null ) &>/dev/null
  kill -KILL $( ps aux | grep "live_syncd start" | grep -v grep | awk '{print $2}' ) &>/dev/null
  kill -KILL $( ps aux | grep "redo_log_live_sync" | grep -v grep | awk '{print $2}' ) &>/dev/null
  kill -KILL $( ps aux | grep "ldap_live_sync" | grep -v grep | awk '{print $2}' ) &>/dev/null
  kill -KILL $( ps aux | \
    grep "$SYNC_COMMANDS_SCRIPT" | grep -v grep | awk '{print $2}' ) &>/dev/null
  kill -KILL $( ps aux | grep "rsync" | egrep "$REDOLOG_DIR""|""$LDAP_DATA_DIR""|""$BACKUP_DIR" | \
    awk '{print $2}' ) &>/dev/null
  #Kill redolog playback if running
  kill -KILL $( ps aux | egrep "zimbra.*java.*PlaybackUtil" | grep -v egrep | \
    awk '{print $2}' ) &>/dev/null
  rm -f "$STOP_FILE"
  rm -f "$PID_FILE_LDAP"
  rm -f "$PID_FILE_REDO"
  rmdir "$LOCK_STATE_DIR" &>/dev/null
}

quitting () {
  echo "Quitting"
  #Kill any hanging processes
  kill_everything
  trap - INT TERM SIGINT SIGTERM
  echo 'kill -KILL $( ps aux | grep live_syncd | grep -v grep | awk '"'"'{print $2}'"'"' ) &>/dev/null' | \
    at now && sleep 1 && rmdir "$LOCK_STATE_DIR" &>/dev/null
  exit
}


#******************************************************************************
#********************** Main Program ******************************************
#******************************************************************************

if [ "$( whoami )" != "zimbra" ]; then
  echo "Must run as zimbra user" >&2
  exit 1
fi

mkdir -p "$LOCKING_DIR"
mkdir -p "$PID_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$LDAP_TEMP_DIR"
mkdir -p "$STATUS_DIR"
chmod 755 "$STATUS_DIR"

if [ ! -f "$CONF_FILE" ]; then
  echo "Configuration file, $CONF_FILE, not found" >&2
  exit 1
fi

source "$CONF_FILE"

#Find all local addresses
server_addresses=$( /sbin/ifconfig | grep inet |   egrep -io "inet [[:space:]]*(([0-9]+\.){3}[0-9]+|[0-9a-f]+(:[0-9a-f]*){5})" |   sed "s/inet //" | tr -d " \t" )

#Check configured server addresses are valid
if ! echo "$server1" | \
    egrep -i "([0-9]+\.){3}[0-9]+|[0-9a-f]+(:[0-9a-f]*){5}" &>/dev/null; then
  echo "No valid IP address found for server1 in configuration file" >&2
  exit 1
fi
if ! echo "$server2" | \
    egrep -i "([0-9]+\.){3}[0-9]+|[0-9a-f]+(:[0-9a-f]*){5}" &>/dev/null; then
  echo "No valid IP address found for server2 in configuration file" >&2
  exit 1
fi

#Deduce local address and assume other address is remote machine
if echo "$server_addresses" | grep "$server1" &>/dev/null; then
  local_address="$server1"
  remote_address="$server2"
else
  if echo "$server_addresses" | grep "$server2" &>/dev/null; then
    local_address="$server2"
    remote_address="$server1"
  else
    echo "Unable to identify local server address and assume remote address" >&2
    exit 1
  fi
fi

#Check remote server is OK
remote_server_status=$( echo "test" | \
  $SSH "$remote_address" "$SYNC_COMMANDS_SCRIPT" )

if [ "x""$remote_server_status" == "xbusy" ]; then
  echo "Remote server appears to have live_syncd process running" >&2
  echo "This can not run on both servers" >&2
  exit 1
fi

if [ "x""$remote_server_status" != "xOK" ]; then
  echo "Unable to run commands on remote server" >&2
  exit 1
fi

#Get major Zimbra version
zimbra_version=$( zmcontrol -v | egrep -o "[0-9][^\.]*" | head -n 1 )
if [ ${#zimbra_version} -lt 1 ]; then
 zimbra_version=0
fi

case $1 in
  start)
    #Check for processes from this script and also redolog replay. Don't count PID files older than uptime.
    if [ -f "$PID_FILE_REDO" ] && \
        [ $(( $( date +%s ) - $( stat -c '%Y' "$PID_FILE_REDO" ) )) -lt $( cat /proc/uptime | egrep -o "[0-9]+" | head -n 1 ) ]; then
      pid_found="yes"
    fi
    if [ -f "$PID_FILE_LDAP" ] && \
        [ $(( $( date +%s ) - $( stat -c '%Y' "$PID_FILE_LDAP" ) )) -lt $( cat /proc/uptime | egrep -o "[0-9]+" | head -n 1 ) ]; then
      pid_found="yes" 
    fi
    if [ $pid_found ] || \
        ps aux | egrep "zimbra.*java.*PlaybackUtil" | grep -v egrep &>/dev/null; then
      echo "Proccess already running"
    else
      echo -n "Starting processes..."
      get_zimbra_config_globals
      echo "***************************************" >>"$LOG_FILE"
      logit 3 "Starting $( basename "$0" )" >>"$LOG_FILE"
      logit 3 "Incremental backups enabled : $incremental_backups" >>"$LOG_FILE"
      logit 3 "Convertd enabled : $convertd_enabled" >>"$LOG_FILE"
  
      ldap_live_sync >>"$LOG_FILE" 2>&1 &
      echo $! >"$PID_FILE_LDAP"
      redo_log_live_sync >>"$LOG_FILE" 2>&1 &
      echo $! >"$PID_FILE_REDO"
      echo "done"
    fi
    ;;
  stop)
    touch "$STOP_FILE"
    [ -d "$LOCK_STATE_DIR" ] && echo "Waiting for sync operations to complete..."
    while [ -d "$LOCK_STATE_DIR" ]; do
      sleep 5
    done
    rm -f "$STOP_FILE"
    replay_redo_logs
    kill_everything
    echo "done"
    ;;
  status)
    if ps aux | egrep "zimbra.*java.*PlaybackUtil" | grep -v egrep &>/dev/null; then
      echo "redolog is being replayed"
      replay_stat=0
    else
      replay_stat=3
    fi
    if [ -f  $PID_FILE_REDO ] && ps $( head -n 1 $PID_FILE_REDO 2>/dev/null ) &>/dev/null; then
      echo "redo log sync process OK"
      redo_stat=0
    else
      echo "redolog sync process stopped"
      redo_stat=3
    fi
    if [ -f  $PID_FILE_LDAP ] && ps $( head -n 1 $PID_FILE_LDAP 2>/dev/null ) &>/dev/null; then
      echo "ldap sync process OK"
      ldap_stat=0
    else
      echo "ldap sync process stopped"
      ldap_stat=3
    fi
    [ $ldap_stat == 3 ] && [ $redo_stat == 3 ] && [ $replay_stat == 3 ] && exit 3
    [ $ldap_stat == 0 ] && [ $redo_stat == 0 ] && exit 0
    exit 1
    ;;
  kill)
    kill_everything
    ;;
  *)
    trap quitting INT TERM SIGINT SIGTERM
    if ps aux | grep "redo_log_live_sync" | grep -v grep  &>/dev/null || \
        ps aux | grep "ldap_live_sync" | grep -v grep  &>/dev/null || \
        ps aux | egrep "zimbra.*java.*PlaybackUtil" | grep -v egrep &>/dev/null; then
      echo "Proccess already running"
    else
      echo "Starting processes in realtime"
      get_zimbra_config_globals
      logit 3 "Incremental backups enabled : $incremental_backups"
      logit 3 "Convertd enabled : $convertd_enabled"
      ldap_live_sync &
      echo $! >"$PID_FILE_LDAP"
      redo_log_live_sync &
      echo $! >"$PID_FILE_REDO"
      while [ 1 ]; do sleep 10; done
    fi
    ;;
esac
