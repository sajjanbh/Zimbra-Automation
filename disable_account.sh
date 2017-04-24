#!/bin/bash
#Author: Sajjan Bhattarai
#Date: April 24, 2016
#Description: This script takes the list of Zimbra users who have never logged on and disables them by changing their status to maintenance mode.

# Check if file containing email accounts is provided as first argument, else exit
if [ -z "$1" ]
then
        echo "You must pass the file as first argument."
        exit 1
fi

#Splitting account from list
while IFS='' read -r account || [[ -n "$account" ]]; do
	accounts=($account)
	# Disabling user account
	output=$(zmprov ma "$accounts[0]" zimbraAccountStatus maintenance)	
	# Checking the Exit status of above command
	if [ $? -eq 0 ]
	then
		echo "Success!"
	else
		echo "Failed!"
		echo "$dl :" >> disable_account.log
		echo "$output" >> disable_account.log
		echo "===================================================" >> create-dl.log
	fi
done < "$1"
