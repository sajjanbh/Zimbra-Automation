#!/bin/bash
# Author: Sajjan Bhattarai
# Date: March 5, 2016
# Description: This bash script takes the list of user accounts from old zimbra server as an argument and creates the corresponding email accounts in the new Zimbra server.

domain="your-domain"
default_password="password@123"

# Function to generate random password in case you want unique password for each user
genpasswd() {
        local l=$1
        [ "$l" == "" ] && l=8
        tr -dc A-Za-z0-9_ < /dev/urandom | head -c ${l} | xargs
}

# This script creates user accounts with default CoS, so user specific CoS hasn't been defined here. You may add CoS settings accordingly.

# Splitting email address into user and domain name
while IFS='@' read -a user || [[ -n "$user" ]]; do
	# Splitting user account into firstname and lastname
	IFS='.' read -a names <<< "$user"
	# Capitalizing first letter of names
	firstname="$(tr '[:lower:]' '[:upper:]' <<< ${names[0]:0:1})${names[0]:1}"
	lastname="$(tr '[:lower:]' '[:upper:]' <<< ${names[1]:0:1})${names[1]:1}"

	# generate password
	password=$(genpasswd)

	echo "Creating $user@$domain..."

	# Creating user account in Zimbra server
	output=$("zmprov ca $user@$domain $password displayName \"$firstname $lastname\"")
	# Checking the exit status of zmprov function
	if [ $? -eq 0 ]
	then
		echo "Success!"
		# Write the user and user'a password in a text file so that you can send the password to the user independently maybe via SMS
		echo "$user@$domain     $password" >> new_users_passwords.list
	else
		echo "Failed!"
		echo "$user@$domain:" >> generate_users.log
		echo "$output" >> generate_users.log
		echo "===================================================" >> generate_users.log
	fi
done < "$1"
