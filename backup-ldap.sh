#!/bin/sh
# Description: This script runs the backup of LDAP database and config to user-specified location.
# You can run it as cronjob in preferred time interval. eg. crontab -e

DIR="/tmp/Backup"

# Check existence of backup folder, otherwise, create it
if [ ! -d "$DIR" ]
then
    mkdir "$DIR"
	chown -R zimbra:zimbra "$DIR"
fi  

echo Backing up LDAP DB...
su - zimbra -c "/opt/zimbra/libexec/zmslapcat $DIR"
if [ $? -eq 0 ] 
then
    echo "Succeeded!"
else
    echo "Backup fialed!"
fi  

echo Backing up LDAP Config...
su - zimbra -c "/opt/zimbra/libexec/zmslapcat -c $DIR"
if [ $? -eq 0 ]
then
    echo "Succeeded!"
else
    echo "Backup Failed!"
fi
