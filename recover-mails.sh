#!/bin/bash
#Author: Sajjan Bhattarai
#Date: March 3, 2016
#Description: This script takes the list of zimbra accounts' ids and email addresses and inputs the mails associated with those users from old mail store to new Zimbra server's mailbox

# Check if the file is provided as first argument, else exit the program
if [ -z "$1" ]
then
	echo "You must provide the file as its first argument."
	exit 1
fi

#Splitting IDs and Email addresses in every line delimited by whitespace
while IFS='' read -r user || [[ -n "$user" ]]; do
	# Creating array containing ID and Email
	user_id=($user)
	echo "${user_id[0]} : ${user_id[1]}"
	# Restoring mails from user's mail directory to new mailbox inside folder named "Old-Mails
	zmmailbox -z -m "${user_id[1]}" addMessage /Old-Mails /opt/zimbra/store/0/Recovered-mails/store/0/"${user_id[0]}"/msg/*	
done < "$1"
