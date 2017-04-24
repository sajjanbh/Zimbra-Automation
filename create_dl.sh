#!/bin/bash
#Author: Sajjan Bhattarai
#Date: April 5, 2016
#Description: This script takes the list of distribution lists and adds them to the Zimbra Server.

# Check if file containing DLs and Emails is provided as first argument
if [ -z "$1" ]
then
	echo "You must pass the file as first argument."
	exit 1
fi

# Fetching list of distribution lists in the file
while IFS='' read -r dl || [[ -n "$dl" ]]; do
	echo "Creating $dl:"
	# Creating a distribution list
	output=$("zmprov cdl $dl")	
	# Checking the Exit status of above command
	if [ $? -eq 0 ]
	then
		echo "Success!"
	else
		echo "Failed!"
		echo "$dl :" >> create_dl.log
		echo "$output" >> create_dl.log
		echo "===================================================" >> create-dl.log
	fi
done < "$1"
