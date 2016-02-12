#!/usr/bin/env bash
export PATH=$PATH:/usr/local/bin/:/usr/bin
# Exit if a pipeline results in an error.
set -o pipefail

# Grab stuff from the ec2 metadata
AWS_ACCESS_KEY_ID=`curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lib-amz-default | grep "AccessKeyId" | cut -d ":" -f 2 | tr "," " " | xargs`
AWS_SECRET_ACCESS_KEY=`curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lib-amz-default | grep "SecretAccessKey" | cut -d ":" -f 2 | tr "," " " | xargs`
AWS_SECURITY_TOKEN=`curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/lib-amz-default | grep "Token" | cut -d ":" -f 2 | tr "," " " | xargs`

export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export AWS_SECURITY_TOKEN=$AWS_SECURITY_TOKEN


## Automatic EBS Volume Snapshot Creation & Clean-Up Script
#
# Written by Casey Labs Inc. (https://www.caseylabs.com)
# Casey Labs - Contact us for all your Amazon Web Services Consulting needs!
#
# Additonal credits: Log function by Alan Franzoni; Pre-req check by Colin Johnson
#
# PURPOSE: This Bash script can be used to take automatic snapshots of your Linux EC2 instance. Script process:
# - Determine the instance ID of the EC2 server on which the script runs
# - Gather a list of all volume IDs attached to that instance
# - Take a snapshot of each attached volume
# - The script will then delete all associated snapshots taken by the script that are older than 7 days
#
# DISCLAIMER: Hey, this script deletes snapshots (though only the ones that it creates)!
# Make sure that you undestand how the script works. No responsibility accepted in event of accidental data loss.
#


## Requirements ##

	## 1) IAM USER:
	#
	# This script requires that a new IAM user be created in the IAM section of AWS. 
	# Here is a sample IAM policy for AWS permissions that this new user will require:
	#
	# {
	#    "Version": "2012-10-17",
	#    "Statement": [
	#        {
	#            "Sid": "Stmt1426256275000",
	#            "Effect": "Allow",
	#            "Action": [
	#                "ec2:CreateSnapshot",
	#                "ec2:CreateTags",
	#                "ec2:DeleteSnapshot",
	#                "ec2:DescribeSnapshotAttribute",
	#                "ec2:DescribeSnapshots",
	#                "ec2:DescribeVolumeAttribute",
	#                "ec2:DescribeVolumes"
	#            ],
	#            "Resource": [
	#                "*"
	#            ]
	#        }
	#    ]
	# }


	## 2) AWS CLI: 
	#
	# This script requires the AWS CLI tools to be installed.
	# Read more about AWS CLI at: https://aws.amazon.com/cli/
	#
	# Linux install instructions for AWS CLI:
	# ASSUMPTION: these commands are ran as the ROOT user.
	#
	# - Install Python pip (e.g. yum install python-pip or apt-get install python-pip)
	# - Then run: pip install awscli
	#
	# Configure AWS CLI by running this command: 
	#		aws configure
	#
	# [NOTE: if you have an IAM Role Setup for your instance to use the IAM policy listed above, you can skip the aws configure step.]
	#
	# Access Key & Secret Access Key: enter in the credentials generated above for the new IAM user
	# Region Name: the region that this instance is currently in (e.g. us-east-1, us-west-1, etc)
	# Output Format: enter "text"


	## 3) SCRIPT INSTALLATION:
	#
	# Copy this script to /opt/aws/ebs-snapshot.sh
	# And make it exectuable: chmod +x /opt/aws/ebs-snapshot.sh
	#
	# Then setup a crontab job for nightly backups:
	# (You will have to specify the location of the AWS CLI Config file)
	#
	# AWS_CONFIG_FILE="/root/.aws/config"
	# 00 06 * * *     root    /opt/aws/ebs-snapshot.sh



## Variable Declartions ##

# Get Instance Details
instance_id=`curl -s http://169.254.169.254/latest/meta-data/instance-id | xargs`
region=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g' | xargs`

# Set Logging Options
logfile="/var/log/ebs-snapshot.log"
logfile_max_lines="5000"

# How many days do you wish to retain backups for? Default: 7 days
retention_days="7"
retention_date_in_seconds=$(date +%s --date "$retention_days days ago")


## Function Declarations ##

# Function: Setup logfile and redirect stdout/stderr.
log_setup() {
    # Check if logfile exists and is writable.
    ( [ -e "$logfile" ] || touch "$logfile" ) && [ ! -w "$logfile" ] && echo "ERROR: Cannot write to $logfile. Check permissions or sudo access." && exit 1

    tmplog=$(tail -n $logfile_max_lines $logfile 2>/dev/null) && echo "${tmplog}" > $logfile
    exec > >(tee -a $logfile)
    exec 2>&1
}

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

# Function: Confirm that the AWS CLI and related tools are installed.
prerequisite_check() {
	for prerequisite in aws; do
		hash $prerequisite &> /dev/null
		if [[ $? == 1 ]]; then
			echo "In order to use this script, the executable \"$prerequisite\" must be installed." 1>&2; exit 70
		fi
	done
}

# Function: Snapshot all volumes attached to this instance.
snapshot_volumes() {
	for volume_id in $volume_list; do
		log "Volume ID is $volume_id"

		# Take a snapshot of the current volume, and capture the resulting snapshot ID
		snapshot_description="$(hostname)-backup-$(date +%Y-%m-%d)"

		snapshot_id=$(aws ec2 create-snapshot --region $region --output=text --description $snapshot_description --volume-id $volume_id --query SnapshotId)
		log "New snapshot is $snapshot_id"
	 
		# Add a "CreatedBy:AutomatedBackup" tag to the resulting snapshot.
		# Why? Because we only want to purge snapshots taken by the script later, and not delete snapshots manually taken.
		aws ec2 create-tags --region $region --resource $snapshot_id --tags Key=CreatedBy,Value=AutomatedBackup
	done
}

# Function: Cleanup all snapshots associated with this instance that are older than $retention_days
cleanup_snapshots() {
	for volume_id in $volume_list; do
		snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=volume-id,Values=$volume_id" "Name=tag:CreatedBy,Values=AutomatedBackup" --query Snapshots[].SnapshotId)
		for snapshot in $snapshot_list; do
			log "Checking $snapshot..."
			# Check age of snapshot
			snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
			snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
			snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)

			if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
				log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
				aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
			else
				log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
			fi
		done
	done
}	


## SCRIPT COMMANDS ##

log_setup
prerequisite_check

# Grab all volume IDs attached to this instance
volume_list=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instance_id --query Volumes[].VolumeId --output text)

snapshot_volumes
cleanup_snapshots
