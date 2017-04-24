#!/bin/bash
#Author: Sajjan Bhattarai
# This script takes a file as first argument, which contains the list of accounts in new lines. It takes the respective distribution list as second argument.

# Check if the accounts list file is provided as first argument, else exit.
if [ -z "$1" ]
then
	echo "You must provide file containing accounts as first argument."
	exit 1
else
	file="$1"
fi

# Check if the DL name is provided as second argument, else set to pre-defined value
if ! [ -z "$2" ]
then
	dl="$2"
else
	dl="<dl-name>@<domain-name>"
fi

# Loop through the content of provided file to get list of accounts
while IFS='' read -r account || [[ -n "$account" ]]; do
	echo "Adding $account to $dl:"
	# Adding to a distribution list
	output=$(zmprov adlm "$dl" "$account")	
	# Checking the Exit status of above command
	if [ $? -eq 0 ]
	then
		echo "Success!"
	else
		echo "Failed!"
		echo "$account :" >> add_to_dl.log
		echo "$output" >> add_to_dl.log
		echo "===================================================" >> add_to_dl.log
	fi
done < "$file"
